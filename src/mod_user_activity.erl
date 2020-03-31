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
%%%------------------------------------------------------------------------------------

-module(mod_user_activity).
-author('murali').
-behaviour(gen_mod).

-include("logger.hrl").
-include("xmpp.hrl").
-include("mod_user_activity.hrl").
-include("translate.hrl").

%% gen_mod API.
-export([start/2, stop/1, reload/3, depends/2, mod_options/1]).
%% hooks.
-export([set_presence_hook/4, unset_presence_hook/4, register_user/2, remove_user/2]).
%% API
-export([get_user_activity/2, probe_and_send_presence/3]).


start(Host, Opts) ->
    mod_user_activity_mnesia:init(Host, Opts),
    ejabberd_hooks:add(set_presence_hook, Host, ?MODULE, set_presence_hook, 1),
    ejabberd_hooks:add(unset_presence_hook, Host, ?MODULE, unset_presence_hook, 1),
    ejabberd_hooks:add(register_user, Host, ?MODULE, register_user, 50),
    ejabberd_hooks:add(remove_user, Host, ?MODULE, remove_user, 50).

stop(Host) ->
    mod_user_activity_mnesia:close(Host),
    ejabberd_hooks:delete(set_presence_hook, Host, ?MODULE, set_presence_hook, 1),
    ejabberd_hooks:delete(unset_presence_hook, Host, ?MODULE, unset_presence_hook, 1),
    ejabberd_hooks:delete(register_user, Host, ?MODULE, register_user, 50),
    ejabberd_hooks:delete(remove_user, Host, ?MODULE, remove_user, 50).

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
    Timestamp = util:convert_timestamp_to_binary(erlang:timestamp()),
    store_user_activity(User, Server, Timestamp, Status).


%% remove_user hook deletes the last known activity of the user.
-spec remove_user(binary(), binary()) -> {ok, any()} | {error, any()}.
remove_user(User, Server) ->
    mod_user_activity_mnesia:remove_user(User, Server).


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

-spec get_user_activity(binary(), binary()) -> {binary(), atom()}.
get_user_activity(User, Server) ->
    case mod_user_activity_mnesia:get_user_activity(User, Server) of
        {ok, #user_activity{last_seen = LastSeen, status = Status}} -> {LastSeen, Status};
        {ok, undefined} -> {<<"">>, away};
        {error, _} -> {<<"">>, away}
    end.


-spec probe_and_send_presence(binary(), binary(), binary()) -> ok.
probe_and_send_presence(User, Server, Friend) ->
    ToJID = jid:make(User, Server),
    FromJID = jid:make(Friend, Server),
    {LastSeen, Status} = mod_user_activity:get_user_activity(Friend, Server),
    check_and_send_presence(FromJID, {LastSeen, Status}, ToJID).

%%====================================================================
%% Internal functions
%%====================================================================


-spec store_and_broadcast_presence(binary(), binary(), atom()) -> ok | {ok, any()}.
store_and_broadcast_presence(_, _, undefined) ->
    {ok, ignore_undefined_presence};
store_and_broadcast_presence(User, Server, away) ->
    Timestamp = util:convert_timestamp_to_binary(erlang:timestamp()),
    case get_user_activity(User, Server) of
        {_, away} ->
            {ok, ignore_away_presence};
        _ ->
            store_user_activity(User, Server, Timestamp, away),
            broadcast_presence(User, Server, Timestamp, away)
    end;
store_and_broadcast_presence(User, Server, available) ->
    Timestamp = util:convert_timestamp_to_binary(erlang:timestamp()),
    store_user_activity(User, Server, Timestamp, available),
    broadcast_presence(User, Server, Timestamp, available).


-spec store_user_activity(binary(), binary(), binary(), atom()) -> {ok, any()} | {error, any()}.
store_user_activity(User, Server, Timestamp, Status) ->
    mod_user_activity_mnesia:store_user_activity(User, Server, Timestamp, Status).


-spec broadcast_presence(binary(), binary(), binary(), atom()) -> ok.
broadcast_presence(User, Server, Timestamp, Status) ->
    Presence = #presence{from = jid:make(User, Server), type = Status, last_seen = Timestamp},
    BroadcastJIDs = mod_presence_subscription:get_user_broadcast_friends(User, Server),
    route_multiple(Server, BroadcastJIDs, Presence).


-spec route_multiple(binary(), [jid()], stanza()) -> ok.
route_multiple(_, [], _) ->
    ok;
route_multiple(Server, JIDs, Packet) ->
    From = xmpp:get_from(Packet),
    ejabberd_router_multicast:route_multicast(From, Server, JIDs, Packet).


-spec check_and_probe_friends_presence(binary(), binary(), atom()) -> ok.
check_and_probe_friends_presence(User, Server, available) ->
    SubscribedFriends = mod_presence_subscription:get_user_subscribed_friends(User, Server),
    lists:foreach(fun({Friend, _ServerHost}) ->
                    probe_and_send_presence(User, Server, Friend)
                 end, SubscribedFriends);
check_and_probe_friends_presence(_User, _Server, _) ->
    ok.


-spec check_and_send_presence(#jid{}, {binary(), atom()}, #jid{}) -> ok.
check_and_send_presence(_, {_, undefined}, _) ->
    ok;
check_and_send_presence(FromJID, {_, available}, ToJID) ->
    Packet = #presence{from = FromJID, to = ToJID, type = available},
    ejabberd_router:route(Packet);
check_and_send_presence(FromJID, {LastSeen, away}, ToJID) ->
    Packet = #presence{from = FromJID, to = ToJID, type = away, last_seen = LastSeen},
    ejabberd_router:route(Packet).


