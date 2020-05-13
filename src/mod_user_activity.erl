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
-include("account.hrl").
-include("translate.hrl").

%% gen_mod API.
-export([start/2, stop/1, reload/3, depends/2, mod_options/1]).
%% hooks.
-export([
    set_presence_hook/4,
    unset_presence_hook/4,
    register_user/2,
    remove_user/2,
    re_register_user/2
]).

%% API
-export([
    get_user_activity/2,
    probe_and_send_presence/3
]).


start(Host, Opts) ->
    mod_user_activity_mnesia:init(Host, Opts),
    ejabberd_hooks:add(set_presence_hook, Host, ?MODULE, set_presence_hook, 1),
    ejabberd_hooks:add(unset_presence_hook, Host, ?MODULE, unset_presence_hook, 1),
    ejabberd_hooks:add(register_user, Host, ?MODULE, register_user, 50),
    ejabberd_hooks:add(remove_user, Host, ?MODULE, remove_user, 50),
    ejabberd_hooks:add(re_register_user, Host, ?MODULE, re_register_user, 50).

stop(Host) ->
    mod_user_activity_mnesia:close(Host),
    ejabberd_hooks:delete(set_presence_hook, Host, ?MODULE, set_presence_hook, 1),
    ejabberd_hooks:delete(unset_presence_hook, Host, ?MODULE, unset_presence_hook, 1),
    ejabberd_hooks:delete(register_user, Host, ?MODULE, register_user, 50),
    ejabberd_hooks:delete(remove_user, Host, ?MODULE, remove_user, 50),
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
-spec register_user(binary(), binary()) -> {ok, any()} | {error, any()}.
register_user(User, Server) ->
    Status = undefined,
    TimestampMs = util:now_ms(),
    store_user_activity(User, Server, TimestampMs, Status).


%% remove_user hook deletes the last known activity of the user.
-spec remove_user(binary(), binary()) -> {ok, any()} | {error, any()}.
remove_user(User, Server) ->
    mod_user_activity_mnesia:remove_user(User, Server).


-spec re_register_user(User :: binary(), Server :: binary()) -> ok.
re_register_user(User, Server) ->
    register_user(User, Server).


%% set_presence_hook checks and stores the user activity, and also broadcast users presence
%% to their subscribed friends and probes their friends presence that the user subscribed to
%% and sends it to the user.
-spec set_presence_hook(binary(), binary(), binary(), #presence{}) -> ok.
set_presence_hook(User, Server, _Resource, #presence{type = Type}) ->
    Status = case Type of
                available -> available;
                away -> away;
                unavailable -> away;
                _ -> undefined
            end,
    store_and_broadcast_presence(User, Server, Status),
    check_and_probe_friends_presence(User, Server, Status).


-spec unset_presence_hook(binary(), binary(), binary(), binary()) -> ok.
unset_presence_hook(User, Server, _Resource, _PStatus) ->
    store_and_broadcast_presence(User, Server, away).


%%====================================================================
%% API
%%====================================================================

-spec get_user_activity(binary(), binary()) -> activity().
get_user_activity(User, Server) ->
    {ok, Activity} = model_accounts:get_last_activity(User),
    {ok, UserActivity} = mod_user_activity_mnesia:get_user_activity(User, Server),
    compare_activity_result(Activity, UserActivity),
    Activity.


-spec probe_and_send_presence(binary(), binary(), binary()) -> ok.
probe_and_send_presence(User, Server, Friend) ->
    ToJID = jid:make(User, Server),
    FromJID = jid:make(Friend, Server),
    Activity = get_user_activity(Friend, Server),
    check_and_send_presence(FromJID, Activity, ToJID).

%%====================================================================
%% Internal functions
%%====================================================================


-spec store_and_broadcast_presence(binary(), binary(), atom()) -> ok | {ok, any()}.
store_and_broadcast_presence(_, _, undefined) ->
    {ok, ignore_undefined_presence};
store_and_broadcast_presence(User, Server, away) ->
    TimestampMs = util:now_ms(),
    case get_user_activity(User, Server) of
        {_, away} ->
            {ok, ignore_away_presence};
        _ ->
            store_user_activity(User, Server, TimestampMs, away),
            broadcast_presence(User, Server, TimestampMs, away)
    end;
store_and_broadcast_presence(User, Server, available) ->
    check_for_first_login(User, Server),
    TimestampMs = util:now_ms(),
    store_user_activity(User, Server, TimestampMs, available),
    broadcast_presence(User, Server, undefined, available).


-spec check_for_first_login(binary(), binary()) -> ok.
check_for_first_login(User, Server) ->
    case get_user_activity(User, Server) of
        {_, undefined} ->
            ejabberd_hooks:run(on_user_first_login, Server, [User, Server]);
        _ ->
            ok
    end.


-spec store_user_activity(binary(), binary(),
        integer(), undefined | activity_status()) -> {ok, any()} | {error, any()}.
store_user_activity(User, Server, TimestampMs, Status) ->
    mod_user_activity_mnesia:store_user_activity(User, Server,
            util:to_binary(TimestampMs), Status),
    model_accounts:set_last_activity(User, TimestampMs, Status).


-spec broadcast_presence(binary(), binary(),
        undefined | integer(), undefined | activity_status()) -> ok.
broadcast_presence(User, Server, TimestampMs, Status) ->
    LastSeen = case TimestampMs of
        undefined -> undefined;
        _ -> util:to_binary(util:ms_to_sec(TimestampMs))
    end,
    Presence = #presence{from = jid:make(User, Server),
            type = Status, last_seen = util:to_binary(LastSeen)},
    BroadcastUIDs = mod_presence_subscription:get_user_broadcast_friends(User, Server),
    BroadcastJIDs = lists:map(fun(Uid) -> jid:make(Uid, Server) end, BroadcastUIDs),
    route_multiple(Server, BroadcastJIDs, Presence).


-spec route_multiple(binary(), [jid()], stanza()) -> ok.
route_multiple(_, [], _) ->
    ok;
route_multiple(Server, JIDs, Packet) ->
    From = xmpp:get_from(Packet),
    ejabberd_router_multicast:route_multicast(From, Server, JIDs, Packet).


-spec check_and_probe_friends_presence(binary(), binary(), undefined | activity_status()) -> ok.
check_and_probe_friends_presence(User, Server, available) ->
    SubscribedFriends = mod_presence_subscription:get_user_subscribed_friends(User, Server),
    lists:foreach(fun(Friend) ->
                    probe_and_send_presence(User, Server, Friend)
                 end, SubscribedFriends);
check_and_probe_friends_presence(_User, _Server, _) ->
    ok.


-spec check_and_send_presence(jid(), activity(), jid()) -> ok.
check_and_send_presence(_, #activity{status = undefined}, _) ->
    ok;
check_and_send_presence(FromJID, #activity{status = available}, ToJID) ->
    Packet = #presence{from = FromJID, to = ToJID, type = available},
    ejabberd_router:route(Packet);
check_and_send_presence(FromJID, #activity{last_activity_ts_ms = LastSeen, status = away}, ToJID) ->
    Packet = #presence{from = FromJID, to = ToJID,
            type = away, last_seen = util:to_binary(util:ms_to_sec(LastSeen))},
    ejabberd_router:route(Packet).


%% TODO(murali@): remove this after migration.
-spec compare_activity_result(activity(), user_activity()) -> boolean().
compare_activity_result(Activity, undefined) ->
    ?WARNING_MSG("Comparing redis: ~p and mnesia: ~p, here.", [Activity, undefined]);
compare_activity_result(Activity, UserActivity) ->
    ?INFO_MSG("Comparing redis: ~p and mnesia: ~p, here.", [Activity, UserActivity]),
    case UserActivity#user_activity.last_seen of
        undefined ->
            true;
        _ ->
            TimestampRes = (Activity#activity.last_activity_ts_ms =:=
                    binary_to_integer(UserActivity#user_activity.last_seen)),
            StatusRes = (Activity#activity.status =:= UserActivity#user_activity.status),
            case TimestampRes andalso StatusRes of
                false ->
                    ?ERROR_MSG("UserActivity records dont match on mnesia: ~p and redis: ~p",
                            [UserActivity, Activity]),
                    false;
                true ->
                    true
            end
    end.


