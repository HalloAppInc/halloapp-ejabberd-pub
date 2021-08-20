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

%% API
-export([
    get_num_fails/1,
    get_state_history/2,
    record_state/3,
    send_ack/3,
    check_consecutive_fails/1,
    check_slow/1
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


-spec get_state_history(Table :: ets:tab(), Key :: term()) -> list(proc_state()).
get_state_history(Table, Key) ->
    case ets:lookup(Table, Key) of
        [] -> [];
        [{Key, StateHistory}] -> StateHistory
    end.


-spec record_state(Table :: ets:tab(), Key :: term(), State :: proc_state()) -> ok.
record_state(Table, Key, State) ->
    PrevStates = get_state_history(Table, Key),
    % reduce the list only when it becomes twice as large as intended history size
    NewStates = case length(PrevStates) > 2 * (?STATE_HISTORY_LENGTH_MS div ?PING_INTERVAL_MS) of
        false -> [State | PrevStates];
        true ->
            NewPrevStates = lists:sublist(PrevStates, (?STATE_HISTORY_LENGTH_MS div ?PING_INTERVAL_MS) - 1),
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
    NumFails = util_monitor:get_num_fails(lists:sublist(StateHistory, ?CONSECUTIVE_FAILURE_THRESHOLD)),
    NumFails >= ?CONSECUTIVE_FAILURE_THRESHOLD.


-spec check_slow(StateHistory :: [proc_state()]) -> {boolean(), non_neg_integer()}.
check_slow(StateHistory) ->
    Window = ?HALF_FAILURE_THRESHOLD_MS div ?PING_INTERVAL_MS,
    NumFails = util_monitor:get_num_fails(lists:sublist(StateHistory, Window)),
    {NumFails >= (0.5 * Window), round(NumFails / Window * 100)}.

