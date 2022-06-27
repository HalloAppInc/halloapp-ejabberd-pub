%%%-------------------------------------------------------------------
%%% @author josh
%%% @copyright (C) 2021, HalloApp, Inc.
%%% @doc
%%%
%%% @end
%%% Created : 06. Jul 2021 5:51 PM
%%%-------------------------------------------------------------------
-module(monitor_tests).
-author("josh").

-compile([nowarn_export_all, export_all]).
-include("logger.hrl").
-include("monitor.hrl").
-include("suite.hrl").
-include("packets.hrl").
-include("account_test_data.hrl").
-include_lib("stdlib/include/assert.hrl").

-define(BAD_PROC, ha_bad_process_global).

group() ->
    {monitor, [sequence], [
        monitor_ping_test,
        monitor_dummy_test,
        monitor_failed_ping_test,
        monitor_remonitor_test
%%        monitor_consecutive_failures_test
    ]}.

dummy_test(_Conf) ->
    ok = ok.

ping_test(_Conf) ->
    ejabberd_monitor:ping_procs(),
    timer:sleep(?PING_TIMEOUT_MS),
    lists:foreach(
        fun(Proc) ->
            History = ejabberd_monitor:get_state_history(Proc),
            ct:pal("~p: ~p", [Proc, History]),
            %% TODO(josh): remove case after ecredis is updated
            case string:find(util:to_list(Proc), "ecredis") of
                nomatch -> [?ALIVE_STATE | _] = History;
                _ -> ok
            end
        end,
        (sys:get_state(?MONITOR_GEN_SERVER))#state.gen_servers).

failed_ping_test(_Conf) ->
    ha_bad_process:be_slow(),
    #{state := slow} = sys:get_state(?BAD_PROC),
    ejabberd_monitor:ping_procs(),
    timer:sleep(?PING_TIMEOUT_MS),
    ejabberd_monitor:ping_procs(),   % checks and records failed pings
    timer:sleep(100),   % allow time for state to be checked
    true = lists:member(?FAIL_STATE, ejabberd_monitor:get_state_history(?BAD_PROC)).

remonitor_test(_Conf) ->
    InitialPid = whereis(?BAD_PROC),
    true = undefined =/= InitialPid,
    true = is_monitored_gen_server(?BAD_PROC),
    ok = ha_bad_process:kill(),
    timer:sleep(?REMONITOR_DELAY_MS * 5),
    FinalPid = whereis(?BAD_PROC),
    true = InitialPid =/= FinalPid,
    true = undefined =/= FinalPid,
    true = is_monitored_gen_server(?BAD_PROC).

%% TODO(josh): figure out how to test this
%%consecutive_failures_test(_Conf) ->
%%    #{state := slow} = sys:get_state(?BAD_PROC),
%%    lists:foreach(fun(_) -> ejabberd_monitor:ping_procs() end,
%%        lists:seq(1, ?CONSECUTIVE_FAILURE_THRESHOLD)),
%%    timer:sleep(?PING_TIMEOUT * ?CONSECUTIVE_FAILURE_THRESHOLD),
%%    %% figure out some way to test if alert was sent


%%% Internal functions %%%

is_monitored_gen_server(Mod) ->
    lists:member(Mod, (sys:get_state(?MONITOR_GEN_SERVER))#state.gen_servers).

