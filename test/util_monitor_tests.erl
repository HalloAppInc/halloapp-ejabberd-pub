%%%-------------------------------------------------------------------
%%% @author josh
%%% @copyright (C) 2021, HalloApp, Inc.
%%% @doc
%%%
%%% @end
%%% Created : 20. Aug 2021 3:44 PM
%%%-------------------------------------------------------------------
-module(util_monitor_tests).
-author("josh").

-include("monitor.hrl").
-include_lib("tutil.hrl").

-define(PERFECT_STATE_HISTORY, lists:duplicate(20, ?ALIVE_STATE)).
-define(ALL_FAILS_STATE_HISTORY, lists:duplicate(20, ?FAIL_STATE)).
-define(SLOW_STATE_HISTORY, lists:map(
    fun(N) ->
        % mixed, but mostly fails, has 5 consecutive failures
        case (N band 1 =:= 1) orelse N < 5 of
            true -> ?FAIL_STATE;
            false -> ?ALIVE_STATE
        end
    end,
    lists:seq(1,20))).
-define(TEST_MOD, util_monitor_test_mod).
-define(TEST_TABLE, util_monitor).

get_num_fails_testparallel() ->
    {inparallel, [
        ?_assertEqual(length(?ALL_FAILS_STATE_HISTORY), util_monitor:get_num_fails(?ALL_FAILS_STATE_HISTORY)),
        ?_assertEqual(0, util_monitor:get_num_fails(?PERFECT_STATE_HISTORY)),
        ?_assertEqual(12, util_monitor:get_num_fails(?SLOW_STATE_HISTORY))
    ]}.


record_state_and_get_state_history_test() ->
    ets:new(?TEST_TABLE, [named_table, public]),
    ExpectedOutput = [?ALIVE_STATE, ?FAIL_STATE, ?ALIVE_STATE, ?FAIL_STATE, ?FAIL_STATE],
    lists:foreach(fun(State) -> util_monitor:record_state(?TEST_TABLE, ?TEST_MOD, State) end, ExpectedOutput),
    ActualOutput = util_monitor:get_state_history(?TEST_TABLE, ?TEST_MOD),
    ets:delete(?TEST_TABLE),
    ?assertEqual(lists:reverse(ExpectedOutput), ActualOutput).


check_consecutive_fails_testparallel() ->
    {inparallel, [
        ?_assert(util_monitor:check_consecutive_fails(
            lists:duplicate(?CONSECUTIVE_FAILURE_THRESHOLD, ?FAIL_STATE))),
        ?_assertNot(util_monitor:check_consecutive_fails(
            lists:duplicate(?CONSECUTIVE_FAILURE_THRESHOLD - 1, ?FAIL_STATE))),
        ?_assertNot(util_monitor:check_consecutive_fails(
            lists:duplicate(?CONSECUTIVE_FAILURE_THRESHOLD, ?ALIVE_STATE))),
        ?_assert(util_monitor:check_consecutive_fails(?ALL_FAILS_STATE_HISTORY)),
        ?_assertNot(util_monitor:check_consecutive_fails(?PERFECT_STATE_HISTORY)),
        ?_assert(util_monitor:check_consecutive_fails(?SLOW_STATE_HISTORY))
    ]}.


check_slow_testparallel() ->
    {inparallel, [
        ?_assertEqual({true, 100}, util_monitor:check_slow(?ALL_FAILS_STATE_HISTORY)),
        ?_assertEqual({false, 0}, util_monitor:check_slow(?PERFECT_STATE_HISTORY)),
        ?_assertEqual({false, 0}, util_monitor:check_slow([])),
        ?_assertEqual({true, 60}, util_monitor:check_slow(?SLOW_STATE_HISTORY))
    ]}.

