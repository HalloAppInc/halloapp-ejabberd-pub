%%%-------------------------------------------------------------------
%%% copyright (C) 2022, halloapp, inc.
%%%
%%%
%%%-------------------------------------------------------------------
-module(mod_moment_notification2_tests).
-author(josh).

-include("feed.hrl").
-include("prompts.hrl").
-include("time.hrl").
-include_lib("tutil.hrl").

%%====================================================================
%% Setup
%%====================================================================

-define(MOMENT_INFO_MAP, #{
    19 => #{
        day_of_month => 19,
        date => "19/02/2023",
        mins_to_send => ((15 * ?HOURS) + (34 * ?MINUTES)) div 60,
        notif_id => 1676764800,
        notif_type => live_camera,
        promptId => <<"test.media.19">>,
        reminder => false
    },
    20 => #{
        day_of_month => 20,
        date => "20/02/2023",
        mins_to_send => ((12 * ?HOURS) + (1 * ?MINUTES)) div 60,
        notif_id => 1676851200,
        notif_type => text_post,
        promptId => <<"test.text.20">>,
        reminder => false
    },
    21 => #{
        day_of_month => 21,
        date => "21/02/2023",
        mins_to_send => ((20 * ?HOURS) + (59 * ?MINUTES)) div 60,
        notif_id => 1676937600,
        notif_type => live_camera,
        promptId => <<"test.media.21">>,
        reminder => false
    },
    22=> #{
        day_of_month => 22,
        date => "22/02/2023",
        mins_to_send => ((10 * ?HOURS) + (23 * ?MINUTES)) div 60,
        notif_id => 1677024000,
        notif_type => text_post,
        promptId => <<"test.text.22">>,
        reminder => false
    },
    23 => #{
        day_of_month => 23,
        date => "23/02/2023",
        mins_to_send => ((18 * ?HOURS) + (0 * ?MINUTES)) div 60,
        notif_id => 1677110400,
        notif_type => live_camera,
        promptId => <<"test.media.23">>,
        reminder => false
    }}).

meck_get_text_prompts() ->
    #{
        <<"test.text.20">> =>
        #prompt{
            text = <<"What food are you craving right now?">>,
            reuse_after = 6 * ?MONTHS},
        <<"test.text.22">> =>
        #prompt{
            text = <<"Describe your day in emojis">>,
            reuse_after = 6 * ?MONTHS}
    }.

meck_get_media_prompts() ->
    #{
        <<"test.media.19">> =>
        #prompt{
            text = <<"If you could live in any time period, which one would you choose?">>,
            reuse_after = 6 * ?MONTHS},
        <<"test.media.20">> =>
        #prompt{
            text = <<"A movie you thought was overrated, but turned out great">>,
            reuse_after = 6 * ?MONTHS},
        <<"test.media.21">> =>
        #prompt{
            text = <<"If you had to listen to only one artist for a week, who would it be?">>,
            reuse_after = 6 * ?MONTHS}
    }.

meck_get_prompt_from_id(PromptId) ->
    case PromptId of
        <<"test.text", _/binary>> ->
            maps:get(PromptId, meck_get_text_prompts(), undefined);
        <<"test.media", _/binary>> ->
            maps:get(PromptId, meck_get_media_prompts(), undefined);
        _ ->
            undefined
    end.


setup() ->
    CleanupInfo = tutil:setup([
        {redis, [redis_accounts, redis_feed]},
%%        {meck, timer, apply_after, fun(A, B, C, D) -> ?debugFmt("~p | ~p | ~p | ~p", [A, B, C, D]) end},  % for debugging
        {meck, timer, apply_after, fun(_, _, _, _) -> ok end},  % use above line for debugging calls to this
%%        {meck, util_moments, calculate_notif_timestamp, fun(A, B, C) -> ?debugFmt("~p | ~p | ~p", [A, B, C]), 0 end},  % for debugging
        {meck, util_moments, calculate_notif_timestamp, fun(_, _, _) -> 0 end},  % use above line for debugging calls to this
        {meck ,util, now, fun() -> 1675209600 end},  %% Feb 1, 2023 | Need this so that the OffsetHrToSend is non-DST hour
        {meck, mod_prompts, [
            {get_text_prompts, fun meck_get_text_prompts/0},
            {get_media_prompts, fun meck_get_media_prompts/0},
            {get_prompt_from_id, fun meck_get_prompt_from_id/1}
        ]}
    ]),
    %% Set moment time to send + info for moment notif info outlined in ?MOMENT_INFO_MAP
    maps:foreach(
        fun(Date, InfoMap) ->
            model_feed:set_moment_info(Date, #moment_notification{
                mins_to_send = maps:get(mins_to_send, InfoMap),
                id = maps:get(notif_id, InfoMap),
                type = maps:get(notif_type, InfoMap),
                promptId = maps:get(promptId, InfoMap)
            })
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
    #{19 := ExpectedYesterday1, 20 := Expected2DaysAgo, 21 := ExpectedYesterday2, 22 := ExpectedToday} = ?MOMENT_INFO_MAP,
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
        ?_assertEqual(3, meck:num_calls(util_moments, calculate_notif_timestamp, '_')),
        %% Time = 18:30 UTC on Feb 22, 2023
        ?_assertOk(mod_moment_notification2:send_latest_notification(UidNeg8, 1677090600, false)),
        ?_assert(meck:called(util_moments, calculate_notif_timestamp, [0, maps:get(mins_to_send, ExpectedToday), -8])),
        ?_assertEqual(4, meck:num_calls(util_moments, calculate_notif_timestamp, '_'))
    ].


maybe_schedule_moment_notif_testset(_) ->
    #{20 := ExpectedToday1, 21 := ExpectedYesterday2, 22 := ExpectedToday2} = ?MOMENT_INFO_MAP,
    Today1PromptRecord = meck_get_prompt_from_id(maps:get(promptId, ExpectedToday1)),
    YesterdayPromptRecord = meck_get_prompt_from_id(maps:get(promptId, ExpectedYesterday2)),
    Today2PromptRecord = meck_get_prompt_from_id(maps:get(promptId, ExpectedToday2)),
    [
        %% Time = 20:00 UTC on Feb 20, 2023
        ?_assertOk(mod_moment_notification2:maybe_schedule_moment_notif(1676923200, false)),
        ?_assert(meck:called(timer, apply_after, [1 * ?MINUTES_MS, mod_moment_notification2, check_and_send_moment_notifications,
            [-8, maps:get(date, ExpectedToday1), 20, maps:get(notif_id, ExpectedToday1), maps:get(notif_type, ExpectedToday1),
                Today1PromptRecord, <<>>, false]])),
        ?_assertEqual(1, meck:num_calls(timer, apply_after, '_')),
        %% Time = 4:00 UTC on Feb 22, 2023
        ?_assertOk(mod_moment_notification2:maybe_schedule_moment_notif(1677038400, false)),
        ?_assert(meck:called(timer, apply_after, [59 * ?MINUTES_MS, mod_moment_notification2, check_and_send_moment_notifications,
            [-8, maps:get(date, ExpectedYesterday2), 21, maps:get(notif_id, ExpectedYesterday2), maps:get(notif_type, ExpectedYesterday2),
                YesterdayPromptRecord, <<>>, false]])),
        ?_assert(meck:called(timer, apply_after, [23 * ?MINUTES_MS, mod_moment_notification2, check_and_send_moment_notifications,
            [6, maps:get(date, ExpectedToday2), 22, maps:get(notif_id, ExpectedToday2), maps:get(notif_type, ExpectedToday2),
                Today2PromptRecord, <<>>, false]])),
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
