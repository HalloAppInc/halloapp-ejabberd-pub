%%%------------------------------------------------------------------------------------
%%% File: model_session.erl
%%% Copyright (C) 2020, HalloApp, Inc.
%%%
%%% This model implements redis operations on sessions.
%%%
%%%------------------------------------------------------------------------------------
-module(model_session).
-author("nikola").
-behavior(gen_mod).

-include("logger.hrl").
-include("ha_types.hrl").
-include("redis_keys.hrl").
-include("ejabberd_sm.hrl").

%% gen_mod callbacks
-export([start/2, stop/1, depends/2, mod_options/1]).


%% API
-export([
    set_session/2,
    del_session/2,
    get_sessions/1,
    get_pid/1
]).


%% Export all functions for unit tests
-ifdef(TEST).
-export([
    pid_key/1,
    sessions_key/1
]).
-endif.


%%====================================================================
%% gen_mod callbacks
%%====================================================================

start(_Host, _Opts) ->
    ok.

stop(_Host) ->
    ok.

depends(_Host, _Opts) ->
    [].

mod_options(_Host) ->
    [].

%%====================================================================
%% API
%%====================================================================


-spec set_session(Uid :: uid(), Session :: session()) -> {ok, maybe(pid())}.
set_session(Uid, Session) ->
    SBin = term_to_binary(Session),
    SID = Session#session.sid,
    SIDKey = term_to_binary(SID),
    {_Ts, Pid} = SID,
    [{ok, OldPidBin}, {ok, _}] = qp([
        ["GETSET", pid_key(Uid), term_to_binary(Pid)],
        ["HSET", sessions_key(Uid), SIDKey, SBin]
    ]),
    OldPid = case OldPidBin of
        undefined -> undefined;
        _ -> binary_to_term(OldPidBin)
    end,
    {ok, OldPid}.


-spec del_session(Uid :: uid(), Session :: session()) -> ok.
del_session(Uid, Session) ->
    SID = Session#session.sid,
    {_Ts, Pid} = SID,
    % TODO: implement this using lua script to avoid race conditions
    {ok, CurPidBin} = q(["GET", pid_key(Uid)]),
    CurPid = case CurPidBin of
        undefined -> undefined;
        _ -> binary_to_term(CurPidBin)
    end,
    Commands = [["HDEL", sessions_key(Uid), term_to_binary(SID)]],
    Commands2 = case Pid =:= CurPid of
        true -> [["DEL", pid_key(Uid)] | Commands];
        false -> Commands
    end,
    _ = qp(Commands2),
    ok.


-spec get_sessions(Uid :: binary()) -> [session()].
get_sessions(Uid) ->
    {ok, SessionsBin} = q(["HVALS", sessions_key(Uid)]),
    Results = lists:map(fun binary_to_term/1, SessionsBin),
    lists:map(fun upgrade_session/1, Results).


-spec get_pid(Uid :: binary()) -> maybe(pid()).
get_pid(Uid) ->
    {ok, PidBin} = q(["GET", pid_key(Uid)]),
    case PidBin of
        undefined -> undefined;
        _ -> binary_to_term(PidBin)
    end.

% TODO: if you pass the wrong client name for example 'ecredis_food' you get strange error.
% Instead you should get bad_client or client_not_initialized
q(Command) -> ecredis:q(ecredis_sessions, Command).
qp(Commands) -> ecredis:qp(ecredis_sessions, Commands).

upgrade_session(#session{} = Session) -> Session;
upgrade_session({session, SID, USR, US, Priority, _Mode, Info}) ->
    #session{sid = SID, usr = USR, us = US, priority = Priority, info = Info};
upgrade_session({session, SID, USR, US, Priority, Info}) ->
    Mode = proplists:get_value(mode, Info),
    #session{sid = SID, usr = USR, us = US, priority = Priority, mode = Mode, info = Info}.


-spec pid_key(Uid :: uid()) -> binary().
pid_key(Uid) when is_binary(Uid) ->
    <<?PID_KEY/binary, "{", Uid/binary, "}">>.

-spec sessions_key(Uid :: uid()) -> binary().
sessions_key(Uid) when is_binary(Uid) ->
    <<?SESSIONS_KEY/binary, "{", Uid/binary, "}">>.

