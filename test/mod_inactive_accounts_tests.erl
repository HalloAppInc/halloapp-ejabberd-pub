%%%-------------------------------------------------------------------
%%% File: mod_inactive_accounts_tests.erl
%%% Copyright (C) 2021, HalloApp Inc.
%%%
%%%-------------------------------------------------------------------
-module(mod_inactive_accounts_tests).
-author("josh").

-include("mod_inactive_accounts.hrl").
-include("time.hrl").
-include_lib("eunit/include/eunit.hrl").

-define(MOD, mod_inactive_accounts).
-define(UID1, <<"1">>).
-define(PHONE1, <<"16505551111">>).
-define(NAME1, <<"Name1">>).
-define(USER_AGENT1, <<"HalloApp/Android1.0">>).

%% -------------------------------------------- %%
%% Tests
%% -------------------------------------------- %%

is_inactive_user_test() ->
    setup(),
    ?assertNot(mod_inactive_accounts:is_inactive_user(?UID1)),
    ok = model_accounts:set_last_activity(?UID1,
            util:now_ms() - (?NUM_INACTIVITY_DAYS + 1) * ?DAYS_MS,
            away),
    ?assert(mod_inactive_accounts:is_inactive_user(?UID1)).

schedule_test() ->
    % manage sets a timer every hour between 6-11pm UTC mon, tue, wed
    % to run the find_uids, check_uids, and delete_uids
    % tasks, one task per day, respectively
    Mon = {2021, 3, 22},    % Mar 22, 2021 is a Monday
    Tue = {2021, 3, 23},
    Wed = {2021, 3, 24},
    TaskTime1 = {17, 59, 59},    % 6pm
    TaskTime2 = {19, 59, 59},    % 8pm
    TaskTime3 = {21, 59, 59},   % 10pm
    Self = self(),
    Timeout = 500,
    tutil:meck_init(?MOD, [
        {find_uids, fun() -> Self ! ack end},
        {check_uids, fun() -> Self ! ack2 end},
        {delete_uids, fun() -> Self ! ack3 end}
    ]),
    setup_erlcron(),

    mod_inactive_accounts:schedule(),
    erlcron:set_datetime({Mon, TaskTime1}),
    erlcron:set_datetime({Mon, TaskTime2}),
    erlcron:set_datetime({Mon, TaskTime3}),
    ?assertEqual(3, collect(ack, Timeout, 3)),
    erlcron:set_datetime({Tue, TaskTime1}),
    erlcron:set_datetime({Tue, TaskTime2}),
    erlcron:set_datetime({Tue, TaskTime3}),
    ?assertEqual(3, collect(ack2, Timeout, 3)),
    erlcron:set_datetime({Wed, TaskTime1}),
    erlcron:set_datetime({Wed, TaskTime2}),
    erlcron:set_datetime({Wed, TaskTime3}),
    ?assertEqual(3, collect(ack3, Timeout, 3)),
    mod_inactive_accounts:unschedule(),
    tutil:meck_finish(?MOD),
    cleanup_erlcron().

%% -------------------------------------------- %%
%% Internal functions
%% -------------------------------------------- %%

setup_erlcron() ->
    application:start(erlcron),
    ok.

cleanup_erlcron() ->
    %% prevents INFO REPORT generation
    error_logger:tty(false),
    application:stop(erlcron),
    error_logger:tty(true),
    ok.

setup() ->
    tutil:setup(),
    ha_redis:start(),
    clear(),
    ok = model_accounts:create_account(?UID1, ?PHONE1, ?USER_AGENT1),
    ok = model_accounts:set_name(?UID1, ?NAME1),
    ok.

clear() ->
    tutil:cleardb(redis_accounts),
    tutil:cleardb(redis_phone).

collect(Msg, Timeout, Count) ->
    collect(Msg, Timeout, 0, Count).
collect(_Msg, _Timeout, Count, Count) ->
    Count;
collect(Msg, Timeout, I, Count) ->
    receive
        Msg -> collect(Msg, Timeout, I+1, Count)
    after
        Timeout -> I
    end.

