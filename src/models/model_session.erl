%%%------------------------------------------------------------------------------------
%%% File: model_session.erl
%%% Copyright (C) 2020, HalloApp, Inc.
%%%
%%% This model implements redis operations on sessions.
%%%
%%%------------------------------------------------------------------------------------
-module(model_session).
-author("nikola").

-include("logger.hrl").
-include("ha_types.hrl").
-include("redis_keys.hrl").
-include("ejabberd_sm.hrl").

%% API
-export([
    set_session/2,
    del_session/2,
    get_session/2,
    get_sessions/1,
    get_active_sessions/1,
    get_passive_sessions/1
]).


%% Export all functions for unit tests
-ifdef(TEST).
-export([
    sessions_key/1
]).
-endif.
-compile([{nowarn_unused_function, [
    {q, 1},
    {qp, 1}
]}]).

%%====================================================================
%% API
%%====================================================================


-spec set_session(Uid :: uid(), Session :: session()) -> {ok, maybe(pid())}.
set_session(Uid, Session) ->
    SBin = term_to_binary(Session),
    SID = Session#session.sid,
    SIDKey = term_to_binary(SID),
    {ok, _} = q(["HSET", sessions_key(Uid), SIDKey, SBin]),
    ok.


-spec del_session(Uid :: uid(), Session :: session()) -> ok.
del_session(Uid, Session) ->
    SID = Session#session.sid,
    {ok, _} = q(["HDEL", sessions_key(Uid), term_to_binary(SID)]),
    ok.


-spec get_sessions(Uid :: binary()) -> [session()].
get_sessions(Uid) ->
    {ok, SessionsBin} = q(["HVALS", sessions_key(Uid)]),
    Results = lists:map(fun binary_to_term/1, SessionsBin),
    lists:map(fun upgrade_session/1, Results).


-spec get_session(Uid :: binary(), SID :: term()) -> session().
get_session(Uid, SID) ->
    SIDKey = term_to_binary(SID),
    case q(["HGET", sessions_key(Uid), SIDKey]) of
        {ok, undefined} -> {error, missing};
        {ok, SessionBin} -> {ok, upgrade_session(binary_to_term(SessionBin))}
    end.


-spec get_active_sessions(Uid :: binary()) -> [session()]. 
get_active_sessions(Uid) ->
    lists:filter(
        fun(#session{mode = active}) -> true;
            (_) -> false
        end, get_sessions(Uid)).


-spec get_passive_sessions(Uid :: binary()) -> [session()].
get_passive_sessions(Uid) ->
    lists:filter(
        fun(#session{mode = passive}) -> true;
            (_) -> false
        end, get_sessions(Uid)).


% TODO: make sure this warning don't happen, then we can clean up.
upgrade_session(#session{} = Session) -> Session;
upgrade_session({session, SID, USR, US, Priority, _Mode, Info}) ->
    ?WARNING("Should not happen SID:~p", [SID]),
    #session{sid = SID, usr = USR, us = US, priority = Priority, info = Info};
upgrade_session({session, SID, USR, US, Priority, Info}) ->
    ?WARNING("Should not happen SID:~p", [SID]),
    Mode = proplists:get_value(mode, Info),
    #session{sid = SID, usr = USR, us = US, priority = Priority, mode = Mode, info = Info}.


% TODO: if you pass the wrong client name for example 'ecredis_food' you get strange error.
% Instead you should get bad_client or client_not_initialized
q(Command) -> ecredis:q(ecredis_sessions, Command).
qp(Commands) -> ecredis:qp(ecredis_sessions, Commands).


-spec sessions_key(Uid :: uid()) -> binary().
sessions_key(Uid) when is_binary(Uid) ->
    <<?SESSIONS_KEY/binary, "{", Uid/binary, "}">>.

