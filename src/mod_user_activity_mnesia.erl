%%%----------------------------------------------------------------------
%%% File    : mod_contacts_mnesia.erl
%%%
%%% Copyright (C) 2020 halloappinc.
%%%
%%% This module handles all the mnesia related queries with user activity to
%%% - store a user's activity status into an mnesia table
%%% - get the user's activity status
%%% - delete the user's activity record.
%%%----------------------------------------------------------------------

-module(mod_user_activity_mnesia).
-author('murali').
-include("logger.hrl").
-include("xmpp.hrl").
-include("translate.hrl").
-include("mod_user_activity.hrl").

%% API
-export([init/2, close/1, get_user_activity/2, store_user_activity/4, remove_user/2]).

%%%===================================================================
%%% API
%%%===================================================================
init(_Host, _Opts) ->
    ejabberd_mnesia:create(?MODULE, user_activity,
               [{disc_copies, [node()]},
                {type, set},
                {attributes, record_info(fields, user_activity)}]).


close(_Host) ->
    ok.


-spec get_user_activity(binary(), binary()) -> {ok, #user_activity{}} | {error, any()}.
get_user_activity(User, Server) ->
    Username = {User, Server},
    F = fun() ->
            case mnesia:match_object(#user_activity{username = Username, _ = '_'}) of
                [] -> undefined;
                [#user_activity{} = UserActivity] -> UserActivity
            end
        end,
    case mnesia:transaction(F) of
        {atomic, Result} -> {ok, Result};
        {aborted, _} -> {error, db_failure}
    end.


-spec store_user_activity(binary(), binary(), binary(), statusType()) ->
                                                         {ok, any()} | {error, any()}.
store_user_activity(User, Server, LastSeen, Status)
                                    when Status == available; Status == away ->
    Username = {User, Server},
    F = fun() ->
            mnesia:write(#user_activity{username = Username,
                            last_seen = LastSeen,
                            status = Status})
        end,
    case mnesia:transaction(F) of
        {atomic, Result} -> {ok, Result};
        {aborted, _} -> {error, db_failure}
    end.


-spec remove_user(binary(), binary()) -> {ok, any()} | {error, any()}.
remove_user(User, Server) ->
    Username = {User, Server},
    F = fun() ->
            mnesia:delete({user_activity, Username})
        end,
    case mnesia:transaction(F) of
        {atomic, Result} -> {ok, Result};
        {aborted, _} -> {error, db_failure}
    end.

