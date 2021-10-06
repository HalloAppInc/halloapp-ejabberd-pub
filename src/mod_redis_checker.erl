%%%-------------------------------------------------------------------
%%% @author josh
%%% @copyright (C) 2021, HalloApp, Inc.
%%% @doc
%%%
%%% @end
%%% Created : 23. Aug 2021 4:06 PM
%%%-------------------------------------------------------------------
-module(mod_redis_checker).
-author("josh").

-include("logger.hrl").
-include("monitor.hrl").
-include("proc.hrl").
-include_lib("ecredis/include/ecredis.hrl").


%% gen_mod API
-export([start/2, stop/1, depends/2, reload/3, mod_options/1]).

%% gen_server API
-export([init/1, terminate/2, handle_cast/2, handle_call/3, handle_info/2, code_change/3]).

%%%%%%%%%%%%%%%%%%%%%
%%% Configurables %%%
%%%%%%%%%%%%%%%%%%%%%

%% how often we should refresh the list of nodes
-define(CLUSTER_REFRESH_MS, (5 * ?MINUTES_MS)).
%% each master should have >= MIN_SLAVE_THRESHOLD slaves
-define(MIN_SLAVE_THRESHOLD, 2).
%% how long we can have < MIN_SLAVE_THRESHOLD slaves before an alert is sent
-define(MISSING_SLAVE_THRESHOLD_MS, 1 * ?HOURS_MS).

%%%%%%%%%%%%%%%%%%%%%

%% key for get/set op
-define(REDIS_KEY(Slot), <<"__redis_checker:{", Slot/binary, "}">>).

%% keys for state histories
-define(CLUSTER_CAN_CONNECT_KEY, cluster_can_connect).
-define(CAN_CONNECT_KEY, can_connect).
-define(GET_KEY, get).
-define(HAS_SLAVES_KEY, has_slaves).
-define(SET_KEY, set).

%% API
-export([
    check_redises/0,
    get_state_history/2,
    get_state_history/3
]).

%%====================================================================
%% API
%%====================================================================

check_redises() ->
    gen_server:cast(?PROC(), check_redises).


%% All state histories except ?CLUSTER_CAN_CONNECT_KEY need the node information
%% So, only when Type =:= ?CLUSTER_CAN_CONNECT_KEY can this function be used
-spec get_state_history(Id :: atom(), Type :: atom()) -> [proc_state()].
get_state_history(Id, Type) when Type =:= ?CLUSTER_CAN_CONNECT_KEY ->
    util_monitor:get_state_history(?REDIS_TABLE, make_key(Id, Type));

get_state_history(_Id, Type) ->
    ?WARNING("Invalid type for get_state_history without node specified: ~p", [Type]),
    undefined.


-spec get_state_history(Id :: atom(), Node :: rnode(), Type :: atom()) -> [proc_state()].
get_state_history(Id, Node, Type) ->
    util_monitor:get_state_history(?REDIS_TABLE, make_key(Id, Node, Type)).


%%====================================================================
%% gen_mod API
%%====================================================================

start(Host, Opts) ->
    case config:get_hallo_env() of
        localhost -> gen_mod:start_child(?MODULE, Host, Opts, ?PROC());
        prod ->
            case util:get_machine_name() of
                <<"s-test">> -> gen_mod:start_child(?MODULE, Host, Opts, ?PROC());
                _ -> ok
            end;
        _ -> ok
    end.

stop(_Host) ->
    case config:get_hallo_env() of
        localhost -> gen_mod:stop_child(?PROC());
        prod ->
            case util:get_machine_name() of
                <<"s-test">> -> gen_mod:stop_child(?PROC());
                _ -> ok
            end;
        _ -> ok
    end.

depends(_Host, _Opts) -> [].

reload(_Host, _NewOpts, _OldOpts) -> ok.

mod_options(_Host) -> [].

%%====================================================================
%% gen_server API
%%====================================================================

init(_) ->
    ets:new(?REDIS_TABLE, [named_table, public]),
    {Clusters, ClustersTsMs} = {get_clusters(), util:now_ms()},
    {ok, Tref} = timer:apply_interval(?PING_INTERVAL_MS, ?MODULE, check_redises, []),
    {ok, #{clusters => Clusters, clusters_ts_ms => ClustersTsMs, tref => Tref}}.


terminate(_Reason, #{tref := Tref}) ->
    ets:delete(?REDIS_TABLE),
    timer:cancel(Tref),
    ok.


handle_call(Request, From, State) ->
    ?WARNING("Unexpected call from ~p: ~p", [From, Request]),
    {noreply, State}.


handle_cast(check_redises, State) ->
    State2 = check_states(State),
    State3 = check_redises(State2),
    {noreply, State3};

handle_cast({ping, Id, Ts, From}, State) ->
    util_monitor:send_ack(self(), From, {ack, Id, Ts, self()}),
    {noreply, State};

handle_cast(Msg, State) ->
    ?WARNING("Unexpected cast: ~p", [Msg]),
    {noreply, State}.


handle_info(Info, State) ->
    ?WARNING("Unexpected info: ~p", [Info]),
    {noreply, State}.


code_change(_OldVsn, State, _Extra) -> {ok, State}.

%%====================================================================
%% Functions to check redis clients
%%====================================================================

check_redises(#{clusters := Clusters, clusters_ts_ms := TsMs} = State) ->
    {NewClusters, NewTsMs} = maybe_refresh_clusters(Clusters, TsMs),
    NewState = State#{clusters => NewClusters, clusters_ts_ms => NewTsMs},
    lists:foreach(fun check_redis_client/1, NewClusters),
    NewState.


-spec check_redis_client({Id :: atom(), Nodes :: [rnode()]}) -> ok.
check_redis_client({Id, Nodes}) ->
    masters_have_slaves(Id, Nodes),  % implicitly checks if we can connect, as well
    can_set_get_masters(Id),
    ok.


% check if can set/get on each master
can_set_get_masters(Id) ->
    case ecredis:q(Id, ["CLUSTER", "SLOTS"]) of
        {ok, Res} ->
            record_state(Id, ?CLUSTER_CAN_CONNECT_KEY, ?ALIVE_STATE),
            %% gather data about slot range and master node for that range
            CleanRes = lists:map(
                fun([Start, End, Master | _Slaves]) ->
                    [Host, Port | _Rest] = Master,
                    Node = #node{address = util:to_list(Host), port = util:to_integer(Port)},
                    {util:to_integer(Start), util:to_integer(End), Node}
                end,
                Res),
            %% try to set then get for each master
            lists:foreach(
                fun({Start, End, Node}) ->
                    %% randomly use any slot in range
                    Slot = rand:uniform(End - Start) + Start,
                    case try_set(Id, Node, Slot) of
                        false -> ok;  %% set failed, so there's nothing to get
                        {true, Val} ->
                            try_get(Id, Node, Slot, Val),
                            delete_redis_key(Id, Node, Slot)
                    end
                end,
                CleanRes);
        {error, Err} ->
            ?ERROR("Failed to run command \"CLUSTER SLOTS\" for ~p: ~p", [Id, Err]),
            record_state(Id, ?CLUSTER_CAN_CONNECT_KEY, ?FAIL_STATE)
    end.


masters_have_slaves(Id, Nodes) ->
    lists:foreach(fun(N) -> master_has_slaves(Id, N) end, Nodes).


%% check if can connect to master and if they have >= MIN_SLAVE_THRESHOLD slaves
master_has_slaves(Id, Node) ->
    case catch ecredis:qn(Id, Node, ["INFO", "replication"]) of
        {ok, RawRes} ->
            record_state(Id, Node, ?CAN_CONNECT_KEY, ?ALIVE_STATE),
            ResMap = maps:from_list(util_redis:parse_info(RawRes)),
            case maps:get(<<"role">>, ResMap, undefined) of
                <<"master">> ->
                    case maps:get(<<"connected_slaves">>, ResMap, undefined) of
                        undefined ->
                            ?WARNING("Can't find connected slaves info for ~p ~p: ~p",
                                [Id, Node, ResMap]),
                            record_state(Id, Node, ?HAS_SLAVES_KEY, ?FAIL_STATE);
                        N ->
                            case util:to_integer(N) >= ?MIN_SLAVE_THRESHOLD of
                                true -> record_state(Id, Node, ?HAS_SLAVES_KEY, ?ALIVE_STATE);
                                false -> record_state(Id, Node, ?HAS_SLAVES_KEY, ?FAIL_STATE)
                            end
                    end;
                OtherRole ->
                    ?WARNING("Expected role was master, instead got ~p for ~p ~p", [OtherRole, Id, Node]),
                    record_state(Id, Node, ?HAS_SLAVES_KEY, ?FAIL_STATE)
            end;
        {error, Err} ->
            ?ERROR("Can't connect to ~p ~p: ~p", [Id, Node, Err]),
            record_state(Id, Node, ?CAN_CONNECT_KEY, ?FAIL_STATE);
        {'EXIT', {Reason, Stacktrace}} ->
            ?ERROR("Redis query failed ~p:~p Reason ~p Stacktrace: ~p",
                [Id, Node, Reason, lager:pr_stacktrace(Stacktrace)]),
            record_state(Id, Node, ?CAN_CONNECT_KEY, ?FAIL_STATE)
    end.

%%====================================================================
%% Functions to check state histories
%% A function will return true if an alert has been sent
%%====================================================================

check_states(#{clusters := Clusters} = State) ->
    lists:foreach(
        fun({Id, Nodes}) ->
            %% check for slow or unreachable connection to cluster
            check_alive(Id),
            lists:foreach(
                fun(Node) ->
                    %% check for slow or unreachable connection to each master in cluster
                    check_alive(Id, Node),
                    %% check that slaves haven't been missing for too long
                    check_has_slaves(Id, Node),
                    %% check that you can get/set keys in each slot range
                    %% if there is an issue with set, dont check get
                    check_can_set(Id, Node) orelse check_can_get(Id, Node)
                end,
                Nodes)
        end,
        Clusters),
    State.


-spec check_alive(Id :: atom()) -> boolean().
check_alive(Id) ->
    check_alive(Id, none).


-spec check_alive(Id :: atom(), Node :: rnode() | none) -> boolean().
check_alive(Id, Node) ->
    {StateHistory, StatName} = case Node of
        none ->
            {get_state_history(Id, ?CLUSTER_CAN_CONNECT_KEY), util:to_list(?CLUSTER_CAN_CONNECT_KEY)};
        _ ->
            {get_state_history(Id, Node, ?CAN_CONNECT_KEY), util:to_list(?CAN_CONNECT_KEY)}
    end,
    send_stats(StatName, Id, Node, StateHistory),
    check_consecutive_connect_fails(Id, Node, StateHistory)
        orelse check_slow_connection(Id, Node, StateHistory).


-spec check_slow_connection(Id :: atom(), Node :: rnode(), StateHistory :: [proc_state()]) -> boolean().
check_slow_connection(Id, Node, StateHistory) ->
    case util_monitor:check_slow(StateHistory) of
        {false, _} -> false;
        {true, PercentFails} ->
            ?ERROR("Sending slow alert for: ~p ~p: ~p% of attempted connections are failing",
                [Id, Node, PercentFails]),
            BinId = get_binary_id_with_node(Id, Node),
            Msg = <<BinId/binary, " failing ", (util:to_binary(PercentFails))/binary ,
                "% of attempted connections">>,
            alerts:send_alert(<<BinId/binary, " is slow">>, BinId, <<"critical">>, Msg),
            true
    end.


-spec check_can_get(Id :: atom(), Node :: rnode()) -> boolean().
check_can_get(Id, Node) ->
    StateHistory = get_state_history(Id, Node, ?GET_KEY),
    send_stats(util:to_list(?GET_KEY), Id, Node, StateHistory),
    check_can_x(Id, Node, StateHistory, <<"get">>).


-spec check_can_set(Id :: atom(), Node :: rnode()) -> boolean().
check_can_set(Id, Node) ->
    StateHistory = get_state_history(Id, Node, ?SET_KEY),
    send_stats(util:to_list(?SET_KEY), Id, Node, StateHistory),
    check_can_x(Id, Node, StateHistory, <<"set">>).


-spec check_can_x(Id :: atom(), Node :: rnode(), StateHistory :: [proc_state()], Type :: binary()) -> boolean().
check_can_x(Id, Node, StateHistory, Type) ->
    case util_monitor:check_consecutive_fails(StateHistory) of
        false ->
            %% check slow only if there is not consecutive failures
            case util_monitor:check_slow(StateHistory) of
                {false, _} -> false;
                {true, _} ->
                    ?ERROR("Sending slow ~s alert for ~p ~p", [Type, Id, Node]),
                    BinId = get_binary_id_with_node(Id, Node),
                    Msg = <<Type/binary, "ting keys is slow">>,
                    alerts:send_alert(<<BinId/binary, " is slow to ", Type/binary, " key">>,
                        BinId, <<"critical">>, Msg),
                    true
            end;
        true ->
            ?ERROR("Sending can't ~s alert for ~p ~p", [Type, Id, Node]),
            BinId = util:to_binary(Id),
            Msg = <<"Failing to ", Type/binary, " key">>,
            alerts:send_alert(<<BinId/binary, " can't ", Type/binary, " key">>, BinId, <<"critical">>, Msg),
            true
    end.


-spec check_consecutive_connect_fails(Id :: atom(), Node :: rnode(), StateHistory :: [proc_state()]) -> boolean().
check_consecutive_connect_fails(Id, Node, StateHistory) ->
    case util_monitor:check_consecutive_fails(StateHistory) of
        false -> false;
        true ->
            ?ERROR("Sending unreachable alert for: ~p ~p", [Id, Node]),
            BinId = get_binary_id_with_node(Id, Node),
            BinNumConsecFails = util:to_binary(?CONSECUTIVE_FAILURE_THRESHOLD),
            Msg = <<BinId/binary, " has failed last ", BinNumConsecFails/binary, " connection attempts">>,
            alerts:send_alert(<<BinId/binary, " unreachable">>, BinId, <<"critical">>, Msg),
            true
    end.


-spec check_has_slaves(Id :: atom(), Node :: rnode()) -> boolean().
check_has_slaves(Id, Node) ->
    StateHistory = get_state_history(Id, Node, ?HAS_SLAVES_KEY),
    send_stats(util:to_list(?HAS_SLAVES_KEY), Id, Node, StateHistory),
    Window = lists:sublist(StateHistory, ?MISSING_SLAVE_THRESHOLD_MS div ?PING_INTERVAL_MS),
    case util_monitor:get_num_fails(Window) =:= (?MISSING_SLAVE_THRESHOLD_MS div ?PING_INTERVAL_MS) of
        false -> false;
        true ->
            ?ERROR("~p ~p has had less than ~p slaves for > ~p hour",
                [Id, Node, ?MIN_SLAVE_THRESHOLD, ?MISSING_SLAVE_THRESHOLD_MS div ?HOURS_MS]),
            BinId = get_binary_id_with_node(Id, Node),
            Msg = <<BinId/binary, " has had less than ",
                (util:to_binary(?MIN_SLAVE_THRESHOLD))/binary, " slaves for > ",
                (util:to_binary(?MISSING_SLAVE_THRESHOLD_MS div ?HOURS_MS))/binary, " hours">>,
            alerts:send_alert(<<BinId/binary, " is missing slaves">>, BinId, <<"critical">>, Msg),
            true
    end.

%%====================================================================
%% Internal functions
%%====================================================================

% TODO: we need to do something with the result of this function. If the delete failed,
% this should be counted as some sort of failure
delete_redis_key(Id, Node, Slot) ->
    SlotKey = ha_redis:get_slot_key(Slot),
    case catch ecredis:qn(Id, Node, ["DEL", ?REDIS_KEY(SlotKey)]) of
        {ok, <<"1">>} -> ok;
        {'EXIT', {Reason, St}} ->
            ?ERROR("Delete check failed ~p:~p Slot: ~p Reason: ~p Stacktrace: ~p",
                [Id, Node, Slot, Reason, lager:pr_stacktrace(St)]);
        Resp -> ?WARNING("Issue deleting redis_checker key ~p, response: ~p",
            [?REDIS_KEY(SlotKey), Resp])
    end.


get_binary_id_with_node(Id, none) ->
    util:to_binary(Id);

get_binary_id_with_node(Id, #node{address = Host, port = Port}) ->
    BinId = util:to_binary(Id),
    BinNode = util:to_binary(lists:concat([Host, ":", util:to_list(Port)])),
    <<BinId/binary, "@", BinNode/binary>>.


-spec get_clusters() -> [{ClientId :: atom(), [rnode()]}].
get_clusters() ->
    lists:map(
        fun(ClusterId) ->
            case ecredis:get_nodes(ClusterId) of
                [] ->
                    ?ERROR("No redis nodes found for ~p", [ClusterId]),
                    BinId = util:to_binary(ClusterId),
                    alerts:send_alert(<<BinId/binary, " has no nodes">>, BinId, <<"critical">>, <<>>),
                    {ClusterId, []};
                Res -> {ClusterId, Res}
            end
        end,
        ha_redis:get_redis_clients()).


make_key(Id, Type) ->
    lists:concat([util:to_list(Id), "_", util:to_list(Type)]).


make_key(Id, #node{address = Host, port = Port}, Type) ->
    Node = lists:concat([Host, ":", util:to_list(Port)]),
    lists:concat([util:to_list(Id), "_", Node, "_", util:to_list(Type)]).


maybe_refresh_clusters(Clusters, TsMs) ->
    case (util:now_ms() - TsMs) >= ?CLUSTER_REFRESH_MS of
        false -> {Clusters, TsMs};
        true -> {get_clusters(), util:now_ms()}
    end.


record_state(Id, Type, State) ->
    util_monitor:record_state(?REDIS_TABLE, make_key(Id, Type), State).


record_state(Id, Node, Type, State) ->
    util_monitor:record_state(?REDIS_TABLE, make_key(Id, Node, Type), State).


-spec send_stats(StatName :: string(), Id :: atom(), Node :: rnode() | none, StateHistory :: [proc_state()]) -> ok.
send_stats(StatName, Id, Node, StateHistory) ->
    Window = ?MINUTES_MS div ?PING_INTERVAL_MS,
    SuccessRate = 1 - (util_monitor:get_num_fails(lists:sublist(StateHistory, Window)) / Window),
    StrNode = case Node of
        #node{address = Host, port = Port} -> lists:concat([Host, "/", util:to_list(Port)]);
        none -> "no_node"
    end,
    stat:gauge(?NS, StatName, round(SuccessRate * 100), [{cluster_id, Id}, {node, StrNode}]),
    ok.


%% returns {true, SetVal} if successful, false otherwise
try_set(Id, Node, Slot) ->
    SlotKey = ha_redis:get_slot_key(Slot),
    Val = util:now_ms(),
    Cmd = ["SET", ?REDIS_KEY(SlotKey), Val],
    case catch ecredis:qn(Id, Node, Cmd) of
        {ok, <<"OK">>} ->
            record_state(Id, Node, ?SET_KEY, ?ALIVE_STATE),
            {true, Val};
        {error, Err} ->
            ?ERROR("Failed to set at ~p for ~p ~p: ~p", [?REDIS_KEY(SlotKey), Id, Node, Err]),
            record_state(Id, Node, ?SET_KEY, ?FAIL_STATE),
            false;
        {'EXIT', {Reason, St}} ->
            ?ERROR("Failed to set at ~p for ~p ~p: ~p Stacktrace ~p",
                [?REDIS_KEY(SlotKey), Id, Node, Reason, lager:pr_stacktrace(St)]),
            record_state(Id, Node, ?SET_KEY, ?FAIL_STATE),
            false
    end.


try_get(Id, Node, Slot, Val) ->
    SlotKey = ha_redis:get_slot_key(Slot),
    Cmd = ["GET", ?REDIS_KEY(SlotKey)],
    BinVal = util:to_binary(Val),
    case catch ecredis:qn(Id, Node, Cmd) of
        {ok, BinVal} -> record_state(Id, Node, ?GET_KEY, ?ALIVE_STATE);
        {ok, OtherVal} ->
            ?ERROR("Got unexpected value ~p at ~p ~p, expected ~p", [OtherVal, Id, Node, BinVal]),
            record_state(Id, Node, ?GET_KEY, ?FAIL_STATE);
        {error, Err} ->
            ?ERROR("Failed to get at ~p for ~p ~p: ~p", [?REDIS_KEY(SlotKey), Id, Node, Err]),
            record_state(Id, Node, ?GET_KEY, ?FAIL_STATE);
        {'EXIT', {Reason, St}} ->
            ?ERROR("Failed to get at ~p for ~p ~p: ~p Stacktrace ~p",
                [?REDIS_KEY(SlotKey), Id, Node, Reason, lager:pr_stacktrace(St)]),
            record_state(Id, Node, ?GET_KEY, ?FAIL_STATE)
    end.

