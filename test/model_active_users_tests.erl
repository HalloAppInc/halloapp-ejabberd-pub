%%%-------------------------------------------------------------------
%%% @author josh
%%% @copyright (C) 2020, HalloApp, Inc.
%%% @doc
%%%
%%% @end
%%% Created : 01. Jul 2020 1:37 PM
%%%-------------------------------------------------------------------
-module(model_active_users_tests).
-author("josh").

-include("time.hrl").
-include("tutil.hrl").

-define(PHONE, 16175280000).
-define(NAME, <<"Name">>).
-define(UA_ANDROID, <<"HalloApp/Android1.0">>).
-define(UA_IOS, <<"HalloApp/iPhone1.0">>).
-define(RESOURCE_ANDROID, <<"android">>).
-define(RESOURCE_IOS, <<"iphone">>).

%% -------------------------------------------- %%
%% Tests
%% -------------------------------------------- %%

set_testset(#{testdata := {[Uid | _Rest], _KaUids}} = _CleanupInfo) ->
    [
        ?_assertEqual(0, model_active_users:count_active_users_between(all, 0, inf, halloapp)),
        ?_assertEqual(0, model_active_users:count_active_users_between(all, 0, inf, katchup)),
        ?_assertOk(mod_active_users:update_last_activity(Uid, util:now_ms(), ?RESOURCE_ANDROID)),
        ?_assertEqual(1, model_active_users:count_active_users_between(all, 0, inf, halloapp)),
        ?_assertEqual(0, model_active_users:count_active_users_between(all, 0, inf, katchup))
        ].


count_testset(#{testdata := {HaUids, _KaUids}} = _CleanupInfo) ->
    Now = util:now_ms(),
    Days1 = length([mod_active_users:update_last_activity(
        Uid, Now - random:uniform(?DAYS_MS), ?RESOURCE_ANDROID
        ) || Uid <- lists:sublist(HaUids, 1, 3)
    ]),
    Days7 = Days1 + length([mod_active_users:update_last_activity(
        Uid, Now - ?WEEKS_MS + random:uniform(6 * ?DAYS_MS), ?RESOURCE_IOS
    ) || Uid <- lists:sublist(HaUids, 4, 3)
    ]),
    Days28 = Days7 + length([mod_active_users:update_last_activity(
        Uid, Now - (28 * ?DAYS_MS) + random:uniform(14 * ?DAYS_MS), ?RESOURCE_ANDROID
    ) || Uid <- lists:sublist(HaUids, 7, 3)
    ]),
    Days30 = Days28 + length([mod_active_users:update_last_activity(
        Uid, Now - (30 * ?DAYS_MS) + random:uniform(2 * ?DAYS_MS), ?RESOURCE_IOS
    ) || Uid <- lists:sublist(HaUids, 10, 3)
    ]),
    Day1Count = [mod_active_users:count_halloapp_active_users_1day(Type) || Type <- [all, android, ios]],
    Day7Count = [mod_active_users:count_halloapp_active_users_7day(Type) || Type <- [all, android, ios]],
    Day28Count = [mod_active_users:count_halloapp_active_users_28day(Type) || Type <- [all, android, ios]],
    Day30Count = [mod_active_users:count_halloapp_active_users_30day(Type) || Type <- [all, android, ios]],
    Day30Count = [model_active_users:count_active_users_between(Type, 0, inf, halloapp) || Type <- [all, android, ios]],
    [
        ?_assertEqual([Days1, Days1, 0], Day1Count),
        ?_assertEqual([Days7, Days1, Days7 - Days1],  Day7Count),
        ?_assertEqual([Days28, Days28 - Days7 + Days1, Days7 - Days1], Day28Count),
        ?_assertEqual([Days30, Days28 - Days7 + Days1, Days30 - Days28 + Days7 - Days1], Day30Count),
        ?_assertEqual([12, 6, 6], Day30Count),
        ?_assertEqual(0, model_active_users:count_active_users_between(all, 0, inf, katchup))
    ].


cleanup_testset(#{testdata := {HaUids, _KaUids}} = _CleanupInfo) ->
    Now = util:now_ms(),
    ActiveUsers = length([mod_active_users:update_last_activity(
        Uid, Now - random:uniform(30 * ?DAYS_MS), ?RESOURCE_ANDROID
    ) || Uid <- lists:sublist(HaUids, 1, 6)
    ]),
    InactiveUsers = length([mod_active_users:update_last_activity(
        Uid, Now - (30 * ?DAYS_MS) - random:uniform(?WEEKS_MS), ?RESOURCE_IOS
    ) || Uid <- lists:sublist(HaUids, 7, 6)
    ]),
    [
        ?_assertEqual([ActiveUsers + InactiveUsers, ActiveUsers, InactiveUsers],
            [model_active_users:count_active_users_between(Type, 0, inf, halloapp) || Type <- [all, android, ios]]),
        ?_assertOk(model_active_users:cleanup()),
        ?_assertEqual([ActiveUsers, ActiveUsers, 0],
            [model_active_users:count_active_users_between(Type, 0, inf, halloapp) || Type <- [all, android, ios]])
    ].


count_engaged_users_testset(#{testdata := {HaUids, _KaUids}} = _CleanupInfo) ->
    Now = util:now_ms(),
    % 3 android users post in last 1 day
    [mod_engaged_users:update_last_activity(
        Uid, post, Now - random:uniform(?DAYS_MS), android
        ) || Uid <- lists:sublist(HaUids, 1, 3)
    ],
    % 3 ios users comment in last 7 day
    [mod_engaged_users:update_last_activity(
        Uid, comment, Now - ?WEEKS_MS + random:uniform(6 * ?DAYS_MS), ios
        ) || Uid <- lists:sublist(HaUids, 4, 3)
    ],
    % 3 android users post in last 28 day
    [mod_engaged_users:update_last_activity(
        Uid, post, Now - (28 * ?DAYS_MS) + random:uniform(14 * ?DAYS_MS), android
        ) || Uid <- lists:sublist(HaUids, 7, 3)
    ],
    % 3 ios users post in last 30 day
    [mod_engaged_users:update_last_activity(
        Uid, post, Now - (30 * ?DAYS_MS) + random:uniform(2 * ?DAYS_MS), ios
        ) || Uid <- lists:sublist(HaUids, 10, 3)
    ],
    AllTypes = [all, android, ios, post],
    Day1Count = [mod_engaged_users:count_halloapp_engaged_users_1day(Type) || Type <- AllTypes],
    Day7Count = [mod_engaged_users:count_halloapp_engaged_users_7day(Type) || Type <- AllTypes],
    Day28Count = [mod_engaged_users:count_halloapp_engaged_users_28day(Type) || Type <- AllTypes],
    Day30Count = [mod_engaged_users:count_halloapp_engaged_users_30day(Type) || Type <- AllTypes],
    Day30Count = [model_active_users:count_engaged_users_between(Type, 0, inf, halloapp) || Type <- AllTypes],
    [
        ?_assertEqual([3, 3, 0, 3], Day1Count),
        ?_assertEqual([6, 3, 3, 3],  Day7Count),
        ?_assertEqual([9, 6, 3, 6], Day28Count),
        ?_assertEqual([12, 6, 6, 9], Day30Count),
        ?_assertEqual([12, 6, 6, 9], Day30Count)
    ].


cleanup_engaged_users_testset(#{testdata := {HaUids, _KaUids}} = _CleanupInfo) ->
    Now = util:now_ms(),
    EngagedUsers = length([mod_engaged_users:update_last_activity(
        Uid, post, Now - random:uniform(30 * ?DAYS_MS), android
    ) || Uid <- lists:sublist(HaUids, 1, 6)
    ]),
    UnEngagedUsers = length([mod_engaged_users:update_last_activity(
        Uid, post, Now - (30 * ?DAYS_MS) - random:uniform(?WEEKS_MS), ios
    ) || Uid <- lists:sublist(HaUids, 7, 6)
    ]),
    [
        ?_assertEqual([EngagedUsers + UnEngagedUsers, EngagedUsers, UnEngagedUsers],
            [model_active_users:count_engaged_users_between(Type, 0, inf, halloapp) || Type <- [all, android, ios]]),
        ?_assertOk(model_active_users:cleanup()),
        ?_assertEqual([EngagedUsers, EngagedUsers, 0],
            [model_active_users:count_engaged_users_between(Type, 0, inf, halloapp) || Type <- [all, android, ios]])
    ].

%% -------------------------------------------- %%
%% Internal functions
%% -------------------------------------------- %%

setup() ->
    CleanupInfo = tutil:setup([
        {redis, [redis_accounts]}
    ]),
    {HaUids, KaUids} = lists:unzip(create_accounts(12)),
    CleanupInfo#{testdata => {HaUids, KaUids}}.


create_accounts(0) ->
    [];

create_accounts(Num) ->
    UidHA = tutil:generate_uid(?HALLOAPP),
    UidKA = tutil:generate_uid(?KATCHUP),
    PhoneHA = integer_to_binary(?PHONE + Num),
    PhoneKA = integer_to_binary(?PHONE - Num),
    UsernamePrefix = ?NAME,
    NumBin = integer_to_binary(Num),
    case Num rem 2 of
        0 ->
            ok = model_accounts:create_account(UidHA, PhoneHA, ?UA_IOS),
            ok = model_accounts:set_name(UidHA, ?NAME),
            ok = model_accounts:create_account(UidKA, PhoneKA, ?UA_IOS),
            true = model_accounts:set_username(UidKA, <<UsernamePrefix/binary, NumBin/binary>>),
            ok = model_accounts:set_name(UidKA, ?NAME);
        1 ->
            ok = model_accounts:create_account(UidHA, PhoneHA, ?UA_ANDROID),
            ok = model_accounts:set_name(UidHA, ?NAME),
            ok = model_accounts:create_account(UidKA, PhoneKA, ?UA_ANDROID),
            true = model_accounts:set_username(UidKA, <<UsernamePrefix/binary, NumBin/binary>>),
            ok = model_accounts:set_name(UidKA, ?NAME)
    end,
    [{UidHA, UidKA}] ++ create_accounts(Num - 1).


% active_users_perf_test() ->
%     tutil:perf(
%         100,
%         fun() -> setup() end,
%         fun() -> model_active_users:count_active_users_between(all, 0, inf) end
%     ).


% engaged_users_perf_test()->
%     tutil:perf(
%         100,
%         fun() -> setup() end,
%         fun() -> model_active_users:count_engaged_users_between(all, 0, inf) end
%     ).

