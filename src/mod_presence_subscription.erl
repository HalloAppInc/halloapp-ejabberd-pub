%%%----------------------------------------------------------------------
%%% File    : mod_presence_subscription.erl
%%%
%%% Copyright (C) 2020 halloappinc.
%%%
%%% This file handles storing and retrieving user's subscriptions to 
%%% their friend's presence, and also friends who subscribed to 
%%% a user's presence. This is useful to be able to fetch user's friends presence
%%% and broadcast a user's presence.
%%% This module also helps in retreiving the list of usernames the user is subscribed in
%%% to be able to fetch their last_seen directly from mod_user_activity.
%%% This module also fetches the list of jids of the friends to directly
%%% broadcast a user's presence to them.
%%%----------------------------------------------------------------------

-module(mod_presence_subscription).
-author('murali').
-behaviour(gen_mod).

-include("logger.hrl").
-include("xmpp.hrl").
-include("presence_subs.hrl").


%% gen_mod API.
-export([start/2, stop/1, reload/3, depends/2, mod_options/1]).
%% hooks.
-export([unset_presence_hook/4, remove_user/2]).
%% API
-export([subscribe_user_to_friend/3, unsubscribe_user_to_friend/3,
        get_user_subscribed_friends/2, get_user_broadcast_friends/2]).


start(Host, Opts) ->
    mod_presence_subscription_mnesia:init(Host, Opts),
    ejabberd_hooks:add(unset_presence_hook, Host, ?MODULE, unset_presence_hook, 1),
    ejabberd_hooks:add(remove_user, Host, ?MODULE, remove_user, 50).

stop(Host) ->
    mod_presence_subscription_mnesia:close(Host),
    ejabberd_hooks:delete(unset_presence_hook, Host, ?MODULE, unset_presence_hook, 1),
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

-spec remove_user(binary(), binary()) -> {ok, any()} | {error, any()}.
remove_user(User, Server) ->
    mod_presence_subscription_mnesia:remove_user(User, Server).

-spec unset_presence_hook(binary(), binary(), binary(), binary()) -> {ok, any()} | {error, any()}.
unset_presence_hook(User, Server, _Resource, _Status) ->
    mod_presence_subscription_mnesia:unsubscribe_user_to_all(User, Server).

%%====================================================================
%% API
%%====================================================================

-spec subscribe_user_to_friend(binary(), binary(), binary()) -> {ok, any()} | {error, any()}.
subscribe_user_to_friend(User, Server, Friend) ->
    mod_presence_subscription_mnesia:subscribe_user_to_friend(User, Server, Friend).


-spec unsubscribe_user_to_friend(binary(), binary(), binary()) -> {ok, any()} | {error, any()}.
unsubscribe_user_to_friend(User, Server, Friend) ->
    mod_presence_subscription_mnesia:unsubscribe_user_to_friend(User, Server, Friend).


-spec get_user_subscribed_friends(binary(), binary()) -> [{binary(), binary()}].
get_user_subscribed_friends(User, Server) ->
    case mod_presence_subscription_mnesia:get_user_subscribed_friends(User, Server) of
        {ok, []} -> [];
        {ok, UserSubscriptions} ->
            lists:map(fun(PresenceSubsRecord) ->
                            PresenceSubsRecord#presence_subs.userid
                          end, UserSubscriptions);
        {error, _} -> []
    end.


-spec get_user_broadcast_friends(binary(), binary()) -> [#jid{}].
get_user_broadcast_friends(User, Server) ->
    case mod_presence_subscription_mnesia:get_user_broadcast_friends(User, Server) of
        {ok, []} -> [];
        {ok, PresenceSubscriptions} ->
            lists:map(fun(#presence_subs{subscriberid = {Friend, ServerHost}}) ->
                            jid:make(Friend, ServerHost)
                          end, PresenceSubscriptions);
        {error, _} -> []
    end.


