%%%----------------------------------------------------------------------------------------------
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
%%% This module also handles all the presence stanzas of type subscribe/unsubscribe.
%%%----------------------------------------------------------------------------------------------

-module(mod_presence_subscription).
-author('murali').
-behaviour(gen_mod).

-include("logger.hrl").
-include("xmpp.hrl").
-include("presence_subs.hrl").


%% gen_mod API.
-export([start/2, stop/1, reload/3, depends/2, mod_options/1]).

%% API and hooks.
-export([
    presence_subs_hook/3,
    unset_presence_hook/4,
    re_register_user/3,
    remove_user/2,
    subscribe_user_to_friend/3,
    unsubscribe_user_to_friend/3,
    get_user_subscribed_friends/2,
    get_user_broadcast_friends/2
]).


start(Host, _Opts) ->
    ejabberd_hooks:add(presence_subs_hook, Host, ?MODULE, presence_subs_hook, 1),
    ejabberd_hooks:add(unset_presence_hook, Host, ?MODULE, unset_presence_hook, 1),
    ejabberd_hooks:add(re_register_user, Host, ?MODULE, re_register_user, 50),
    ejabberd_hooks:delete(remove_user, Host, ?MODULE, remove_user, 10).

stop(Host) ->
    ejabberd_hooks:delete(presence_subs_hook, Host, ?MODULE, presence_subs_hook, 1),
    ejabberd_hooks:delete(unset_presence_hook, Host, ?MODULE, unset_presence_hook, 1),
    ejabberd_hooks:delete(re_register_user, Host, ?MODULE, re_register_user, 50),
    ejabberd_hooks:delete(remove_user, Host, ?MODULE, remove_user, 10).

depends(_Host, _Opts) ->
    [].

mod_options(_Host) ->
    [].

reload(_Host, _NewOpts, _OldOpts) ->
    ok.

%%====================================================================
%% hooks
%%====================================================================

-spec re_register_user(Uid :: binary(), Server :: binary(),
        Phone :: binary()) -> {ok, any()} | {error, any()}.
re_register_user(Uid, _Server, _Phone) ->
    presence_unsubscribe_all(Uid).


-spec remove_user(Uid :: binary(), Server :: binary()) -> ok.
remove_user(Uid, _Server) ->
    presence_unsubscribe_all(Uid).


-spec unset_presence_hook(Uid :: binary(), Server :: binary(),
        Resource :: binary(), Status :: binary()) -> {ok, any()} | {error, any()}.
unset_presence_hook(Uid, _Server, _Resource, _Status) ->
    presence_unsubscribe_all(Uid).


-spec presence_unsubscribe_all(Uid :: binary()) -> ok.
presence_unsubscribe_all(Uid) ->
    ?INFO("Uid: ~s, unsubscribe_all", [Uid]),
    model_accounts:presence_unsubscribe_all(Uid).


-spec presence_subs_hook(User :: binary(), Server :: binary(),
        Presence :: presence()) -> {ok, any()} | {error, any()}.
presence_subs_hook(User, Server, #presence{to = #jid{user = Friend}, type = Type}) ->
    case Type of
        subscribe ->
            check_and_subscribe_user_to_friend(User, Server, Friend);
        unsubscribe ->
            ?INFO("Uid: ~s, unsubscribe_all", [User]),
            unsubscribe_user_to_friend(User, Server, Friend)
    end.


%%====================================================================
%% API
%%====================================================================

-spec subscribe_user_to_friend(User :: binary(), Server :: binary(),
        Friend :: binary()) -> {ok, any()} | {error, any()}.
subscribe_user_to_friend(User, _, User) ->
    {ok, ignore_self_subscribe};
subscribe_user_to_friend(User, _Server, Friend) ->
    ?INFO("Uid: ~s, Friend: ~s", [User, Friend]),
    model_accounts:presence_subscribe(User, Friend).


-spec unsubscribe_user_to_friend(User :: binary(), Server :: binary(),
        Friend :: binary()) -> {ok, any()} | {error, any()}.
unsubscribe_user_to_friend(User, _Server, Friend) ->
    ?INFO("Uid: ~s, Friend: ~s", [User, Friend]),
    model_accounts:presence_unsubscribe(User, Friend).


-spec get_user_subscribed_friends(User :: binary(), Server :: binary()) -> [binary()].
get_user_subscribed_friends(User, _Server) ->
    {ok, Result} = model_accounts:get_subscribed_uids(User),
    Result.


-spec get_user_broadcast_friends(User :: binary(), Server :: binary()) -> [binary()].
get_user_broadcast_friends(User, _Server) ->
    {ok, Result} = model_accounts:get_broadcast_uids(User),
    Result.


%%====================================================================
%% Internal functions
%%====================================================================

-spec check_and_subscribe_user_to_friend(User :: binary(), Server :: binary(),
        Friend :: binary()) -> ignore | ok | {ok, any()} | {error, any()}.
check_and_subscribe_user_to_friend(User, Server, Friend) ->
    case model_friends:is_friend(User, Friend) of
        false ->
            ?INFO("ignore presence_subscribe, Uid: ~s, FriendUid: ~s", [User, Friend]),
            ignore;
        true ->
            ?INFO("accept presence_subscribe, Uid: ~s, FriendUid: ~s", [User, Friend]),
            subscribe_user_to_friend(User, Server, Friend),
            mod_user_activity:probe_and_send_presence(User, Server, Friend)
    end.



