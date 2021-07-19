%%%-------------------------------------------------------------------
%%% File    : ejabberd_monitor.erl
%%%
%%% copyright (C) 2020, HalloApp, Inc
%%%
%% This is a worker process under the main root supervisor of the application.
%% Currently, this monitors child processes of ejabberd_gen_mod_sup and redis_sup.
%% An alert will be sent if a monitored process is dead, slow, or unresponsive.
%% Supervisors are only monitored using erlang:monitor and will only alert if they go down.
%%%-------------------------------------------------------------------
-module(ejabberd_monitor).
-author('murali').
-author('josh').

-behaviour(gen_server).

-include("logger.hrl").
-include("monitor.hrl").

-export([start_link/0]).
%% gen_server callbacks
-export([
    init/1,
    stop/0,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-export([
    get_monitored_procs/0,
    ping_procs/0,
    new_node/2,
    monitor/1,
    get_state_history/1,
    try_remonitor/1,
    get_registered_name/0,
    get_registered_name/1,
    %% TODO(josh): remove this api after all machines have globally registered ejabberd monitors
    enable_global_monitoring/0
]).

%%====================================================================
%% API
%%====================================================================

enable_global_monitoring() ->
    gen_server:call(?MONITOR_GEN_SERVER, enable_global_monitoring),
    monitor_other_monitors(),
    ok.

start_link() ->
    ?INFO("Starting monitoring process: ~p", [?MODULE]),
    Result = gen_server:start_link(?MONITOR_GEN_SERVER, ?MODULE, [], []),
    monitor_ejabberd_processes(),
    monitor_other_monitors(),
    Result.

stop() ->
    ejabberd_sup:stop_child(?MODULE).

get_monitored_procs() ->
    gen_server:call(?MONITOR_GEN_SERVER, get_monitored_procs).

ping_procs() ->
    gen_server:cast(?MONITOR_GEN_SERVER, ping_procs).

new_node(Node, _InfoList) ->
    monitor({global, ejabberd_monitor:get_registered_name(Node)}).

-spec monitor(Proc :: atom() | pid()) -> ok.
monitor(Proc) ->
    gen_server:cast(?MONITOR_GEN_SERVER, {monitor, Proc}),
    ok.

-spec get_state_history(Mod :: atom()) -> list(proc_state()).
get_state_history(Mod) ->
    case ets:lookup(?MONITOR_TABLE, Mod) of
        [] -> [];
        [{Mod, StateHistory}] -> StateHistory
    end.

try_remonitor({global, Name} = Proc) ->
    case global:whereis_name(Name) of
        undefined ->
            {ok, _TRef} = timer:apply_after(?REMONITOR_DELAY_MS, ?MODULE, try_remonitor, [Proc]);
        _Pid -> monitor(Proc)
    end;
try_remonitor(Proc) ->
    case whereis(Proc) of
        undefined ->
            ?ERROR("Process ~p unable to be found, cannot remonitor", [Proc]),
            {ok, _TRef} = timer:apply_after(?REMONITOR_DELAY_MS, ?MODULE, try_remonitor, [Proc]);
        _Pid -> monitor(Proc)
    end.

get_registered_name() ->
    get_registered_name(node()).

-spec get_registered_name(Node :: atom()) -> atom().
get_registered_name(Node) ->
    Shard = util:get_shard(Node),
    case Shard of
        undefined ->
            [Name | _] = string:split(util:to_list(Node), <<"@">>),
            util:to_atom(lists:concat([?MODULE, ".", Name]));
        _ -> util:to_atom(lists:concat([?MODULE, ".", Shard]))
    end.

get_gen_servers() ->
    [
        ejabberd_local,
        ejabberd_cluster,
        ejabberd_iq,
        ejabberd_hooks,
        ejabberd_router,
        ejabberd_sm
    ].

% supervisors cannot be pinged like gen_servers
get_supervisors() ->
    [
        ejabberd_listener,
        ejabberd_gen_mod_sup,
        redis_sup
    ].

%%====================================================================
%% gen_server callbacks
%%====================================================================

%% Since, if this process crashes: restarting this process will lose all our monitor references.
init([]) ->
    ?INFO("Start: ~p", [?MONITOR_GEN_SERVER]),
    {ok, TRef} = timer:apply_interval(?PING_INTERVAL_MS, ?MODULE, ping_procs, []),
    ets:new(?MONITOR_TABLE, [named_table, public]),
    ejabberd_hooks:add(new_node, ?MODULE, new_node, 0),
    {ok, #state{monitors = #{}, active_pings = #{}, gen_servers = [], tref = TRef,
        global_monitoring = false}}.


terminate(_Reason, #state{tref = TRef} = _State) ->
    ?INFO("Terminate: ~p", [?MONITOR_GEN_SERVER]),
    timer:cancel(TRef),
    ets:delete(?MONITOR_TABLE),
    ejabberd_hooks:delete(new_node, ?MODULE, monitor, 0),
    ok.

%% TODO(josh): remove this api after all machines have globally registered ejabberd monitors
handle_call(get_global_monitoring_status, _From, #state{global_monitoring = GM} = State) ->
    {reply, GM, State};

%% TODO(josh): remove this api after all machines have globally registered ejabberd monitors
handle_call(enable_global_monitoring, _From, State) ->
    {reply, ok, State#state{global_monitoring = true}};

handle_call(get_monitored_procs, _From, #state{monitors = Monitors} = State) ->
    {reply, maps:values(Monitors), State};

handle_call(Request, From, State) ->
    ?WARNING("Unexpected call from ~p: ~p", [From, Request]),
    {noreply, State}.


handle_cast(ping_procs, State) ->
    {NewState, _NumFailedPings} = check_ping_map(State),
    NewState2 = check_states(NewState),
    NewState3 = send_pings(NewState2),
    {noreply, NewState3};

handle_cast({monitor, {global, Name} = Proc}, #state{monitors = Monitors, gen_servers = GenServers,
        global_monitoring = GM} = State) ->
    %% TODO(josh): remove this case after all machines have globally registered ejabberd monitors
    case GM of
        false -> NewState2 = State;
        true ->
            Pid = global:whereis_name(Name),
            NewState2 = case lists:member(Proc, maps:values(Monitors)) of
                true -> State;
                false ->
                    NewState = case Pid of
                        undefined ->
                           try_remonitor(Proc),
                           State;
                        _ ->
                           ?INFO("Monitoring global process name: ~p, pid: ~p", [Name, Pid]),
                           Ref = erlang:monitor(process, Pid),
                           State#state{monitors = Monitors#{Ref => Proc}}
                    end,
                    case lists:member(Proc, GenServers) of
                        true -> NewState;
                        false -> NewState#state{gen_servers = [Proc | GenServers]}
                    end
            end
    end,
    {noreply, NewState2};

handle_cast({monitor, Proc}, #state{monitors = Monitors, gen_servers = GenServers} = State) ->
    Pid = whereis(Proc),
    ?INFO("Monitoring process name: ~p, pid: ~p", [Proc, Pid]),
    Ref = erlang:monitor(process, Proc),
    NewState = State#state{monitors = Monitors#{Ref => Proc}},
    NewState2 = case is_gen_server(Proc) of
        true -> NewState#state{gen_servers = [Proc | GenServers]};
        false -> NewState
    end,
    {noreply, NewState2};

handle_cast({ping, Id, Ts, From}, State) ->
    util_monitor:send_ack(self(), From, {ack, Id, Ts, self()}),
    {noreply, State};

handle_cast(Msg, State) ->
    ?WARNING("Unexpected cast: ~p", [Msg]),
    {noreply, State}.


handle_info({ack, Id, Ts, From}, #state{active_pings = PingMap} = State) ->
    case maps:take(Id, PingMap) of
        error ->
            Secs = (util:now_ms() - Ts) / 1000,
            ?WARNING("Got late ack (~ps) from: ~p", [Secs, From]),
            NewPingMap = PingMap;
        {Mod, NewPingMap} ->
            case util:now_ms() - Ts > ?PING_TIMEOUT_MS of
                true ->
                    Secs = (util:now_ms() - Ts) / 1000,
                    ?WARNING("Got late ack (~ps) from: ~p", [Secs, From]),
                    record_state(Mod, ?FAIL_STATE);
                false -> record_state(Mod, ?ALIVE_STATE)
            end
    end,
    {noreply, State#state{active_pings = NewPingMap}};

handle_info({'DOWN', Ref, process, Pid, Reason}, #state{monitors = Monitors} = State) ->
    ?ERROR("process down, pid: ~p, reason: ~p", [Pid, Reason]),
    Proc = maps:get(Ref, Monitors, undefined),
    case Proc of
        undefined -> ?ERROR("Monitor's reference missing: ~p", [Ref]);
        {global, Name} ->
            case Reason of
                shutdown -> ?INFO("Remote monitor at ~p shutdown", [node(Pid)]);
                _ -> alerts:send_process_down_alert(Name, <<"Monitor is dead">>)
            end;
        _ ->
            [_, Node] = binary:split(util:to_binary(node()), <<"@">>),
            BProc = util:to_binary(Proc),
            Name = <<BProc/binary, ".", Node/binary>>,
            alerts:send_process_down_alert(Name, <<"Process is dead">>)
    end,
    NewMonitors = maps:remove(Ref, State#state.monitors),
    NewGenServers = lists:delete(Proc, State#state.gen_servers),
    {ok, _TRef} = timer:apply_after(?REMONITOR_DELAY_MS, ?MODULE, try_remonitor, [Proc]),
    FinalState = State#state{monitors = NewMonitors, gen_servers = NewGenServers},
    {noreply, FinalState};

handle_info(Info, State) ->
    ?WARNING("Unexpected info: ~p", [Info]),
    {noreply, State}.


code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%====================================================================
%% Internal functions
%%====================================================================

monitor_ejabberd_processes() ->
    lists:foreach(fun(Mod) -> ejabberd_monitor:monitor(Mod) end, get_supervisors() ++ get_gen_servers()),
    %% Monitor all our child gen_servers of ejabberd_gen_mod_sup.
    lists:foreach(
        fun ({ChildId, _, _, _}) ->
            ejabberd_monitor:monitor(ChildId)
        end, supervisor:which_children(ejabberd_gen_mod_sup)),

    %% Monitor all our redis cluster clients - children of redis_sup.
    lists:foreach(
        fun ({ChildId, _, _, _}) ->
            ejabberd_monitor:monitor(ChildId)
        end, supervisor:which_children(redis_sup)),
    ok.


monitor_other_monitors() ->
    %% TODO(josh): remove this api after all machines have globally registered ejabberd monitors
    case gen_server:call(?MONITOR_GEN_SERVER, get_global_monitoring_status) of
        false -> ok;
        true ->
            STestShardNum = util:get_stest_shard_num(),
            ToMonitor = case util:get_shard() of
                undefined -> all;
                STestShardNum -> all;
                0 -> stest;
                1 -> stest;
                2 -> stest;
                _ -> none
            end,
            MonitorList = case ToMonitor of
                all ->
                  lists:map(
                      fun(N) -> {global, get_registered_name(N)} end,
                      nodes());
                stest -> [{global, get_registered_name('ejabberd@s-test')}];
                none -> []
            end,
            lists:foreach(fun monitor/1, MonitorList)
    end,
    ok.


check_ping_map(#state{active_pings = PingMap} = State) ->
    %% Check Ping Map and record ?FAIL_STATE for any leftover pings
    NumFailedPings = lists:foldl(
        fun(Mod, Acc) ->
            ?ERROR("Failed to ack ping: ~p", [Mod]),
            record_state(Mod, ?FAIL_STATE),
            Acc + 1
        end,
        0,
        maps:values(PingMap)),
    case NumFailedPings > 0 of
        true -> ?WARNING("~p failed pings", [NumFailedPings]);
        false -> ok
    end,
    {State#state{active_pings = #{}}, NumFailedPings}.


check_states(#state{gen_servers = GenServers} = State) ->
    %% Check state histories and maybe trigger an alert
    lists:foreach(
        fun(Mod) ->
            StateHistory = get_state_history(Mod),
            case check_consecutive_fails(Mod, StateHistory) of
                error -> ok;
                ok -> check_slow_process(Mod, StateHistory)
            end,
            send_stats(Mod, StateHistory)
        end,
        GenServers),
    State.

send_pings(#state{active_pings = PingMap, gen_servers = GenServers} = State) ->
    %% Send ping to each monitored gen_server
    NewPingMap = lists:foldl(fun send_ping/2, PingMap, GenServers),
    State#state{active_pings = NewPingMap}.

send_ping(Proc, AccMap) ->
    Id = util:random_str(?ID_LENGTH),
    gen_server:cast(Proc, {ping, Id, util:now_ms(), self()}),
    maps:put(Id, Proc, AccMap).

check_consecutive_fails(Mod, StateHistory) ->
    NumFails = get_num_fails(lists:sublist(StateHistory, ?CONSECUTIVE_FAILURE_THRESHOLD)),
    case NumFails >= ?CONSECUTIVE_FAILURE_THRESHOLD of
        false -> ok;
        true ->
            ?CRITICAL("Sending unreachable process alert for: ~p", [Mod]),
            BinNumConsecFails = util:to_binary(?CONSECUTIVE_FAILURE_THRESHOLD),
            Msg = <<"Process has failed last ", BinNumConsecFails/binary, "pings">>,
            alerts:send_unreachable_process_alert(Mod, Msg),
            error
    end.

check_slow_process(Mod, StateHistory) ->
    Window = ?HALF_FAILURE_THRESHOLD_MS div ?PING_INTERVAL_MS,
    NumFails = get_num_fails(lists:sublist(StateHistory, Window)),
    case NumFails >= (0.5 * Window) of
        false -> ok;
        true ->
            ?CRITICAL("Sending slow process alert for: ~p", [Mod]),
            Msg = <<"Process failing >= 50% of pings">>,
            alerts:send_slow_process_alert(Mod, Msg),
            error
    end.

-spec record_state(Mod :: atom(), State :: proc_state()) -> ok.
record_state(Mod, State) ->
    PrevStates = get_state_history(Mod),
    % reduce the list only when it becomes twice as large as intended history size
    NewStates = case length(PrevStates) > 2 * get_state_memory_size() of
        false -> [State | PrevStates];
        true ->
            NewPrevStates = lists:sublist(PrevStates, get_state_memory_size() - 1),
            [State | NewPrevStates]
    end,
    true = ets:insert(?MONITOR_TABLE, [{Mod, NewStates}]),
    ok.

-spec get_num_fails(StateList :: list(proc_state())) -> list(fail_state()).
get_num_fails(StateList) ->
    lists:foldl(
        fun
            (?ALIVE_STATE, Acc) -> Acc;
            (?FAIL_STATE, Acc) -> Acc + 1
        end,
        0,
        StateList
    ).

send_stats(Mod, StateHistory) ->
    Window = ?MINUTES_MS div ?PING_INTERVAL_MS,
    SuccessRate = 1 - (get_num_fails(lists:sublist(StateHistory, Window)) / Window),
    ProcName = case Mod of
        {global, Name} -> Name;
        _ -> Mod
    end,
    stat:gauge(?NS, "process_uptime", round(SuccessRate * 100), [{process_name, ProcName}]),
    ok.

get_state_memory_size() ->
    ?STATE_HISTORY_LENGTH_MS div ?PING_INTERVAL_MS.

is_gen_server(Proc) ->
    not lists:member(Proc, get_supervisors()).

