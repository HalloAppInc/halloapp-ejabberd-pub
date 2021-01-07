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
-include_lib("eunit/include/eunit.hrl").

-define(UID, 1000000024384563984).
-define(PHONE, 16175280000).
-define(NAME, <<"Name">>).
-define(UA_ANDROID, <<"HalloApp/Android1.0">>).
-define(UA_IOS, <<"HalloApp/iPhone1.0">>).
-define(RESOURCE_ANDROID, <<"android">>).
-define(RESOURCE_IOS, <<"iphone">>).

%% -------------------------------------------- %%
%% Tests
%% -------------------------------------------- %%

set_test() ->
    setup(),
    ?assertEqual(0, model_active_users:count_active_users_between(all, 0, inf)),
    ok = mod_active_users:update_last_activity(integer_to_binary(?UID + 1), util:now_ms(), ?RESOURCE_ANDROID),
    ?assertEqual(1, model_active_users:count_active_users_between(all, 0, inf)).


count_test() ->
    setup(),
    Now = util:now_ms(),
    Days1 = length([mod_active_users:update_last_activity(
        integer_to_binary(?UID + Num), Now - random:uniform(?DAYS_MS), ?RESOURCE_ANDROID
        ) || Num <- lists:seq(1,3)
    ]),
    Days7 = Days1 + length([mod_active_users:update_last_activity(
        integer_to_binary(?UID + Num), Now - ?WEEKS_MS + random:uniform(6 * ?DAYS_MS), ?RESOURCE_IOS
    ) || Num <- lists:seq(4,6)
    ]),
    Days28 = Days7 + length([mod_active_users:update_last_activity(
        integer_to_binary(?UID + Num), Now - (28 * ?DAYS_MS) + random:uniform(14 * ?DAYS_MS), ?RESOURCE_ANDROID
    ) || Num <- lists:seq(7,9)
    ]),
    Days30 = Days28 + length([mod_active_users:update_last_activity(
        integer_to_binary(?UID + Num), Now - (30 * ?DAYS_MS) + random:uniform(2 * ?DAYS_MS), ?RESOURCE_IOS
    ) || Num <- lists:seq(10,12)
    ]),
    Day1Count = [mod_active_users:count_active_users_1day(Type) || Type <- [all, android, ios]],
    ?assertEqual([Days1, Days1, 0], Day1Count),
    Day7Count = [mod_active_users:count_active_users_7day(Type) || Type <- [all, android, ios]],
    ?assertEqual([Days7, Days1, Days7 - Days1],  Day7Count),
    Day28Count = [mod_active_users:count_active_users_28day(Type) || Type <- [all, android, ios]],
    ?assertEqual([Days28, Days28 - Days7 + Days1, Days7 - Days1], Day28Count),
    Day30Count = [mod_active_users:count_active_users_30day(Type) || Type <- [all, android, ios]],
    ?assertEqual([Days30, Days28 - Days7 + Days1, Days30 - Days28 + Days7 - Days1], Day30Count),
    Day30Count = [model_active_users:count_active_users_between(Type, 0, inf) || Type <- [all, android, ios]],
    ?assertEqual([12, 6, 6], Day30Count).


cleanup_test() ->
    setup(),
    Now = util:now_ms(),
    ActiveUsers = length([mod_active_users:update_last_activity(
        integer_to_binary(?UID + Num), Now - random:uniform(30 * ?DAYS_MS), ?RESOURCE_ANDROID
    ) || Num <- lists:seq(1, 6)
    ]),
    InactiveUsers = length([mod_active_users:update_last_activity(
        integer_to_binary(?UID + Num), Now - (30 * ?DAYS_MS) - random:uniform(?WEEKS_MS), ?RESOURCE_IOS
    ) || Num <- lists:seq(7, 12)
    ]),
    Before = [model_active_users:count_active_users_between(Type, 0, inf) || Type <- [all, android, ios]],
    ?assertEqual([ActiveUsers + InactiveUsers, ActiveUsers, InactiveUsers], Before),
    ok = model_active_users:cleanup(),
    After = [model_active_users:count_active_users_between(Type, 0, inf) || Type <- [all, android, ios]],
    ?assertEqual([ActiveUsers, ActiveUsers, 0], After).


count_engaged_users_test() ->
    setup(),
    Now = util:now_ms(),
    Days1 = length([mod_engaged_users:update_last_activity(
        integer_to_binary(?UID + Num), Now - random:uniform(?DAYS_MS), android
        ) || Num <- lists:seq(1,3)
    ]),
    Days7 = Days1 + length([mod_engaged_users:update_last_activity(
        integer_to_binary(?UID + Num), Now - ?WEEKS_MS + random:uniform(6 * ?DAYS_MS), ios
    ) || Num <- lists:seq(4,6)
    ]),
    Days28 = Days7 + length([mod_engaged_users:update_last_activity(
        integer_to_binary(?UID + Num), Now - (28 * ?DAYS_MS) + random:uniform(14 * ?DAYS_MS), android
    ) || Num <- lists:seq(7,9)
    ]),
    Days30 = Days28 + length([mod_engaged_users:update_last_activity(
        integer_to_binary(?UID + Num), Now - (30 * ?DAYS_MS) + random:uniform(2 * ?DAYS_MS), ios
    ) || Num <- lists:seq(10,12)
    ]),
    Day1Count = [mod_engaged_users:count_engaged_users_1day(Type) || Type <- [all, android, ios]],
    ?assertEqual([Days1, Days1, 0], Day1Count),
    Day7Count = [mod_engaged_users:count_engaged_users_7day(Type) || Type <- [all, android, ios]],
    ?assertEqual([Days7, Days1, Days7 - Days1],  Day7Count),
    Day28Count = [mod_engaged_users:count_engaged_users_28day(Type) || Type <- [all, android, ios]],
    ?assertEqual([Days28, Days28 - Days7 + Days1, Days7 - Days1], Day28Count),
    Day30Count = [mod_engaged_users:count_engaged_users_30day(Type) || Type <- [all, android, ios]],
    ?assertEqual([Days30, Days28 - Days7 + Days1, Days30 - Days28 + Days7 - Days1], Day30Count),
    Day30Count = [model_active_users:count_engaged_users_between(Type, 0, inf) || Type <- [all, android, ios]],
    ?assertEqual([12, 6, 6], Day30Count).


cleanup_engaged_users_test() ->
    setup(),
    Now = util:now_ms(),
    EngagedUsers = length([mod_engaged_users:update_last_activity(
        integer_to_binary(?UID + Num), Now - random:uniform(30 * ?DAYS_MS), android
    ) || Num <- lists:seq(1, 6)
    ]),
    UnEngagedUsers = length([mod_engaged_users:update_last_activity(
        integer_to_binary(?UID + Num), Now - (30 * ?DAYS_MS) - random:uniform(?WEEKS_MS), ios
    ) || Num <- lists:seq(7, 12)
    ]),
    Before = [model_active_users:count_engaged_users_between(Type, 0, inf) || Type <- [all, android, ios]],
    ?assertEqual([EngagedUsers + UnEngagedUsers, EngagedUsers, UnEngagedUsers], Before),
    ok = model_active_users:cleanup(),
    After = [model_active_users:count_engaged_users_between(Type, 0, inf) || Type <- [all, android, ios]],
    ?assertEqual([EngagedUsers, EngagedUsers, 0], After).

%% -------------------------------------------- %%
%% Internal functions
%% -------------------------------------------- %%

setup() ->
    tutil:setup(),
    mod_redis:start(undefined, []),
    clear(),
    ok = create_accounts(12),
    ok.


clear() ->
    tutil:cleardb(redis_accounts).


create_accounts(0) ->
    ok;

create_accounts(Num) ->
    Uid = integer_to_binary(?UID + Num),
    Phone = integer_to_binary(?PHONE + Num),
    case Num rem 2 of
        0 -> ok = model_accounts:create_account(Uid, Phone, ?NAME, ?UA_IOS);
        1 -> ok = model_accounts:create_account(Uid, Phone, ?NAME, ?UA_ANDROID)
    end,
    create_accounts(Num - 1).

