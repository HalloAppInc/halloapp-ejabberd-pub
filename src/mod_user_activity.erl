%%%------------------------------------------------------------------------------------
%%% File    : mod_user_activity.erl
%%%
%%% Copyright (C) 2020 halloappinc.
%%%
%%% This file handles storing and retrieving activity/last seen status
%%% of all the users. We basically register for 3 hooks:
%%% set_presence_hook and unset_presence_hook:
%%% every presence update from a user is triggered here
%%% and we use it to set the activity status of that user.
%%% c2s_closed is triggerred if the connection is terminated unusually.
%%% register_user: we register an empty activity status for the user upon
%%% registration, so that it is available immediately for others.
%%% remove_user: we remove the last known activity of the user when
%%% the user is removed from the app.
%%% Whenever a user's activity is updated, we also broadcast the activity to the
%%% users who subscribed. We also fetch the last activity of the users the
%%% user subscribed to and route them to the user.
%%% TODO(murali@): Update specs in this file.
%%%------------------------------------------------------------------------------------

-module(mod_user_activity).
-author('murali').
-behaviour(gen_mod).

-include("logger.hrl").
-include("xmpp.hrl").
-include("packets.hrl").
-include("account.hrl").

%% gen_mod API.
-export([start/2, stop/1, reload/3, depends/2, mod_options/1]).

%% API and hooks.
-export([
    set_presence_hook/4,
    unset_presence_hook/4,
    register_user/3,
    get_user_activity/2,
    probe_and_send_presence/3
]).


start(Host, _Opts) ->
    ejabberd_hooks:add(set_presence_hook, Host, ?MODULE, set_presence_hook, 1),
    ejabberd_hooks:add(unset_presence_hook, Host, ?MODULE, unset_presence_hook, 1),
    ejabberd_hooks:add(register_user, Host, ?MODULE, register_user, 50).

stop(Host) ->
    ejabberd_hooks:delete(set_presence_hook, Host, ?MODULE, set_presence_hook, 1),
    ejabberd_hooks:delete(unset_presence_hook, Host, ?MODULE, unset_presence_hook, 1),
    ejabberd_hooks:delete(register_user, Host, ?MODULE, register_user, 50).

depends(_Host, _Opts) ->
    [].

mod_options(_Host) ->
    [].

reload(_Host, _NewOpts, _OldOpts) ->
    ok.

%%====================================================================
%% hooks
%%====================================================================

%% register_user sets some default undefined activity for the user until they login.
%% TODO: figure out how to get resource/user agent here
-spec register_user(User :: binary(), Server :: binary(), Phone :: binary()) ->
        {ok, any()} | {error, any()}.
register_user(User, Server, _Phone) ->
    Status = undefined,
    TimestampMs = util:now_ms(),
    store_user_activity(User, Server, undefined, TimestampMs, Status).


%% set_presence_hook checks and stores the user activity, and also broadcast users presence
%% to their subscribed users and probes the presence of users that the user subscribed to
%% and sends it to the user.
-spec set_presence_hook(User :: binary(), Server :: binary(),
        Resource :: binary(), Presence :: presence()) -> ok.
set_presence_hook(User, Server, Resource, #pb_presence{type = StatusType}) ->
    ?INFO("Uid: ~p, Resource: ~p, StatusType: ~p", [User, Resource, StatusType]),
    store_and_broadcast_presence(User, Server, Resource, StatusType),
    check_and_probe_contacts_presence(User, Server, StatusType).


-spec unset_presence_hook(User :: binary(), Mode :: atom(),
        Resource :: binary(), Reason :: atom()) -> ok.
%% when an account is deleted, we terminate the connection session.
%% as part of that: we unset presence info and run this hook,
%% but since this uid is deleted, we can ignore this hook here.
unset_presence_hook(_User, _Mode, _Resource, {socket, account_deleted}) -> ok;
%% passive connections should not affect your presence behavior.
unset_presence_hook(_User, passive, _Resource, _Reason) -> ok;
unset_presence_hook(User, active, Resource, _Reason) ->
    Server = util:get_host(),
    store_and_broadcast_presence(User, Server, Resource, away).


%%====================================================================
%% API
%%====================================================================

-spec get_user_activity(User :: binary(), Server :: binary()) -> activity().
get_user_activity(User, _Server) ->
    {ok, Activity} = model_accounts:get_last_activity(User),
    Activity.


-spec probe_and_send_presence(Uid :: binary(), Server :: binary(), Ouid :: binary()) -> ok.
probe_and_send_presence(Uid, Server, Ouid) ->
    Activity = get_user_activity(Ouid, Server),
    check_and_send_presence(Uid, Activity, Ouid).

%%====================================================================
%% Internal functions
%%====================================================================


-spec store_and_broadcast_presence(User :: binary(), Server :: binary(), Resource :: binary() | undefined,
        Status :: undefined | activity_status()) -> ok | {ok, any()}.
store_and_broadcast_presence(_, _, _, undefined) ->
    {ok, ignore_undefined_presence};
store_and_broadcast_presence(User, Server, Resource, away) ->
    TimestampMs = util:now_ms(),
    case get_user_activity(User, Server) of
        #activity{status = away} ->
            {ok, ignore_away_presence};
        _ ->
            store_user_activity(User, Server, Resource, TimestampMs, away),
            broadcast_presence(User, Server, TimestampMs, away)
    end;
store_and_broadcast_presence(User, Server, Resource, available) ->
    TimestampMs = util:now_ms(),
    store_user_activity(User, Server, Resource, TimestampMs, available),
    broadcast_presence(User, Server, undefined, available).


-spec store_user_activity(User :: binary(), Server :: binary(), TimestampMs :: integer(),
        Resource :: binary() | undefined, Status :: undefined | activity_status()) -> {ok, any()} | {error, any()}.
store_user_activity(User, _Server, Resource, TimestampMs, Status) ->
    ?INFO("Uid: ~s, tsms: ~p, Status: ~p", [User, TimestampMs, Status]),
    mod_active_users:update_last_activity(User, TimestampMs, Resource),
    model_accounts:set_last_activity(User, TimestampMs, Status).


-spec broadcast_presence(User :: binary(), Server :: binary(),
        TimestampMs :: undefined | integer(), Status :: undefined | activity_status()) -> ok.
broadcast_presence(User, _Server, TimestampMs, Status) ->
    LastSeen = case TimestampMs of
        undefined -> undefined;
        _ -> util:ms_to_sec(TimestampMs)
    end,
    Presence = #pb_presence{id = util_id:new_short_id(), from_uid = User, uid = User,
            type = Status, last_seen = LastSeen},
    BroadcastUIDs = mod_presence_subscription:get_broadcast_uids(User),
    ?INFO("Uid: ~s, BroadcastUIDs: ~p, status: ~p", [User, BroadcastUIDs, Status]),
    route_multiple(BroadcastUIDs, Presence).


-spec route_multiple(BroadcastUIDs :: [uid()], Packet :: stanza()) -> ok.
route_multiple([], _) ->
    ok;
route_multiple(BroadcastUIDs, Packet) ->
    FromUid = pb:get_from(Packet),
    ejabberd_router:route_multicast(FromUid, BroadcastUIDs, Packet).


-spec check_and_probe_contacts_presence(User :: binary(), Server :: binary(),
        Status :: undefined | activity_status()) -> ok.
check_and_probe_contacts_presence(User, Server, available) ->
    SubscribedUids = mod_presence_subscription:get_subscribed_uids(User),
    lists:foreach(fun(Ouid) ->
                    probe_and_send_presence(User, Server, Ouid)
                 end, SubscribedUids);
check_and_probe_contacts_presence(_User, _Server, away) ->
    %% Not necessary to probe users since client is away.
    ok.


-spec check_and_send_presence(ToUid :: uid(), Activity :: activity(), FromUid :: uid()) -> ok.
check_and_send_presence(_, #activity{status = undefined}, _) ->
    ok;
check_and_send_presence(ToUid, #activity{status = available} = Activity, FromUid) ->
    ?INFO("FromUid: ~s, ToUid: ~s, activity: ~p", [FromUid, ToUid, Activity]),
    Packet = #pb_presence{id = util_id:new_short_id(), from_uid = FromUid, to_uid = ToUid,
            uid = FromUid, type = available},
    ejabberd_router:route(Packet);
check_and_send_presence(ToUid,
        #activity{last_activity_ts_ms = LastSeen, status = away} = Activity, FromUid) ->
    ?INFO("FromUid: ~s, ToUid: ~s, activity: ~p", [FromUid, ToUid, Activity]),
    Packet = #pb_presence{id = util_id:new_short_id(), from_uid = FromUid, to_uid = ToUid, uid = FromUid,
            type = away, last_seen = util:ms_to_sec(LastSeen)},
    ejabberd_router:route(Packet).



