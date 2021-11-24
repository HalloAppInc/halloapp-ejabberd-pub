%%%-------------------------------------------------------------------
%%% File: mod_invites_tests.erl
%%% Copyright (C) 2020, Halloapp Inc.
%%%
%%%-------------------------------------------------------------------
-module(mod_invites_tests).
-author("josh").

-include("invites.hrl").
-include("xmpp.hrl").
-include("packets.hrl").
-include_lib("eunit/include/eunit.hrl").

-define(UID1, <<"1">>).
-define(PHONE1, <<"16505551111">>).
-define(NAME1, <<"Name1">>).
-define(USER_AGENT1, <<"HalloApp/Android1.0">>).

-define(UID2, <<"2">>).
-define(PHONE2, <<"16175287001">>).
-define(NAME2, <<"Name2">>).
-define(USER_AGENT2, <<"HalloApp/Android1.0">>).

-define(UID3, <<"3">>).
-define(PHONE3, <<"16175287002">>).
-define(NAME3, <<"Name3">>).
-define(USER_AGENT3, <<"HalloApp/Android1.0">>).

-define(TEST_PHONE1, <<"16175550000">>).

%% -------------------------------------------- %%
%% Tests for IQ API
%% --------------------------------------------	%%

get_invites_test() ->
    setup(),
    Result = mod_invites:process_local_iq(create_get_iq(?UID1)),
    ExpNumInvites = ?INF_INVITES,
    ?assertEqual(ok, check_invites_iq_correctness(Result, ExpNumInvites)).

get_invites_error_test() ->
    setup_bare(),
    Actual = mod_invites:process_local_iq(create_get_iq(?UID1)),
    Expected = #pb_iq{type = error, to_uid = ?UID1, payload =
        #pb_error_stanza{reason = <<"no_account">>}
    },
    ?assertEqual(Expected, Actual).

% tests no_account error
send_invites_error1_test() ->
    setup_bare(),
    Actual = mod_invites:process_local_iq(create_invite_iq(?UID1)),
    Expected = #pb_iq{type = error, to_uid = ?UID1, payload =
        #pb_error_stanza{reason = <<"no_account">>}
    },
    ?assertEqual(Expected, Actual).

%%% tests no_invites_left error
%%send_invites_error2_test() ->
%%    setup(),
%%    Result = mod_invites:process_local_iq(create_big_invite_iq(?UID1)),
%%    ?assertEqual(ok, check_invites_iq_correctness(Result, 0)),
%%    Oks = [#pb_invite{phone = integer_to_binary(Ph), result = <<"ok">>} ||
%%        Ph <- lists:seq(16175289000,16175289000 + ?MAX_NUM_INVITES - 1)],
%%    Expected = lists:append(Oks,
%%        [#pb_invite{
%%            phone = integer_to_binary(16175289000 + ?MAX_NUM_INVITES),
%%            result = <<"failed">>, reason = <<"no_invites_left">>
%%        }]),
%%    ?assertEqual(Expected, get_invite_subel_list(Result)).

% tests existing_user error
send_invites_error3_test() ->
    setup(),
    ok = model_accounts:create_account(?UID2, ?PHONE2, ?NAME2, ?USER_AGENT2),
    ok = model_phone:add_phone(?PHONE2, ?UID2),
    Actual = mod_invites:process_local_iq(create_invite_iq(?UID1)),
    Expected = [
        #pb_invite{phone = ?PHONE2, result = <<"failed">>, reason = <<"existing_user">>},
        #pb_invite{phone = <<"16175283002">>, result = <<"ok">>},
        #pb_invite{phone = <<"16175283003">>, result = <<"ok">>},
        #pb_invite{phone = <<"212">>, result = <<"failed">>, reason = <<"invalid_number">>}
    ],
    ?assertEqual(Expected, get_invite_subel_list(Actual)),
    ExpNumInvites = ?INF_INVITES,
    ?assertEqual(ok, check_invites_iq_correctness(Actual, ExpNumInvites)).

% tests invalid_phone error
send_invites_error4_test() ->
    setup(),
    Result = mod_invites:process_local_iq(create_invite_iq(?UID1)),
    ExpNumInvites = ?INF_INVITES,
    ?assertEqual(ok, check_invites_iq_correctness(Result, ExpNumInvites)),
    Expected = [
        #pb_invite{phone = ?PHONE2, result = <<"ok">>},
        #pb_invite{phone = <<"16175283002">>, result = <<"ok">>},
        #pb_invite{phone = <<"16175283003">>, result = <<"ok">>},
        #pb_invite{phone = <<"212">>, result = <<"failed">>, reason = <<"invalid_number">>}
    ],
    ?assertEqual(Expected, get_invite_subel_list(Result)).


register_user_hook_test() ->
    setup(),
    ?assertEqual(?MAX_NUM_INVITES, mod_invites:get_invites_remaining(?UID1)),
    mod_invites:request_invite(?UID1, ?PHONE2),
    ?assertEqual(?MAX_NUM_INVITES, mod_invites:get_invites_remaining(?UID1)),
    ?assertEqual(?INF_INVITES, mod_invites:get_invites_remaining2(?UID1)),
    mod_invites:request_invite(?UID1, ?PHONE3),
    ?assertEqual(?MAX_NUM_INVITES, mod_invites:get_invites_remaining(?UID1)),
    ?assertEqual(?INF_INVITES, mod_invites:get_invites_remaining2(?UID1)),
    ok = mod_invites:register_user(?UID2, <<>>, ?PHONE2),
    ?assertEqual(?MAX_NUM_INVITES, mod_invites:get_invites_remaining(?UID1)),
    ?assertEqual(?INF_INVITES, mod_invites:get_invites_remaining2(?UID1)),
    ok = mod_invites:register_user(?UID3, <<>>, ?PHONE3),
    ?assertEqual(?MAX_NUM_INVITES, mod_invites:get_invites_remaining(?UID1)),
    ?assertEqual(?INF_INVITES, mod_invites:get_invites_remaining2(?UID1)),
    ok.

%% -------------------------------------------- %%
%% Tests for API functions
%% --------------------------------------------	%%

% tests setting the invite limit for the first time (i.e., a user that has not yet sent an invite)
reset_invs_for_first_time_test() ->
    setup(),
    ?assertEqual(?MAX_NUM_INVITES, mod_invites:get_invites_remaining(?UID1)).

% tests that sending one invite will decrease the invites sent for that week by 1
get_invites_remaining1_test() ->
    setup(),
    ?assertEqual(?MAX_NUM_INVITES, mod_invites:get_invites_remaining(?UID1)),
    ?assertEqual(?INF_INVITES, mod_invites:get_invites_remaining2(?UID1)),
    ?assertEqual({?PHONE2, ok, undefined}, mod_invites:request_invite(?UID1, ?PHONE2)),
    ?assertEqual(?MAX_NUM_INVITES, mod_invites:get_invites_remaining(?UID1)),
    ?assertEqual(?INF_INVITES, mod_invites:get_invites_remaining2(?UID1)).

% tests get_time_until_refresh function on a randomly chosen timestamp
time_until_refresh1_test() ->
    ?assertEqual(271422, mod_invites:get_time_until_refresh(1594240578)).

% tests get_time_until_refresh function's edge case where the refresh time just passed
time_until_refresh2_test() ->
    ?assertEqual(604800, mod_invites:get_time_until_refresh(1593907200)).

% tests the existing_user error of the request_invite function
request_invite_error1_test() ->
    setup(),
    ok = model_accounts:create_account(?UID2, ?PHONE2, ?NAME2, ?USER_AGENT2),
    ok = model_phone:add_phone(?PHONE2, ?UID2),
    ?assertEqual({?PHONE2, failed, existing_user}, mod_invites:request_invite(?UID1, ?PHONE2)),
    ?assertEqual(?MAX_NUM_INVITES, mod_invites:get_invites_remaining(?UID1)).

% tests the no_invites_left error of the request_invite function
request_invite_error2_test() ->
    setup(),
    [mod_invites:request_invite(?UID1, integer_to_binary(Phone)) ||
        Phone <- lists:seq(16175289000, 16175289000 + ?MAX_NUM_INVITES)],
    ?assertEqual({?PHONE2, ok, undefined}, mod_invites:request_invite(?UID1, ?PHONE2)),
    ?assertEqual(?MAX_NUM_INVITES, mod_invites:get_invites_remaining(?UID1)),
    ?assertEqual(?INF_INVITES, mod_invites:get_invites_remaining2(?UID1)),
    ?assertEqual({<<"16175289000">>, ok, undefined}, mod_invites:request_invite(?UID1, <<"16175289000">>)),
    ?assertEqual(?MAX_NUM_INVITES, mod_invites:get_invites_remaining(?UID1)),
    ?assertEqual(?INF_INVITES, mod_invites:get_invites_remaining2(?UID1)).

% tests that a duplicate invite will not decrease invite limit
request_invite_error3_test() ->
    setup(),
    ?assertEqual(?MAX_NUM_INVITES, mod_invites:get_invites_remaining(?UID1)),
    ?assertEqual(?INF_INVITES, mod_invites:get_invites_remaining2(?UID1)),
    ?assertEqual({?PHONE2, ok, undefined}, mod_invites:request_invite(?UID1, ?PHONE2)),
    ?assertEqual(?MAX_NUM_INVITES, mod_invites:get_invites_remaining(?UID1)),
    ?assertEqual(?INF_INVITES, mod_invites:get_invites_remaining2(?UID1)),
    ?assertEqual({?PHONE2, ok, undefined}, mod_invites:request_invite(?UID1, ?PHONE2)),
    ?assertEqual(?MAX_NUM_INVITES, mod_invites:get_invites_remaining(?UID1)),
    ?assertEqual(?INF_INVITES, mod_invites:get_invites_remaining2(?UID1)).

% tests that a test number in production will not decrease invite limit
request_invite_error4_test() ->
    setup(),
    meck_init(ejabberd_router, is_my_host, fun(_) -> true end),
    meck_init(config, is_prod_env, fun() -> true end),
    ?assertEqual(?MAX_NUM_INVITES, mod_invites:get_invites_remaining(?UID1)),
    ?assertEqual({?TEST_PHONE1, ok, undefined}, mod_invites:request_invite(?UID1, ?TEST_PHONE1)),
    ?assertEqual(?MAX_NUM_INVITES, mod_invites:get_invites_remaining(?UID1)),
    meck_finish(config),
    meck_finish(ejabberd_router).

get_inviters_list_test() ->
    setup(),
    #{} = model_invites:get_inviters_list([]),
    ok = model_invites:record_invite(?UID1, ?PHONE2, 1),
    ok = model_invites:record_invite(?UID1, ?PHONE3, 1),
    ok = model_invites:record_invite(?UID2, ?PHONE3, 1),
    ResMap = model_invites:get_inviters_list([?PHONE2, ?PHONE3]),
    ResMap = model_invites:get_inviters_list([?PHONE1, ?PHONE2, ?PHONE3]),

    Phone2Result = maps:get(?PHONE2, ResMap),
    Phone2Uids = [Uid || {Uid, _Ts2} <- Phone2Result],
    ?assertEqual(sets:from_list(Phone2Uids), sets:from_list([?UID1])),

    Phone3Result = maps:get(?PHONE3, ResMap),
    Phone3Uids = [Uid || {Uid, _Ts2} <- Phone3Result],
    ?assertEqual(sets:from_list(Phone3Uids), sets:from_list([?UID1, ?UID2])),
    ok.

%% --------------------------------------------	%%
%% Tests for internal functions
%% -------------------------------------------- %%

% tests the ability to get the next sunday at midnight for a chosen time
next_sunday1_test() ->
    TestTime = 1585045819,
    Expected = 1585440000,
    ?assertEqual(Expected, mod_invites:get_next_sunday_midnight(TestTime)).

% tests the ability to get the next sunday when it is already sunday at midnight
next_sunday2_test() ->
    TestTime = 1593907200,
    Expected = 1594512000,
    ?assertEqual(Expected, mod_invites:get_next_sunday_midnight(TestTime)).

% tests the ability to get the previous sunday at midnight for a chosen time
prev_sunday1_test() ->
    TestTime = 1585045819,
    Expected = 1584835200,
    ?assertEqual(Expected, mod_invites:get_last_sunday_midnight(TestTime)).

% tests the ability to get the previous sunday when it is already sunday at midnight
prev_sunday2_test() ->
    TestTime = 1593907200,
    Expected = 1593907200,
    ?assertEqual(Expected, mod_invites:get_last_sunday_midnight(TestTime)).

%% --------------------------------------------	%%
%% Internal functions
%% -------------------------------------------- %%

setup() ->
    tutil:setup(),
    ha_redis:start(),
    phone_number_util:init(undefined, undefined),
    clear(),
    ok = model_accounts:create_account(?UID1, ?PHONE1, ?NAME1, ?USER_AGENT1),
    ok.

setup_bare() ->
    ha_redis:start(),
    clear(),
    ok.

meck_init(Mod, FunName, Fun) ->
    meck:new(Mod, [passthrough]),
    meck:expect(Mod, FunName, Fun).

meck_finish(Mod) ->
    ?assert(meck:validate(Mod)),
    meck:unload(Mod).

clear() ->
    tutil:cleardb(redis_accounts),
    tutil:cleardb(redis_phone).

create_get_iq(Uid) ->
    #pb_iq{
        from_uid = Uid,
        type = get,
        payload = #pb_invites_request{}
    }.

create_invite_iq(Uid) ->
    #pb_iq{
        from_uid = Uid,
        type = set,
        payload = #pb_invites_request{invites = [
            #pb_invite{phone = ?PHONE2},
            #pb_invite{phone = <<"16175283002">>},
            #pb_invite{phone = <<"16175283003">>},
            #pb_invite{phone = <<"212">>}
        ]}
    }.

% creates an iq with (MAX_NUM_INVITES + 1) phone numbers
create_big_invite_iq(Uid) ->
    #pb_iq{
        from_uid = Uid,
        type = set,
        payload = #pb_invites_request{invites = [
            #pb_invite{phone = integer_to_binary(Ph)} || Ph <- lists:seq(16175289000,16175289000 + ?MAX_NUM_INVITES)
        ]}
    }.

get_invites_subel(#pb_iq{} = IQ) ->
    IQ#pb_iq.payload.

get_invite_subel_list(#pb_iq{} = IQ) ->
    SubEl = get_invites_subel(IQ),
    case SubEl of
        #pb_invites_request{} -> SubEl#pb_invites_request.invites;
        #pb_invites_response{} -> SubEl#pb_invites_response.invites
    end.

% function to verify the refresh time in the iq result is close enough to assume its correctness
% the refresh time function itself is tested elsewhere
check_refresh_time_tolerance(Time) ->
    Tolerance = 5,
    CurrTime = mod_invites:get_time_until_refresh(),
    if
        (Time >= (CurrTime - Tolerance)) or (Time =< (CurrTime + Tolerance)) ->
            ok;
        true -> {error_bad_refresh_time, Time}
    end.

-spec check_invites_iq_correctness(IQ :: iq(), ExpectedInvsLeft :: integer()) -> ok.
check_invites_iq_correctness(IQ, ExpectedInvsLeft) ->
    #pb_invites_response{invites_left = InvLeft, time_until_refresh = TimeLeft} = get_invites_subel(IQ),
    ?assertEqual(ExpectedInvsLeft, InvLeft),
    ?assertEqual(ok, check_refresh_time_tolerance(TimeLeft)),
    ok.

