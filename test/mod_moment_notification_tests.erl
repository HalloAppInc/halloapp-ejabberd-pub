%%%-------------------------------------------------------------------
%%% copyright (C) 2022, halloapp, inc.
%%%
%%%
%%%-------------------------------------------------------------------
-module(mod_moment_notification_tests).
-author('vipin').

-include_lib("eunit/include/eunit.hrl").

-define(TIMESTAMP, 1667008095).  %% {{2022,10,29},{1,48,15}}


is_time_ok_test() ->
    tutil:meck_init(util, now, fun() -> ?TIMESTAMP end),

    %% PST, GMT-6 yesterday
    ?assert(mod_moment_notification:is_time_ok(<<"16507967982">>, undefined, 19, 19, 23)),
    ?assertEqual(false,
        mod_moment_notification:is_time_ok(<<"16507967982">>, undefined, 19, 20, 23)),

    %% GMT-7 yesterday
    ?assertEqual(true,
        mod_moment_notification:is_time_ok(<<"16507967982">>, -25200, 19, 18, 23)),
    ?assertEqual(false,
        mod_moment_notification:is_time_ok(<<"16507967982">>, -25200, 19, 19, 23)),

    %% GMT+14 today
    ?assertEqual(true,
        mod_moment_notification:is_time_ok(<<"16507967982">>, 50400, 15, 20, 23)),
    ?assertEqual(false,
        mod_moment_notification:is_time_ok(<<"16507967982">>, 25200, 16, 20, 23)),

    %% GMT+38 tomorrow
    ?assertEqual(true,
        mod_moment_notification:is_time_ok(<<"16507967982">>, 136800, 10, 20, 15)),
    ?assertEqual(false,
        mod_moment_notification:is_time_ok(<<"16507967982">>, 136800, 11, 20, 16)),

    tutil:meck_finish(util).
    
