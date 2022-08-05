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


push_monitor_android_test() ->
    setup(),
    meck_init(alerts, send_alert, fun(_,_,_,_) -> ok end),
    {Android1, Ios1} = mod_push_monitor:push_monitor(failure, android, [], [0]),
    ?assertEqual({[0], [0]}, {Android1, Ios1}),
    {Android2, Ios2} = mod_push_monitor:push_monitor(success, android, Android1, Ios1),
    ?assertEqual({[1, 0], [0]}, {Android2, Ios2}),
    {Android3, Ios3} = mod_push_monitor:push_monitor(failure, android, Android2, Ios2),
    ?assertEqual({[0, 1, 0], [0]}, {Android3, Ios3}),

    AlertRate = [0 || _ <- lists:seq(1,100)],

    {Android4, Ios4} = {AlertRate, []},
    {Android5, Ios5} = mod_push_monitor:push_monitor(success, android, Android4, Ios4),
    NewSuccessList = [1] ++ [0 || _ <- lists:seq(1,99)],
    ?assertEqual({NewSuccessList, []}, {Android5, Ios5}),
    ?assert(meck:called(alerts, send_alert, ['_', '_', '_', '_'])),

    meck_finish(alerts),
    ok.


push_monitor_ios_test() ->
    setup(),
    meck_init(alerts, send_alert, fun(_,_,_,_) -> ok end),
    {Android1, Ios1} = mod_push_monitor:push_monitor(failure, ios, [0], []),
    ?assertEqual({[0], [0]}, {Android1, Ios1}),
    {Android2, Ios2} = mod_push_monitor:push_monitor(success, ios, Android1, Ios1),
    ?assertEqual({[0], [1, 0]}, {Android2, Ios2}),
    {Android3, Ios3} = mod_push_monitor:push_monitor(failure, ios, Android2, Ios2),
    ?assertEqual({[0], [0, 1, 0]}, {Android3, Ios3}),

    AlertRate = [0 || _ <- lists:seq(1,100)],

    {Android4, Ios4} = {[], AlertRate},
    {Android5, Ios5} = mod_push_monitor:push_monitor(success, ios, Android4, Ios4),
    NewSuccessList = [1] ++ [0 || _ <- lists:seq(1,99)],
    ?assertEqual({[], NewSuccessList}, {Android5, Ios5}),
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

