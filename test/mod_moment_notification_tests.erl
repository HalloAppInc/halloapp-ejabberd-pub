%%%-------------------------------------------------------------------
%%% copyright (C) 2022, halloapp, inc.
%%%
%%%
%%%-------------------------------------------------------------------
-module(mod_moment_notification_tests).
-author('vipin').

-include_lib("eunit/include/eunit.hrl").


% is_time_ok_test() ->
%     %% PST, GMT-6 yesterday
%     ?assertEqual({true, 0, -1},
%         mod_moment_notification:is_time_ok(
%             mod_moment_notification:get_local_time_in_minutes(<<"16507967982">>, undefined, 1, 48),
%             19 * 60,
%             19 * 60,
%             23 * 60)),
%     ?assertEqual({false, 0, -1},
%         mod_moment_notification:is_time_ok(
%             mod_moment_notification:get_local_time_in_minutes(<<"16507967982">>, undefined, 1, 48),
%             19 * 60,
%             20 * 60,
%             23 * 60)),

%     %% GMT-7 yesterday
%     ?assertEqual({true, 3, -1},
%         mod_moment_notification:is_time_ok(
%             mod_moment_notification:get_local_time_in_minutes(<<"16507967982">>, -25200, 1, 48),
%             19 * 60,
%             18 * 60 + 51,
%             23 * 60)),
%     ?assertEqual({false, 0, -1},
%         mod_moment_notification:is_time_ok(
%             mod_moment_notification:get_local_time_in_minutes(<<"16507967982">>, -25200, 1, 48),
%             19 * 60,
%             19 * 60,
%             23)),

%     %% GMT+14 today
%     ?assertEqual({true, 3, 0},
%         mod_moment_notification:is_time_ok(
%             mod_moment_notification:get_local_time_in_minutes(<<"16507967982">>, 50400, 1, 48),
%             15 * 60 + 51,
%             20 * 60,
%             23 * 60)),
%     ?assertEqual({false, 0, 0},
%         mod_moment_notification:is_time_ok(
%             mod_moment_notification:get_local_time_in_minutes(<<"16507967982">>, 50400, 1, 48),
%             16 * 60,
%             20 * 60,
%             23 * 60)),

%     %% GMT+38 tomorrow
%     ?assertEqual({true, 3, 1},
%         mod_moment_notification:is_time_ok(
%             mod_moment_notification:get_local_time_in_minutes(<<"16507967982">>, 136800, 1, 48),
%             10 * 60,
%             20 * 60,
%             15 * 60 + 51)),
%     ?assertEqual({false, 0, 1},
%         mod_moment_notification:is_time_ok(
%             mod_moment_notification:get_local_time_in_minutes(<<"16507967982">>, 136800, 1, 48),
%             11 * 60,
%             20 * 60,
%             16 * 60)).
    
