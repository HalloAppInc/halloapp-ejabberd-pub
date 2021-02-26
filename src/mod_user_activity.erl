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
%%% Whenever a user's activity is updated, we also broadcast the activity to their friends
%%% who subscribed to this user. We also fetch the last activity of the friends the
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
    re_register_user/3,
    get_user_activity/2,
    probe_and_send_presence/3
]).


start(Host, _Opts) ->
    ejabberd_hooks:add(set_presence_hook, Host, ?MODULE, set_presence_hook, 1),
    ejabberd_hooks:add(unset_presence_hook, Host, ?MODULE, unset_presence_hook, 1),
    ejabberd_hooks:add(register_user, Host, ?MODULE, register_user, 50),
    ejabberd_hooks:add(re_register_user, Host, ?MODULE, re_register_user, 50).

stop(Host) ->
    ejabberd_hooks:delete(set_presence_hook, Host, ?MODULE, set_presence_hook, 1),
    ejabberd_hooks:delete(unset_presence_hook, Host, ?MODULE, unset_presence_hook, 1),
    ejabberd_hooks:delete(register_user, Host, ?MODULE, register_user, 50),
    ejabberd_hooks:delete(re_register_user, Host, ?MODULE, re_register_user, 50).

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


-spec re_register_user(Uid :: binary(), Server :: binary(), Phone :: binary()) -> ok.
re_register_user(Uid, Server, Phone) ->
    register_user(Uid, Server, Phone).


%% set_presence_hook checks and stores the user activity, and also broadcast users presence
%% to their subscribed friends and probes their friends presence that the user subscribed to
%% and sends it to the user.
-spec set_presence_hook(User :: binary(), Server :: binary(),
        Resource :: binary(), Presence :: presence()) -> ok.
set_presence_hook(User, Server, Resource, #pb_presence{type = StatusType}) ->
    store_and_broadcast_presence(User, Server, Resource, StatusType),
    check_and_probe_friends_presence(User, Server, StatusType).


-spec unset_presence_hook(User :: binary(), Server :: binary(),
        Resource :: binary(), PStatus :: binary()) -> ok.
unset_presence_hook(User, Server, Resource, _PStatus) ->
    store_and_broadcast_presence(User, Server, Resource, away).


%%====================================================================
%% API
%%====================================================================

-spec get_user_activity(User :: binary(), Server :: binary()) -> activity().
get_user_activity(User, _Server) ->
    {ok, Activity} = model_accounts:get_last_activity(User),
    Activity.


-spec probe_and_send_presence(Uid :: binary(), Server :: binary(), FriendUid :: binary()) -> ok.
probe_and_send_presence(Uid, Server, FriendUid) ->
    Activity = get_user_activity(FriendUid, Server),
    check_and_send_presence(Uid, Activity, FriendUid).

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
    check_for_first_login(User, Server),
    TimestampMs = util:now_ms(),
    store_user_activity(User, Server, Resource, TimestampMs, available),
    broadcast_presence(User, Server, undefined, available).


-spec check_for_first_login(User :: binary(), Server :: binary()) -> ok.
check_for_first_login(User, Server) ->
    case get_user_activity(User, Server) of
        #activity{status = undefined} ->
            ?INFO("Uid: ~s, on_user_first_login", [User]),
            ejabberd_hooks:run(on_user_first_login, Server, [User, Server]);
        _ ->
            ok
    end.


-spec store_user_activity(User :: binary(), Server :: binary(), TimestampMs :: integer(),
        Resource :: binary() | undefined, Status :: undefined | activity_status()) -> {ok, any()} | {error, any()}.
store_user_activity(User, _Server, Resource, TimestampMs, Status) ->
    ?INFO("Uid: ~s, tsms: ~p, Status: ~p", [User, TimestampMs, Status]),
    mod_active_users:update_last_activity(User, TimestampMs, Resource),
    model_accounts:set_last_activity(User, TimestampMs, Status).


-spec broadcast_presence(User :: binary(), Server :: binary(),
        TimestampMs :: undefined | integer(), Status :: undefined | activity_status()) -> ok.
broadcast_presence(User, Server, TimestampMs, Status) ->
    LastSeen = case TimestampMs of
        undefined -> undefined;
        _ -> util:ms_to_sec(TimestampMs)
    end,
    Presence = #pb_presence{from_uid = User,
            type = Status, last_seen = LastSeen},
    BroadcastUIDs = mod_presence_subscription:get_user_broadcast_friends(User, Server),
    ?INFO("Uid: ~s, BroadcastUIDs: ~p, status: ~p", [User, BroadcastUIDs, Status]),
    BroadcastJIDs = lists:map(fun(Uid) -> jid:make(Uid, Server) end, BroadcastUIDs),
    route_multiple(Server, BroadcastJIDs, Presence).


-spec route_multiple(Server :: binary(), JIDs :: [jid()], Packet :: stanza()) -> ok.
route_multiple(_, [], _) ->
    ok;
route_multiple(Server, JIDs, Packet) ->
    FromJid = jid:make(util_pb:get_from(Packet), Server),
    ejabberd_router:route_multicast(FromJid, JIDs, Packet).


-spec check_and_probe_friends_presence(User :: binary(), Server :: binary(),
        Status :: undefined | activity_status()) -> ok.
check_and_probe_friends_presence(User, Server, available) ->
    SubscribedFriends = mod_presence_subscription:get_user_subscribed_friends(User, Server),
    lists:foreach(fun(Friend) ->
                    probe_and_send_presence(User, Server, Friend)
                 end, SubscribedFriends);
check_and_probe_friends_presence(_User, _Server, away) ->
    %% Not necessary to probe friends since client is away.
    ok.


-spec check_and_send_presence(FromJID :: jid(), Activity :: activity(), ToJID :: jid()) -> ok.
check_and_send_presence(_, #activity{status = undefined}, _) ->
    ok;
check_and_send_presence(ToUid, #activity{status = available} = Activity, FromUid) ->
    ?INFO("FromUid: ~s, ToUid: ~s, activity: ~p", [FromUid, ToUid, Activity]),
    Packet = #pb_presence{from_uid = FromUid, to_uid = ToUid, type = available},
    ejabberd_router:route(Packet);
check_and_send_presence(ToUid,
        #activity{last_activity_ts_ms = LastSeen, status = away} = Activity, FromUid) ->
    ?INFO("FromUid: ~s, ToUid: ~s, activity: ~p", [FromUid, ToUid, Activity]),
    Packet = #pb_presence{from_uid = FromUid, to_uid = ToUid,
            type = away, last_seen = util:ms_to_sec(LastSeen)},
    ejabberd_router:route(Packet).



