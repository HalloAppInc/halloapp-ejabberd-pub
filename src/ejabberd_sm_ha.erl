-module(ejabberd_sm_ha).
-behaviour(ejabberd_sm).

-export([
    init/0,
    set_session/1,
    delete_session/1,
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
    % FIXME: make sure the redis_sup has started already?
    ok.


-spec set_session(Session :: session()) -> ok.
set_session(Session) ->
    {Uid, _Server} = Session#session.us,
    {ok, _OldPid} = model_session:set_session(Uid, Session),
    ok.


-spec delete_session(Session :: session()) -> ok.
delete_session(Session) ->
    {Uid, _Server} = Session#session.us,
    model_session:del_session(Uid, Session).


-spec get_sessions(Uid :: uid(), Server :: binary()) -> {ok, [session()]}.
get_sessions(Uid, _LServer) ->
    Sessions = model_session:get_sessions(Uid),
    {ok, Sessions}.

