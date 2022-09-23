%%%-------------------------------------------------------------------
%%% @author josh
%%% @copyright (C) 2021, HalloApp, Inc.
%%% @doc
%%%
%%% @end
%%% Created : 29. Jun 2021 10:06 AM
%%%-------------------------------------------------------------------
-module(util_monitor).
-author("josh").

-include("logger.hrl").
-include("monitor.hrl").
-include("ha_types.hrl").

%% API
-export([
    get_num_fails/1,
    get_state_history/2,
    record_state/3,
    record_state/4,
    send_ack/3,
    check_consecutive_fails/1,
    check_consecutive_fails/2,
    check_slow/1,
    check_slow/2,
    get_previous_state/4
]).

%%====================================================================
%% API
%%====================================================================

-spec get_num_fails(StateList :: list(proc_state())) -> non_neg_integer().
get_num_fails(StateList) ->
    lists:foldl(
        fun
            (?ALIVE_STATE, Acc) -> Acc;
            (?FAIL_STATE, Acc) -> Acc + 1
        end,
        0,
        StateList).


-spec get_state_history(Table :: ets:tab(), Key :: term()) -> list(term()).
get_state_history(Table, Key) ->
    case ets:lookup(Table, Key) of
        [] -> [];
        [{Key, StateHistory}] -> StateHistory
    end.


-spec record_state(Table :: ets:tab(), Key :: term(), State :: term()) -> ok.
record_state(Table, Key, State) ->
    record_state(Table, Key, State, []).

-spec record_state(Table :: ets:tab(), Key :: term(), State :: term(), Opts :: opts()) -> ok.
record_state(Table, Key, State, Opts) ->
    OptMap = maps:from_list(Opts),
    PingInterval = maps:get(ping_interval_ms, OptMap, ?PING_INTERVAL_MS),
    StateHistoryLenMs = maps:get(state_history_length_ms, OptMap, ?STATE_HISTORY_LENGTH_MS),
    PrevStates = get_state_history(Table, Key),
    % reduce the list only when it becomes twice as large as intended history size
    NewStates = case length(PrevStates) > 2 * (StateHistoryLenMs div PingInterval) of
        false -> [State | PrevStates];
        true ->
            NewPrevStates = lists:sublist(PrevStates, (StateHistoryLenMs div PingInterval) - 1),
            [State | NewPrevStates]
    end,
    true = ets:insert(Table, {Key, NewStates}),
    ok.


-spec send_ack(From :: pid(), To :: pid(), Msg :: term()) -> ok.
send_ack(_From, To, Msg) ->
    To ! Msg.

%%====================================================================
%% Checker functions
%% Return true if an alert must be sent
%%====================================================================

-spec check_consecutive_fails(StateHistory :: [proc_state()]) -> boolean().
check_consecutive_fails(StateHistory) ->
    check_consecutive_fails(StateHistory, []).

-spec check_consecutive_fails(StateHistory :: [proc_state()], Opts :: opts()) -> boolean().
check_consecutive_fails(StateHistory, Opts) ->
    OptMap = maps:from_list(Opts),
    ConsecFailThreshold = maps:get(consec_fail_threshold, OptMap, ?CONSECUTIVE_FAILURE_THRESHOLD),
    NumFails = util_monitor:get_num_fails(lists:sublist(StateHistory, ConsecFailThreshold)),
    NumFails >= ConsecFailThreshold.


-spec check_slow(StateHistory :: [proc_state()]) -> {boolean(), non_neg_integer()}.
check_slow(StateHistory) ->
    check_slow(StateHistory, []).

-spec check_slow(StateHistory :: [proc_state()], Opts :: opts()) -> {boolean(), non_neg_integer()}.
check_slow(StateHistory, Opts) ->
    case length(StateHistory) of
        0 -> {false, 0};
        _ ->
            OptMap = maps:from_list(Opts),
            HalfFailThreshold = maps:get(half_fail_threshold_ms, OptMap, ?HALF_FAILURE_THRESHOLD_MS),
            PingInterval = maps:get(ping_interval_ms, OptMap, ?PING_INTERVAL_MS),
            Window = HalfFailThreshold div PingInterval,
            StateHistoryWindow = lists:sublist(StateHistory, Window),
            NumFails = util_monitor:get_num_fails(StateHistoryWindow),
            {NumFails >= (0.5 * Window), round(NumFails / length(StateHistoryWindow) * 100)}
    end.


-spec get_previous_state(Table :: ets:tab(), Key :: term(), TimeAgo :: pos_integer(), Opts :: opts()) -> maybe(term()).
get_previous_state(Table, Key, TimeAgo, Opts) ->
    OptMap = maps:from_list(Opts),
    History = get_state_history(Table, Key),
    PingInterval = maps:get(ping_interval_ms, OptMap, ?PING_INTERVAL_MS),
    PrevStateIndex = TimeAgo div PingInterval,
    case PrevStateIndex =< length(History) of
        false -> undefined;
        true -> lists:nth(PrevStateIndex, History)
    end.
