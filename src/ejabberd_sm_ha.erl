-module(ejabberd_sm_ha).
-behaviour(ejabberd_sm).

-export([
    init/0,
    set_session/1,
    delete_session/1,
    get_sessions/1,
    get_sessions/2
]).


-include("ha_types.hrl").
-include("ejabberd_sm.hrl").
-include("logger.hrl").


%%%===================================================================
%%% API
%%%===================================================================
-spec init() -> ok | {error, any()}.
init() ->
    ?INFO("Using ~p as backend", [?MODULE]),
    ejabberd_sm_mnesia:init(),
    % FIXME: make sure the redis_sup has started already?
    ok.


-spec set_session(Session :: session()) -> ok.
set_session(Session) ->
    {Uid, _Server} = Session#session.us,
    {ok, _OldPid} = model_session:set_session(Uid, Session),
    ok = ejabberd_sm_mnesia:set_session(Session),
    ok.

-spec delete_session(Session :: session()) -> ok.
delete_session(Session) ->
    {Uid, _Server} = Session#session.us,
    ok = model_session:del_session(Uid, Session),
    ok = ejabberd_sm_mnesia:delete_session(Session),
    ok.

% TODO: delete
-spec get_sessions(Server :: binary()) -> [session()].
get_sessions(_LServer) ->
    ?ERROR("Deprecated API"),
    [].

-spec get_sessions(Uid :: uid(), Server :: binary()) -> {ok, [session()]}.
get_sessions(Uid, LServer) ->
    RSessionsAll = model_session:get_sessions(Uid),
    {RSessions, DeadRSessions} = partition_alive_sessions(RSessionsAll),
    {ok, MSessions} = ejabberd_sm_mnesia:get_sessions(Uid, LServer),
    MSessionsSorted = lists:sort(MSessions),
    RSessionsSorted = lists:sort(RSessions),
    case MSessionsSorted =:= RSessionsSorted of
        true -> ?INFO("Uid ~s sessions match ~p", [Uid, length(RSessions)]);
        false ->
            ?INFO("sessions-mismatch Uid: ~s, M: ~p R: ~p", [
                Uid,
                [S#session.sid || S <- MSessionsSorted],
                [S#session.sid || S <- RSessionsSorted]])
    end,
    cleanup_sessions(DeadRSessions),
    {ok, RSessions}.


-spec partition_alive_sessions(Sessions :: [session()]) -> {[session()], [session()]}.
partition_alive_sessions(Sessions) ->
    lists:partition(
        fun (#session{sid = {_, Pid}}) ->
            remote_is_process_alive(Pid)
        end, Sessions).

remote_is_process_alive(Pid) ->
    case rpc:call(node(Pid), erlang, is_process_alive, [Pid], 5000) of
        {badrpc, Reason} ->
            ?ERROR("Pid: ~p badrpc ~p", [Pid, Reason]),
            true;
        Result -> Result
    end.


-spec cleanup_sessions(Sessions :: [session()]) -> ok.
cleanup_sessions(Sessions) ->
    lists:foreach(fun cleanup_session/1, Sessions).


-spec cleanup_session(Session :: session()) -> ok.
cleanup_session(#session{sid = SID, us = {Uid, _}} = Session) ->
    ?INFO("Uid: ~s Cleanup dead session ~p", [Uid, SID]),
    model_session:del_session(Uid, Session),
    ok.

