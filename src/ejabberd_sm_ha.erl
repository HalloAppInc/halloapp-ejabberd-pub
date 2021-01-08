-module(ejabberd_sm_ha).
-behaviour(ejabberd_sm).

-export([
    init/0,
    set_session/1,
    delete_session/1,
    get_sessions/0,
    get_sessions/1,
    get_sessions/2,
    use_cache/1,
    cache_nodes/1
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


-spec cache_nodes(Server :: binary()) -> [node()].
cache_nodes(_LServer) ->
    [node()].

-spec use_cache(Server :: binary()) -> boolean().
use_cache(_LServer) ->
    false.

-spec set_session(Session :: session()) -> ok.
set_session(Session) ->
    Res = ejabberd_sm_mnesia:set_session(Session),
    try
        {Uid, _Server} = Session#session.us,
        {ok, _OldPid} = model_session:set_session(Uid, Session)
    catch Class:Reason:St ->
        ?ERROR("Storing sessions in redis failed: Session: ~p Stacktrace: ~p",
            [Session, lager:pr_stacktrace(St, {Class, Reason})])
    end,
    Res.

-spec delete_session(Session :: session()) -> ok.
delete_session(Session) ->
    Res = ejabberd_sm_mnesia:delete_session(Session),
    try
        {Uid, _Server} = Session#session.us,
        ok = model_session:del_session(Uid, Session)
    catch Class:Reason:St ->
        ?ERROR("Deleting sessions in redis failed: Session: ~p Stacktrace: ~p",
            [Session, lager:pr_stacktrace(St, {Class, Reason})])
    end,
    Res.

-spec get_sessions() -> [session()].
get_sessions() ->
    ?ERROR("Deprecated API"),
    % TODO: return [], and later delete this API.
    ejabberd_sm_mnesia:get_sessions().

-spec get_sessions(Server :: binary()) -> [session()].
get_sessions(LServer) ->
    ?ERROR("Deprecated API"),
    % TODO: return [], and later delete this API.
    ejabberd_sm_mnesia:get_sessions(LServer).

-spec get_sessions(Uid :: uid(), Server :: binary()) -> {ok, [session()]}.
get_sessions(Uid, LServer) ->
    {ok, MSessions} = ejabberd_sm_mnesia:get_sessions(Uid, LServer),
    try
        RSessions = model_session:get_sessions(Uid),
        MSessionsSorted = lists:sort(MSessions),
        RSessionsSorted = lists:sort(RSessions),
        case MSessionsSorted =:= RSessionsSorted of
            true -> ?INFO("Uid ~s sessions match ~p", [Uid, length(RSessions)]);
            false ->
                ?INFO("sessions-mismatch Uid: ~s, M: ~p R: ~p", [
                    Uid,
                    [S#session.sid || S <- MSessionsSorted],
                    [S#session.sid || S <- RSessionsSorted]])
        end
    catch Class:Reason:St ->
        ?ERROR("get_sessions in redis failed: Uid: ~p Stacktrace: ~p",
            [Uid, lager:pr_stacktrace(St, {Class, Reason})])
    end,
    {ok, MSessions}.

