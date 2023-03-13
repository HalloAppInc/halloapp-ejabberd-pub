%%%-------------------------------------------------------------------
%%% copyright (C) 2022, halloapp, inc.
%%%
%%%
%%%-------------------------------------------------------------------
-module(mod_moment_notification2_tests).
-author(josh).

-include("time.hrl").
-include_lib("tutil.hrl").

%%====================================================================
%% Setup
%%====================================================================

-define(MOMENT_INFO_MAP, #{
    19 => #{
        date => 19,
        mins_to_send => ((15 * ?HOURS) + (34 * ?MINUTES)) div 60,
        notif_id => 1676764800,
        notif_type => live_camera,
        prompt => <<"P19">>
    },
    20 => #{
        date => 20,
        mins_to_send => ((12 * ?HOURS) + (1 * ?MINUTES)) div 60,
        notif_id => 1676851200,
        notif_type => text_post,
        prompt => <<"P20">>
    },
    21 => #{
        date => 21,
        mins_to_send => ((20 * ?HOURS) + (59 * ?MINUTES)) div 60,
        notif_id => 1676937600,
        notif_type => live_camera,
        prompt => <<"P21">>
    },
    22=> #{
        date => 22,
        mins_to_send => ((10 * ?HOURS) + (23 * ?MINUTES)) div 60,
        notif_id => 1677024000,
        notif_type => text_post,
        prompt => <<"P22">>
    },
    23 => #{
        date => 23,
        mins_to_send => ((18 * ?HOURS) + (0 * ?MINUTES)) div 60,
        notif_id => 1677110400,
        notif_type => live_camera,
        prompt => <<"P23">>
    }}).

setup() ->
    CleanupInfo = tutil:setup([
        {redis, [redis_accounts, redis_feed]},
%%        {meck, timer, apply_after, fun(A, B, C, D) -> ?debugFmt("~p | ~p | ~p | ~p", [A, B, C, D]) end},  % for debugging
        {meck, timer, apply_after, fun(_, _, _, _) -> ok end},  % use above line for debugging calls to this
%%        {meck, util_moments, calculate_notif_timestamp, fun(A, B, C) -> ?debugFmt("~p | ~p | ~p", [A, B, C]), 0 end},  % for debugging
        {meck, util_moments, calculate_notif_timestamp, fun(_, _, _) -> 0 end},  % use above line for debugging calls to this
        {meck ,util, now, fun() -> 1675209600 end}  %% Feb 1, 2023 | Need this so that the OffsetHrToSend is non-DST hour
    ]),
    %% Set moment time to send + info for moment notif info outlined in ?MOMENT_INFO_MAP
    maps:foreach(
        fun(Date, InfoMap) ->
            model_feed:set_moment_time_to_send(
                maps:get(mins_to_send, InfoMap),
                maps:get(notif_id, InfoMap),
                maps:get(notif_type, InfoMap),
                maps:get(prompt, InfoMap),
                Date)
        end,
        ?MOMENT_INFO_MAP),
    %% Create some uids in different zone offsets
    UidNeg8 = tutil:generate_uid(?KATCHUP),
    UidGmt = tutil:generate_uid(?KATCHUP),
    UidPos6 = tutil:generate_uid(?KATCHUP),
    ok = model_accounts:create_account(UidNeg8, <<"1">>, <<>>),
    ok = model_accounts:create_account(UidGmt, <<"2">>, <<>>),
    ok = model_accounts:create_account(UidPos6, <<"3">>, <<>>),
    ok = model_accounts:update_zone_offset_hr_index(UidNeg8, -8 * ?HOURS, undefined),
    ok = model_accounts:update_zone_offset_hr_index(UidGmt, 0 * ?HOURS, undefined),
    ok = model_accounts:update_zone_offset_hr_index(UidPos6, 6 * ?HOURS, undefined),
    ok = model_accounts:set_push_token(UidNeg8, <<>>, <<>>, util:now(), <<>>, -8 * ?HOURS),
    ok = model_accounts:set_push_token(UidGmt, <<>>, <<>>, util:now(), <<>>, 0 * ?HOURS),
    ok = model_accounts:set_push_token(UidPos6, <<>>, <<>>, util:now(), <<>>, 6 * ?HOURS),
    CleanupInfo#{uid_neg8 => UidNeg8, uid_gmt => UidGmt, uid_pos6 => UidPos6}.

%%====================================================================
%% Test fixtures
%%====================================================================

%% This fun is called by send_latest_notification and maybe_schedule_moment_notif
%% So if all are failing, check here first
get_current_offsets_testset(_) ->
    #{19 := Expected19, 20 := Expected20, 21 := Expected21, 22 := Expected22, 23 := Expected23} = ?MOMENT_INFO_MAP,
    %% Time = 20:00 UTC on Feb 20, 2023
    [YesterdayInfoMap1, TodayInfoMap1, TomorrowInfoMap1] = mod_moment_notification2:get_current_offsets(1676923200),
    ExpectedYesterday1 = Expected19#{current_offset_hr => -29},
    ExpectedToday1 = Expected20#{current_offset_hr => -8},
    ExpectedTomorrow1 = Expected21#{current_offset_hr => 24},
    Tests1 = lists:map(
        fun({Test, Expected}) ->
            ?_assertEqual(Expected, Test)
        end,
        [{YesterdayInfoMap1, ExpectedYesterday1}, {TodayInfoMap1, ExpectedToday1}, {TomorrowInfoMap1, ExpectedTomorrow1}]),
    %% Time = 4:00 UTC on Feb 22, 2023
    [YesterdayInfoMap2, TodayInfoMap2, TomorrowInfoMap2] = mod_moment_notification2:get_current_offsets(1677038400),
    ExpectedYesterday2 = Expected21#{current_offset_hr => -8},
    ExpectedToday2 = Expected22#{current_offset_hr => 6},
    ExpectedTomorrow2 = Expected23#{current_offset_hr => 38},
    Tests2 = lists:map(
        fun({Test, Expected}) ->
            ?_assertEqual(Expected, Test)
        end,
        [{YesterdayInfoMap2, ExpectedYesterday2}, {TodayInfoMap2, ExpectedToday2}, {TomorrowInfoMap2, ExpectedTomorrow2}]),
    Tests1 ++ Tests2.


send_latest_notification_testset(#{uid_neg8 := UidNeg8, uid_gmt := UidGmt}) ->
    %% It is challenging to mock functions being called within their own module
    %% So test util_moment:calculate_notif_timestamp call instead, which has enough
    %% info for us to verify that the correct code was reached
    #{19 := ExpectedYesterday1, 20 := Expected2DaysAgo, 21 := ExpectedYesterday2} = ?MOMENT_INFO_MAP,
    [
        %% Time = 20:00 UTC on Feb 20, 2023
        ?_assertOk(mod_moment_notification2:send_latest_notification(UidNeg8, 1676923200, false)),
        ?_assert(meck:called(util_moments, calculate_notif_timestamp, [-1, maps:get(mins_to_send, ExpectedYesterday1), -8])),
        ?_assertEqual(1, meck:num_calls(util_moments, calculate_notif_timestamp, '_')),
        %% Time = 4:00 UTC on Feb 22, 2023
        ?_assertOk(mod_moment_notification2:send_latest_notification(UidGmt, 1677038400, false)),
        ?_assert(meck:called(util_moments, calculate_notif_timestamp, [-1, maps:get(mins_to_send, ExpectedYesterday2), 0])),
        ?_assertEqual(2, meck:num_calls(util_moments, calculate_notif_timestamp, '_')),
        ?_assertOk(mod_moment_notification2:send_latest_notification(UidNeg8, 1677038400, false)),
        ?_assert(meck:called(util_moments, calculate_notif_timestamp, [-2, maps:get(mins_to_send, Expected2DaysAgo), -8])),
        ?_assertEqual(3, meck:num_calls(util_moments, calculate_notif_timestamp, '_'))
    ].


maybe_schedule_moment_notif_testset(_) ->
    #{20 := ExpectedToday1, 21 := ExpectedYesterday2, 22 := ExpectedToday2} = ?MOMENT_INFO_MAP,
    [
        %% Time = 20:00 UTC on Feb 20, 2023
        ?_assertOk(mod_moment_notification2:maybe_schedule_moment_notif(1676923200, false)),
        ?_assert(meck:called(timer, apply_after, [1 * ?MINUTES_MS, mod_moment_notification2, check_and_send_moment_notifications,
            [-8, 20, maps:get(notif_id, ExpectedToday1), maps:get(notif_type, ExpectedToday1), maps:get(prompt, ExpectedToday1)]])),
        ?_assertEqual(1, meck:num_calls(timer, apply_after, '_')),
        %% Time = 4:00 UTC on Feb 22, 2023
        ?_assertOk(mod_moment_notification2:maybe_schedule_moment_notif(1677038400, false)),
        ?_assert(meck:called(timer, apply_after, [59 * ?MINUTES_MS, mod_moment_notification2, check_and_send_moment_notifications,
            [-8, 21, maps:get(notif_id, ExpectedYesterday2), maps:get(notif_type, ExpectedYesterday2), maps:get(prompt, ExpectedYesterday2)]])),
        ?_assert(meck:called(timer, apply_after, [23 * ?MINUTES_MS, mod_moment_notification2, check_and_send_moment_notifications,
            [6, 22, maps:get(notif_id, ExpectedToday2), maps:get(notif_type, ExpectedToday2), maps:get(prompt, ExpectedToday2)]])),
        ?_assertEqual(3, meck:num_calls(timer, apply_after, '_'))
    ].

%%====================================================================
%% Non-fixture tests
%%====================================================================

get_regions_test() ->
    %% Ensures that a region is defined for every offset hr and that regions do not overlap
    AllOffsetHrs = lists:flatmap(
        fun({_Region, Predicate, OffsetHrToSend}) ->
            %% Check that the OffsetHrToSend is within the region's definition
            ?assert(Predicate(OffsetHrToSend)),
            %% Build a list of every offset hr covered in this region's definition
            lists:filter(Predicate, lists:seq(-12, 14))
        end,
        mod_moment_notification2:get_regions()),
    %% Check that every offset hr is defined in one and only one region
    ?assertEqual(lists:seq(-12, 14), lists:sort(AllOffsetHrs)).
