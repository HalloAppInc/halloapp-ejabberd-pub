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
    monitor/1,
    get_state_history/1,
    try_remonitor/1
]).

%%====================================================================
%% API
%%====================================================================

start_link() ->
    ?INFO("Starting monitoring process: ~p", [?MODULE]),
    Result = gen_server:start_link({local, ?MODULE}, ?MODULE, [], []),
    monitor_ejabberd_processes(),
    Result.

stop() ->
    ejabberd_sup:stop_child(?MODULE).

get_monitored_procs() ->
    gen_server:call(?MODULE, get_monitored_procs).

ping_procs() ->
    gen_server:cast(?MODULE, ping_procs).

-spec monitor(Proc :: atom() | pid()) -> ok.
monitor(Proc) ->
    gen_server:cast(?MODULE, {monitor, Proc}),
    ok.

-spec get_state_history(Mod :: atom()) -> list(proc_state()).
get_state_history(Mod) ->
    case ets:lookup(?MONITOR_TABLE, Mod) of
        [] -> [];
        [{Mod, StateHistory}] -> StateHistory
    end.

try_remonitor(Proc) ->
    case whereis(Proc) of
        undefined ->
            ?ERROR("Process ~p unable to be found, cannot remonitor", [Proc]),
            {ok, _TRef} = timer:apply_after(?REMONITOR_DELAY_MS, ?MODULE, try_remonitor, [Proc]);
        _Pid -> gen_server:cast(?MODULE, {monitor, Proc})
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
    ?INFO("Start: ~p", [?MODULE]),
    {ok, TRef} = timer:apply_interval(?PING_INTERVAL_MS, ?MODULE, ping_procs, []),
    ets:new(?MONITOR_TABLE, [named_table, public]),
    {ok, #state{monitors = #{}, active_pings = #{}, gen_servers = [], tref = TRef}}.


terminate(_Reason, #state{tref = TRef} = _State) ->
    ?INFO("Terminate: ~p", [?MODULE]),
    timer:cancel(TRef),
    ets:delete(?MONITOR_TABLE),
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
        _ -> alerts:send_process_down_alert(Proc, <<"Process is dead">>)
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
    %% TODO: we pass true/false to monitor if a mod is a gen_server,
    %% we should update this to be more dynamic
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
            end
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

get_state_memory_size() ->
    ?STATE_HISTORY_LENGTH_MS div ?PING_INTERVAL_MS.

is_gen_server(Proc) ->
    not lists:member(Proc, get_supervisors()).

