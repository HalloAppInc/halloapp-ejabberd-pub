%%%----------------------------------------------------------------------
%%% File    : mod_presence_subscription_mnesia.erl
%%%
%%% Copyright (C) 2020 halloappinc.
%%%
%%% This module handles all the mnesia related queries with presence_subs
%%% - when a user requests to subscribe/unsubscribe to their friends presence.
%%% - fetch all subscriptions of a user
%%% - fetch all friends of the user who subscribed to user's presence
%%% - when a user unsubscribe from all friends
%%% - when a user is completeley removed.
%%%----------------------------------------------------------------------

-module(mod_presence_subscription_mnesia).
-author('murali').
-include("presence_subs.hrl").

%% API
-export([init/2, close/1, get_user_subscribed_friends/2, get_user_broadcast_friends/2,
        subscribe_user_to_friend/3, unsubscribe_user_to_friend/3,
        unsubscribe_user_to_all/2, remove_user/2]).

%%%===================================================================
%%% API
%%%===================================================================
init(_Host, _Opts) ->
    ejabberd_mnesia:create(?MODULE, presence_subs,
               [{disc_copies, [node()]},
                {type, bag},
                {attributes, record_info(fields, presence_subs)},
                {index, [userid]}]).


close(_Host) ->
    ok.


-spec get_user_subscribed_friends(binary(), binary()) -> {ok, [#presence_subs{}]} | {error, any()}.
get_user_subscribed_friends(User, Server) ->
    SubscriberId = {User, Server},
    F = fun() ->
            mnesia:read({presence_subs, SubscriberId})
        end,
    case mnesia:transaction(F) of
        {atomic, Result} -> {ok, Result};
        {aborted, _} -> {error, db_failure}
    end.


-spec get_user_broadcast_friends(binary(), binary()) -> {ok, [#presence_subs{}]} | {error, any()}.
get_user_broadcast_friends(User, Server) ->
    FriendId = {User, Server},
    F = fun() ->
            mnesia:index_read(presence_subs, FriendId, #presence_subs.userid)
        end,
    case mnesia:transaction(F) of
        {atomic, Result} -> {ok, Result};
        {aborted, _} -> {error, db_failure}
    end.


-spec subscribe_user_to_friend(binary(), binary(), binary()) -> {ok, any()} | {error, any()}.
subscribe_user_to_friend(User, Server, Friend) ->
    SubscriberId = {User, Server},
    FriendId = {Friend, Server},
    F = fun() ->
            mnesia:write(#presence_subs{subscriberid = SubscriberId, userid = FriendId})
        end,
    case mnesia:transaction(F) of
        {atomic, Result} -> {ok, Result};
        {aborted, _} -> {error, db_failure}
    end.


-spec unsubscribe_user_to_friend(binary(), binary(), binary()) -> {ok, any()} | {error, any()}.
unsubscribe_user_to_friend(User, Server, Friend) ->
    SubscriberId = {User, Server},
    FriendId = {Friend, Server},
    F = fun() ->
            mnesia:delete_object(#presence_subs{subscriberid = SubscriberId, userid = FriendId})
        end,
    case mnesia:transaction(F) of
        {atomic, Result} -> {ok, Result};
        {aborted, _} -> {error, db_failure}
    end.


-spec unsubscribe_user_to_all(binary(), binary()) -> {ok, any()} | {error, any()}.
unsubscribe_user_to_all(User, Server) ->
    SubscriberId = {User, Server},
    F = fun() ->
            mnesia:delete({presence_subs, SubscriberId})
        end,
    case mnesia:transaction(F) of
        {atomic, Result} -> {ok, Result};
        {aborted, _} -> {error, db_failure}
    end.


-spec remove_user(binary(), binary()) -> {ok, any()} | {error, any()}.
remove_user(User, Server) ->
    SubscriberId = {User, Server},
    F = fun() ->
            mnesia:delete({presence_subs, SubscriberId}),
            lists:foreach(fun(PresenceSubsRecord) ->
                            mnesia:delete_object(PresenceSubsRecord)
                          end, mnesia:index_read(presence_subs, SubscriberId,
                                                    #presence_subs.userid))
        end,
    case mnesia:transaction(F) of
        {atomic, Result} -> {ok, Result};
        {aborted, _} -> {error, db_failure}
    end.


