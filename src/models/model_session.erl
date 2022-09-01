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
    get_passive_sessions/1,
    set_static_key_session/2,
    del_static_key_session/2,
    get_static_key_sessions/1
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


-spec set_session(Uid :: uid(), Session :: session()) -> ok | {error, any()}.
set_session(Uid, Session) ->
    SBin = term_to_binary(Session),
    SID = Session#session.sid,
    SIDKey = term_to_binary(SID),
    util_redis:verify_ok(q(["HSET", sessions_key(Uid), SIDKey, SBin])).


-spec del_session(Uid :: uid(), Session :: session()) -> ok | {error, any()}.
del_session(Uid, Session) ->
    SID = Session#session.sid,
    util_redis:verify_ok(q(["HDEL", sessions_key(Uid), term_to_binary(SID)])).


-spec get_sessions(Uid :: binary()) -> [session()].
get_sessions(Uid) ->
    {ok, SessionsBin} = q(["HVALS", sessions_key(Uid)]),
    lists:map(fun binary_to_term/1, SessionsBin).


-spec get_session(Uid :: binary(), SID :: term()) -> {ok, session()} | {error, any()}.
get_session(Uid, SID) ->
    SIDKey = term_to_binary(SID),
    case q(["HGET", sessions_key(Uid), SIDKey]) of
        {ok, undefined} -> {error, missing};
        {ok, SessionBin} -> {ok, binary_to_term(SessionBin)}
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


-spec set_static_key_session(StaticKey :: binary(), Session :: session()) -> ok | {error, any()}.
set_static_key_session(StaticKey, Session) ->
    SBin = term_to_binary(Session),
    SID = Session#session.sid,
    SIDKey = term_to_binary(SID),
    case q(["HSET", static_key_sessions_key(StaticKey), SIDKey, SBin]) of
        {ok, _} -> ok;
        Error -> Error
    end.


-spec del_static_key_session(StaticKey :: binary(), Session :: session()) -> ok.
del_static_key_session(StaticKey, Session) ->
    SID = Session#session.sid,
    {ok, _} = q(["HDEL", static_key_sessions_key(StaticKey), term_to_binary(SID)]),
    ok.

-spec get_static_key_sessions(StaticKey :: binary()) -> [session()].
get_static_key_sessions(StaticKey) ->
    {ok, SessionsBin} = q(["HVALS", static_key_sessions_key(StaticKey)]),
    lists:map(fun binary_to_term/1, SessionsBin).

% TODO: if you pass the wrong client name for example 'ecredis_food' you get strange error.
% Instead you should get bad_client or client_not_initialized
q(Command) -> ecredis:q(ecredis_sessions, Command).
qp(Commands) -> ecredis:qp(ecredis_sessions, Commands).


-spec sessions_key(Uid :: uid()) -> binary().
sessions_key(Uid) when is_binary(Uid) ->
    <<?SESSIONS_KEY/binary, "{", Uid/binary, "}">>.

-spec static_key_sessions_key(StaticKey :: binary()) -> binary().
static_key_sessions_key(StaticKey) ->
    <<?STATIC_KEY_SESSIONS_KEY/binary, "{", StaticKey/binary, "}">>.

