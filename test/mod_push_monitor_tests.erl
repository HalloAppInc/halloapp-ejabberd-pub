%%%-------------------------------------------------------------------------------------------
%%% File    : mod_push_monitor_tests.erl
%%%
%%% Copyright (C) 2022 HalloApp inc.
%%%-------------------------------------------------------------------------------------------
-module(mod_push_monitor_tests).
-author('michelle').

-include_lib("eunit/include/eunit.hrl").

setup() ->
    tutil:setup(),
    {ok, _} = application:ensure_all_started(stringprep),
    ha_redis:start(),
    ok.


meck_init(Mod, FunName, Fun) ->
    meck:new(Mod, [passthrough]),
    meck:expect(Mod, FunName, Fun).


meck_finish(Mod) ->
    ?assert(meck:validate(Mod)),
    meck:unload(Mod).


push_status_android_test() ->
    setup(),
    meck_init(alerts, send_alert, fun(_,_,_,_) -> ok end),
    State = #{ios_pushes => [0], android_pushes => []},
    State1 = mod_push_monitor:push_status(failure, android, State),
    State1 = #{ios_pushes => [0], android_pushes => [0]},
    State2 = mod_push_monitor:push_status(success, android, State1),
    State2 = #{ios_pushes => [0], android_pushes => [1, 0]},
    State3 = mod_push_monitor:push_status(failure, android, State2),
    State3 = #{ios_pushes => [0], android_pushes => [0, 1, 0]},

    AlertRate = [0 || _ <- lists:seq(1,100)],

    State4 = #{ios_pushes => [], android_pushes => AlertRate},
    State5 = mod_push_monitor:push_status(success, android, State4),
    NewSuccessList = [1] ++ [0 || _ <- lists:seq(1,99)],
    State5 = #{ios_pushes => [], android_pushes => NewSuccessList},
    ?assert(meck:called(alerts, send_alert, ['_', '_', '_', '_'])),

    meck_finish(alerts),
    ok.


push_status_ios_test() ->
    setup(),
    meck_init(alerts, send_alert, fun(_,_,_,_) -> ok end),
    State = #{android_pushes => [0], ios_pushes => []},
    State1 = mod_push_monitor:push_status(failure, ios, State),
    State1 = #{android_pushes => [0], ios_pushes => [0]},
    State2 = mod_push_monitor:push_status(success, ios, State1),
    State2 = #{android_pushes => [0], ios_pushes => [1, 0]},
    State3 = mod_push_monitor:push_status(failure, ios, State2),
    State3 = #{android_pushes => [0], ios_pushes => [0, 1, 0]},

    AlertRate = [0 || _ <- lists:seq(1,100)],

    State4 = #{android_pushes => [], ios_pushes => AlertRate},
    State5 = mod_push_monitor:push_status(success, ios, State4),
    NewSuccessList = [1] ++ [0 || _ <- lists:seq(1,99)],
    State5 = #{android_pushes => [], ios_pushes => NewSuccessList},
    ?assert(meck:called(alerts, send_alert, ['_', '_', '_', '_'])),

    meck_finish(alerts),
    ok.
    

check_error_rate_test() ->
    setup(),
    meck_init(alerts, send_alert, fun(_,_,_,_) -> ok end),

    % info for <15% error rate
    InfoRate = [0] ++ [1 || _ <- lists:seq(1,10)],
    9.09 = mod_push_monitor:check_error_rate(InfoRate, android),
    9.09 = mod_push_monitor:check_error_rate(InfoRate, ios),

    % warning for >15% error rate
    WarningRate = [0] ++ [1 || _ <- lists:seq(1,5)],
    16.67 = mod_push_monitor:check_error_rate(WarningRate, android),
    16.67 = mod_push_monitor:check_error_rate(WarningRate, ios),

    % error for >25% error rate
    ErrorRate = [0] ++ [1 || _ <- lists:seq(1,2)],
    33.33 = mod_push_monitor:check_error_rate(ErrorRate, android),
    33.33 = mod_push_monitor:check_error_rate(ErrorRate, ios),

    % alert for >50% error rate
    AlertRate = [0 || _ <- lists:seq(1,10)],
    100.0 = mod_push_monitor:check_error_rate(AlertRate, android),
    100.0 = mod_push_monitor:check_error_rate(AlertRate, ios),
    meck_finish(alerts),

    ok.

