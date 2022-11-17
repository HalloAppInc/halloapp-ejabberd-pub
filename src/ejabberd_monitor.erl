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

-ifdef(TEST).
-export([get_list_of_stest_monitor_names/1]).
-endif.

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
    node_up/2,
    monitor/1,
    get_state_history/1,
    try_remonitor/1,
    get_registered_name/0,
    get_registered_name/1,
    monitor_atoms/0,
    monitor_c2s_heap_size/0,
    monitor_process_count/0,
    check_iam_role/1
]).

%%====================================================================
%% API
%%====================================================================

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

node_up(Node, _InfoList) ->
    %% 15s delay is to ensure the new node is fully initialized
    %% so we don't get one or two 'missed ping' log msgs from
    %% the new node's monitor
    Args = [{global, ejabberd_monitor:get_registered_name(Node)}],
    {ok, _TRef} = timer:apply_after(15 * ?SECONDS_MS, ?MODULE, monitor, Args).

-spec monitor(Proc :: atom() | pid() | {global, atom()}) -> ok.
monitor(Proc) ->
    gen_server:cast(?MONITOR_GEN_SERVER, {monitor, Proc}),
    ok.

-spec get_state_history(Mod :: atom() | {global, atom()}) -> list(proc_state()).
get_state_history(Mod) ->
    util_monitor:get_state_history(?MONITOR_TABLE, Mod).

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
    {ok, TRef2} = timer:apply_interval(?ATOM_CHECK_INTERVAL_MS, ?MODULE, monitor_atoms, []),
    ets:new(?PROCESS_COUNT_TABLE, [named_table, public]),
    {ok, TRef3} = timer:apply_interval(?PROCESS_COUNT_CHECK_INTERVAL_MS, ?MODULE, monitor_process_count, []),
    {ok, TRef4} = timer:apply_interval(?C2S_SIZE_CHECK_INTERVAL_MS, ?MODULE, monitor_c2s_heap_size, []),
    {ok, Config} = erlcloud_aws:auto_config(),
    {ok, TRef5} = timer:apply_interval(?IAM_CHECK_INTERVAL_MS, ?MODULE, check_iam_role, [Config]),
    ets:new(?MONITOR_TABLE, [named_table, public]),
    ejabberd_hooks:add(node_up, ?MODULE, node_up, 10),
    {ok, #state{monitors = #{}, active_pings = #{}, gen_servers = [],
        trefs = [TRef, TRef2, TRef3, TRef4, TRef5]}}.


terminate(_Reason, #state{trefs = TRefs} = _State) ->
    ?INFO("Terminate: ~p", [?MONITOR_GEN_SERVER]),
    lists:foreach(
        fun(TRef) -> timer:cancel(TRef) end,
        TRefs),
    ets:delete(?MONITOR_TABLE),
    ets:delete(?PROCESS_COUNT_TABLE),
    ejabberd_hooks:delete(node_up, ?MODULE, node_up, 10),
    ok.


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

handle_cast({monitor, {global, Name} = Proc}, #state{monitors = Monitors, gen_servers = GenServers} = State) ->
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
                _ -> alerts:send_process_down_alert(util:to_binary(Name), <<"Monitor is dead">>)
            end;
        _ ->
            [_, Node] = binary:split(util:to_binary(node()), <<"@">>),
            BProc = util:to_binary(Proc),
            Name = <<BProc/binary, ".", Node/binary>>,
            alerts:send_process_down_alert(util:to_binary(Name), <<"Process is dead">>)
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

    %% Monitor all our redis cluster clients
    lists:foreach(
        fun (ClusterId) ->
            ejabberd_monitor:monitor(ClusterId)
        end, ha_redis:get_redis_clients()),
    ok.


monitor_other_monitors() ->
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
        stest -> get_list_of_stest_monitor_names(nodes());
        none -> []
    end,
    lists:foreach(fun monitor/1, MonitorList),
    ok.


get_list_of_stest_monitor_names(Nodes) ->
    lists:filtermap(
        fun(NodeAtom) ->
            NodeStr = util:to_list(NodeAtom),
            case string:find(NodeStr, "s-test") of
                nomatch -> false;
                _ -> {true, {global, get_registered_name(NodeAtom)}}
            end
        end,
        Nodes).


monitor_atoms() ->
    AtomCount = erlang:system_info(atom_count),
    PercentUsed = util:to_float(io_lib:format("~.2f", [AtomCount / ?ATOM_LIMIT * 100])),
    case PercentUsed of
        Percent when Percent < 45 ->
            ?INFO("Atom count: ~p, roughly ~p% of the max limit", [AtomCount, PercentUsed]);
        Percent when Percent < 65 ->
            ?WARNING("Atom count: ~p, roughly ~p% of the max limit", [AtomCount, PercentUsed]);
        Percent when Percent < 85 ->
            ?ERROR("Atom count: ~p, roughly ~p% of the max limit", [AtomCount, PercentUsed]);
        _ ->
            Host = util:get_machine_name(),
            BinPercent = util:to_binary(PercentUsed),
            Msg = <<Host/binary, " has used ", BinPercent/binary, " of the atom limit">>,
            alerts:send_alert(<<Host/binary, " is approaching atom limit">>, Host, <<"critical">>, Msg)
    end,
    stat:gauge(?NS, "atom_count_num", AtomCount),
    stat:gauge(?NS, "atom_count_percent", PercentUsed),
    ok.


monitor_process_count() ->
    ProcessCount = erlang:system_info(process_count),
    MaxProcessCount = erlang:system_info(process_limit),
    PercentUsed = util:to_float(io_lib:format("~.2f", [ProcessCount / MaxProcessCount * 100])),
    case PercentUsed of
        Percent when Percent < 45 ->
            ?INFO("Process count: ~p, roughly ~p% of the max limit", [ProcessCount, PercentUsed]);
        Percent when Percent < 65 ->
            ?WARNING("Process count: ~p, roughly ~p% of the max limit", [ProcessCount, PercentUsed]);
        Percent when Percent < 85 ->
            ?ERROR("Process count: ~p, roughly ~p% of the max limit", [ProcessCount, PercentUsed]);
        _ ->
            Host = util:get_machine_name(),
            BinPercent = util:to_binary(PercentUsed),
            Msg = <<Host/binary, " has used ", BinPercent/binary, " of the process limit">>,
            alerts:send_alert(<<Host/binary, " is approaching process limit">>, Host, <<"critical">>, Msg)
    end,
    stat:gauge(?NS, "process_count_num", ProcessCount),
    stat:gauge(?NS, "process_count_percent", PercentUsed),

    case util_monitor:get_previous_state(?PROCESS_COUNT_TABLE, ?PROCESS_COUNT_PERCENT_KEY, ?PROCESS_RATE_CHECK_WINDOW, ?PROCESS_COUNT_OPTS) of
        undefined -> ok;
        PercentThen ->
            Delta = PercentUsed - PercentThen,
            case Delta of
                Okay when Okay < ?PROCESS_PERCENT_DELTA_ALARM_THRESHOLD -> ok;
                LargeDelta ->
                    Host1 = util:get_machine_name(),
                    BinPercent1 = util:to_binary(io_lib:format("~.2f",[PercentUsed])),
                    BinDelta = util:to_binary(io_lib:format("~.2f", [LargeDelta])),
                    Msg1 = <<Host1/binary, " has seen a ", BinDelta/binary, "% increase in percentage to ",
                        BinPercent1/binary, "% of the process limit">>,
                    alerts:send_alert(<<Host1/binary, " has a high process creation rate.">>, Host1, <<"critical">>, Msg1)
            end
    end,
    util_monitor:record_state(?PROCESS_COUNT_TABLE, ?PROCESS_COUNT_PERCENT_KEY, PercentUsed, ?PROCESS_COUNT_OPTS),
    ok.


monitor_c2s_heap_size() ->
    Children = supervisor:which_children(halloapp_c2s_sup),
    Pids = [Pid || {_, Pid, _, _} <- Children],
    % Get at most 10 c2s processes
    SamplePids = lists:sublist(Pids, 10),

    case SamplePids of
        [] -> ok;
        _ ->
            HeapSizes = lists:foldl(
                fun(Pid, Acc) ->
                    {_, Size} = erlang:process_info(Pid, total_heap_size),
                    case erlang:process_info(Pid, total_heap_size) of
                        undefined ->
                            ?INFO("C2S Pid no longer alive: ~p", [Pid]),
                            Acc;
                        {_, Size} ->
                            ?INFO("Heap size of pid ~p process: ~p", [Pid, Size]),
                            [Size] ++ Acc
                    end
                end, [], SamplePids),
            Avg = lists:sum(HeapSizes)/length(HeapSizes),
            FormattedAvg = util:to_float(io_lib:format("~.1f",[Avg])),
            ?INFO("Average c2s heap size of ~p pids: ~p", [length(HeapSizes), FormattedAvg])
    end,
    ok.


-spec check_iam_role(Config :: erlcloud_aws:aws_config()) -> ok.
check_iam_role(Config) ->
    case config:is_prod_env() of
        false -> ok;
        true ->
            {ok, Result} = erlcloud_sts:get_caller_identity(Config),
            {arn, Arn} = lists:keyfind(arn, 1, Result),
            BinArn = util:to_binary(Arn),
            Role = case util:is_machine_stest() of
                true -> <<"s-test-perms">>;
                false -> <<"Jabber-instance-perms">>
            end,
            case binary:match(BinArn, Role) of
                nomatch -> send_role_change_alert(BinArn);
                _ -> ok
            end
    end.


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
    {State#state{active_pings = #{}}, NumFailedPings}.


check_states(#state{gen_servers = GenServers} = State) ->
    %% Check state histories and maybe trigger an alert
    lists:foreach(
        fun(Mod) ->
            StateHistory = get_state_history(Mod),
            %% do checks until one returns true (meaning an alert has been sent)
            check_consecutive_fails(Mod, StateHistory) orelse check_slow_process(Mod, StateHistory),
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
    case util_monitor:check_consecutive_fails(StateHistory) of
        false -> false;
        true ->
            ?ERROR("Sending unreachable process alert for: ~p", [Mod]),
            BinMod = proc_to_binary(Mod),
            BinNumConsecFails = util:to_binary(?CONSECUTIVE_FAILURE_THRESHOLD),
            Msg = <<BinMod/binary, " has failed last ", BinNumConsecFails/binary, " pings">>,
            alerts:send_process_unreachable_alert(BinMod, Msg),
            true
    end.


check_slow_process(Mod, StateHistory) ->
    case util_monitor:check_slow(StateHistory) of
        {false, _} -> false;
        {true, PercentFails} ->
            ?ERROR("Sending slow process alert for: ~p", [Mod]),
            BinMod = proc_to_binary(Mod),
            Msg = <<BinMod/binary, " failing ", (util:to_binary(PercentFails))/binary ,"% of pings">>,
            alerts:send_process_unreachable_alert(BinMod, Msg),
            true
    end.


-spec record_state(Mod :: atom(), State :: proc_state()) -> ok.
record_state(Mod, State) ->
    util_monitor:record_state(?MONITOR_TABLE, Mod, State).


send_stats(Mod, StateHistory) ->
    Window = ?MINUTES_MS div ?PING_INTERVAL_MS,
    SuccessRate = 1 - (util_monitor:get_num_fails(lists:sublist(StateHistory, Window)) / Window),
    ProcName = case Mod of
        {global, Name} -> Name;
        _ -> Mod
    end,
    stat:gauge(?NS, "process_uptime", round(SuccessRate * 100), [{process_name, ProcName}]),
    ok.


proc_to_binary(Proc) ->
    case Proc of
        {global, Name} -> util:to_binary(Name);
        _ -> util:to_binary(Proc)
    end.


is_gen_server(Proc) ->
    not lists:member(Proc, get_supervisors()).


send_role_change_alert(Info) ->
    Host = util:get_machine_name(),
    Msg = <<"IAM role change: ", Info/binary>>,
    alerts:send_iam_role_change_alert(Host, Msg).

