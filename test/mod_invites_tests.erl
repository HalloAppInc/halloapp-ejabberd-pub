%%%-------------------------------------------------------------------
%%% File: mod_invites_tests.erl
%%% Copyright (C) 2020, Halloapp Inc.
%%%
%%%-------------------------------------------------------------------
-module(mod_invites_tests).
-author("josh").

-include("invites.hrl").
-include("packets.hrl").
-include("tutil.hrl").

-define(UID1, <<"1">>).
-define(PHONE1, <<"16505551111">>).
-define(NAME1, <<"Name1">>).
-define(USER_AGENT1, <<"HalloApp/Android1.0">>).
-define(LANG_ID1, <<"en-US">>).

-define(UID2, <<"10">>).
-define(PHONE2, <<"16175287001">>).
-define(NAME2, <<"Name2">>).
-define(USER_AGENT2, <<"HalloApp/Android1.0">>).
-define(LANG_ID2A, <<"en-US">>).
-define(LANG_ID2B, <<"en-GB">>).

-define(UID3, <<"3">>).
-define(PHONE3, <<"16175287002">>).
-define(NAME3, <<"Name3">>).
-define(USER_AGENT3, <<"HalloApp/Android1.0">>).
-define(LANG_ID3, <<"en-US">>).

-define(UID4, <<"5">>).
-define(PHONE4, <<"16175287003">>).
-define(LANG_ID4, <<"en-US">>).

-define(TEST_PHONE1, <<"16175550000">>).

%% -------------------------------------------- %%
%% Tests for IQ API
%% --------------------------------------------	%%

get_invites_testparallel(_) ->
    Result = mod_invites:process_local_iq(create_get_iq(?UID1)),
    ExpNumInvites = ?INF_INVITES,
    check_invites_iq_correctness(Result, ExpNumInvites). % generates list of tests

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
send_invites_error3_testparallel(_) ->
    ok = model_accounts:create_account(?UID2, ?PHONE2, ?NAME2, ?USER_AGENT2),
    ok = model_phone:add_phone(?PHONE2, ?HALLOAPP, ?UID2),
    Actual = mod_invites:process_local_iq(create_invite_iq(?UID1)),
    Expected = [
        #pb_invite{phone = ?PHONE2, result = <<"failed">>, reason = <<"existing_user">>},
        #pb_invite{phone = <<"16175283002">>, result = <<"ok">>},
        #pb_invite{phone = <<"16175283003">>, result = <<"ok">>},
        #pb_invite{phone = <<"212">>, result = <<"failed">>, reason = <<"invalid_number">>}
    ],
    [?_assertEqual(Expected, get_invite_subel_list(Actual)),
    check_invites_iq_correctness(Actual, ?INF_INVITES)].

% tests invalid_phone error
send_invites_error4_testparallel(_) ->
    Result = mod_invites:process_local_iq(create_invite_iq(?UID1)),
    ExpNumInvites = ?INF_INVITES,
    Expected = [
        #pb_invite{phone = ?PHONE2, result = <<"ok">>},
        #pb_invite{phone = <<"16175283002">>, result = <<"ok">>},
        #pb_invite{phone = <<"16175283003">>, result = <<"ok">>},
        #pb_invite{phone = <<"212">>, result = <<"failed">>, reason = <<"invalid_number">>}
    ],
    [?_assertEqual(Expected, get_invite_subel_list(Result)),
    check_invites_iq_correctness(Result, ExpNumInvites)].


register_user_hook_testparallel(_) ->
    InvsRem1 = mod_invites:get_invites_remaining(?UID1),
    mod_invites:request_invite(?UID1, ?PHONE2),
    InvsRem2 = mod_invites:get_invites_remaining(?UID1),
    InvsRem3 = mod_invites:get_invites_remaining2(?UID1),
    mod_invites:request_invite(?UID1, ?PHONE3),
    InvsRem4 = mod_invites:get_invites_remaining(?UID1),
    InvsRem5 = mod_invites:get_invites_remaining2(?UID1),
    ok = mod_invites:register_user(?UID2, <<>>, ?PHONE2, <<"undefined">>),
    InvsRem6 = mod_invites:get_invites_remaining(?UID1),
    InvsRem7 = mod_invites:get_invites_remaining2(?UID1),
    ok = mod_invites:register_user(?UID3, <<>>, ?PHONE3, <<"undefined">>),
    InvsRem8 = mod_invites:get_invites_remaining(?UID1),
    InvsRem9 = mod_invites:get_invites_remaining2(?UID1),
    %% ! Note that we store the results we're interested in in variables and then assert on those
    %%   These assertions are run later, so we can't guarantee timing for them
    [?_assertEqual(?MAX_NUM_INVITES, InvsRem1), 
        ?_assertEqual(?MAX_NUM_INVITES, InvsRem2), ?_assertEqual(?INF_INVITES, InvsRem3), 
        ?_assertEqual(?MAX_NUM_INVITES, InvsRem4), ?_assertEqual(?INF_INVITES, InvsRem5),
        ?_assertEqual(?MAX_NUM_INVITES, InvsRem6), ?_assertEqual(?INF_INVITES, InvsRem7),
        ?_assertEqual(?MAX_NUM_INVITES, InvsRem8), ?_assertEqual(?INF_INVITES, InvsRem9)].

get_invites_error(_) ->
    Actual = mod_invites:process_local_iq(create_get_iq(?UID1)),
    Expected = #pb_iq{type = error, to_uid = ?UID1, payload =
        #pb_error_stanza{reason = <<"no_account">>}
    },
    [?_assertEqual(Expected, Actual)].

% tests no_account error
send_invites_error1(_) ->
    Actual = mod_invites:process_local_iq(create_invite_iq(?UID1)),
    Expected = #pb_iq{type = error, to_uid = ?UID1, payload =
        #pb_error_stanza{reason = <<"no_account">>}
    },
    [?_assertEqual(Expected, Actual)].

iq_test_() ->
    tutil:setup_foreach(fun setup_redis_only/0, [
          fun get_invites_error/1,
          fun send_invites_error1/1  
    ]).

%% -------------------------------------------- %%
%% Tests for API functions
%% --------------------------------------------	%%

% tests setting the invite limit for the first time (i.e., a user that has not yet sent an invite)
reset_invs_for_first_time_testset(_) ->
    [?_assertEqual(?MAX_NUM_INVITES, mod_invites:get_invites_remaining(?UID1))].

% tests that sending one invite will decrease the invites sent for that week by 1
get_invites_remaining1_testset(_) ->
    InvsRemStart = mod_invites:get_invites_remaining(?UID1),
    InvsRem2Start = mod_invites:get_invites_remaining2(?UID1),
    InvReq = mod_invites:request_invite(?UID1, ?PHONE2),
    InvsRemEnd = mod_invites:get_invites_remaining(?UID1),
    InvsRem2End = mod_invites:get_invites_remaining2(?UID1),
    [?_assertEqual(?MAX_NUM_INVITES, InvsRemStart),
    ?_assertEqual(?INF_INVITES, InvsRem2Start),
    ?_assertEqual({?PHONE2, ok, undefined}, InvReq),
    ?_assertEqual(?MAX_NUM_INVITES, InvsRemEnd),
    ?_assertEqual(?INF_INVITES, InvsRem2End)].

%% ! Note that the following two tests don't use fixtures, as they don't require setup/teardown
% tests get_time_until_refresh function on a randomly chosen timestamp
time_until_refresh1_test() ->
    ?assertEqual(271422, mod_invites:get_time_until_refresh(1594240578)).

% tests get_time_until_refresh function's edge case where the refresh time just passed
time_until_refresh2_test() ->
    ?assertEqual(604800, mod_invites:get_time_until_refresh(1593907200)).

% tests the existing_user error of the request_invite function
request_invite_error1_testset(_) ->
    ok = model_accounts:create_account(?UID2, ?PHONE2, ?NAME2, ?USER_AGENT2),
    ok = model_phone:add_phone(?PHONE2, ?HALLOAPP, ?UID2),
    InvReq = mod_invites:request_invite(?UID1, ?PHONE2),
    InvRem = mod_invites:get_invites_remaining(?UID1),
    [?_assertEqual({?PHONE2, failed, existing_user}, InvReq),
    ?_assertEqual(?MAX_NUM_INVITES, InvRem)].

% tests the no_invites_left error of the request_invite function
request_invite_error2_testset(_) ->
    [mod_invites:request_invite(?UID1, integer_to_binary(Phone)) ||
        Phone <- lists:seq(16175289000, 16175289000 + ?MAX_NUM_INVITES)],
    InvReq = mod_invites:request_invite(?UID1, ?PHONE2),
    InvRemStart = mod_invites:get_invites_remaining(?UID1),
    InvRem2Start = mod_invites:get_invites_remaining2(?UID1),
    InvReq2 = mod_invites:request_invite(?UID1, <<"16175289000">>),
    InvRemEnd = mod_invites:get_invites_remaining(?UID1),
    InvRem2End = mod_invites:get_invites_remaining2(?UID1),
    [?_assertEqual({?PHONE2, ok, undefined}, InvReq),
    ?_assertEqual(?MAX_NUM_INVITES, InvRemStart),
    ?_assertEqual(?INF_INVITES, InvRem2Start),
    ?_assertEqual({<<"16175289000">>, ok, undefined}, InvReq2),
    ?_assertEqual(?MAX_NUM_INVITES, InvRemEnd),
    ?_assertEqual(?INF_INVITES, InvRem2End)].

% tests that a duplicate invite will not decrease invite limit
request_invite_error3_testset(_) ->
    InvRemStart = mod_invites:get_invites_remaining(?UID1),
    InvRem2Start = mod_invites:get_invites_remaining2(?UID1),
    InvReq = mod_invites:request_invite(?UID1, ?PHONE2),
    InvRemMid = mod_invites:get_invites_remaining(?UID1),
    InvRem2Mid = mod_invites:get_invites_remaining2(?UID1),
    InvReq2 = mod_invites:request_invite(?UID1, ?PHONE2),
    InvRemEnd = mod_invites:get_invites_remaining(?UID1),
    InvRem2End = mod_invites:get_invites_remaining2(?UID1),
    [?_assertEqual(?MAX_NUM_INVITES, InvRemStart),
    ?_assertEqual(?INF_INVITES, InvRem2Start),
    ?_assertEqual({?PHONE2, ok, undefined}, InvReq),
    ?_assertEqual(?MAX_NUM_INVITES, InvRemMid),
    ?_assertEqual(?INF_INVITES, InvRem2Mid),
    ?_assertEqual({?PHONE2, ok, undefined}, InvReq2),
    ?_assertEqual(?MAX_NUM_INVITES, InvRemEnd),
    ?_assertEqual(?INF_INVITES, InvRem2End)].


get_inviters_list_testset(_) ->
    #{} = model_invites:get_inviters_list([]),
    ok = model_invites:record_invite(?UID1, ?PHONE2, 1),
    ok = model_invites:record_invite(?UID1, ?PHONE3, 1),
    ok = model_invites:record_invite(?UID2, ?PHONE3, 1),
    ResMap = model_invites:get_inviters_list([?PHONE2, ?PHONE3]),
    ResMap = model_invites:get_inviters_list([?PHONE1, ?PHONE2, ?PHONE3]),

    Phone2Result = maps:get(?PHONE2, ResMap),
    Phone2Uids = [Uid || {Uid, _Ts2} <- Phone2Result],

    Phone3Result = maps:get(?PHONE3, ResMap),
    Phone3Uids = [Uid || {Uid, _Ts2} <- Phone3Result],
    [?_assertEqual(sets:from_list(Phone2Uids), sets:from_list([?UID1])),
    ?_assertEqual(sets:from_list(Phone3Uids), sets:from_list([?UID1, ?UID2]))].


% tests that a test number in production will not decrease invite limit
request_invite_error4(_) ->
    InvRemStart = mod_invites:get_invites_remaining(?UID1),
    InvReq = mod_invites:request_invite(?UID1, ?TEST_PHONE1),
    InvRemEnd = mod_invites:get_invites_remaining(?UID1),
    [?_assertEqual(?MAX_NUM_INVITES, InvRemStart),
    ?_assertEqual({?TEST_PHONE1, ok, undefined}, InvReq),
    ?_assertEqual(?MAX_NUM_INVITES, InvRemEnd)].


api_test_() ->
    tutil:setup_once(fun setup_with_meck/0, fun request_invite_error4/1).

%% -------------------------------------------- %%
%% Tests for invite strings
%% --------------------------------------------	%%

get_invite_strings(_) ->
    InviteStringMap = mod_invites:get_invite_strings(?UID1),
    [?_assertNotEqual(#{}, InviteStringMap),
    ?_assertNotEqual(undefined, maps:get(<<"en">>, InviteStringMap, undefined)),
    ?_assertNotEqual(undefined, maps:get(<<"id">>, InviteStringMap, undefined))].

get_pre_invite_strings(_) ->
    PreInviteStringMap = mod_invites:get_invite_strings(?UID1),
    [?_assertNotEqual(#{}, PreInviteStringMap),
    ?_assertNotEqual(undefined, maps:get(<<"en">>, PreInviteStringMap, undefined)),
    ?_assertNotEqual(undefined, maps:get(<<"id">>, PreInviteStringMap, undefined))].

invite_string_id(_) ->
    InviteStringMap = mod_invites:get_invite_strings(?UID1),
    InvStr = maps:get(<<"en">>, InviteStringMap, undefined),
    [?_assertNotEqual(undefined, InvStr),
    ?_assertEqual(InvStr,
        mod_invites:lookup_invite_string(mod_invites:get_invite_string_id(InvStr)))].

rm_invite_string_test(_) ->
    %% The string being removed here depends on a uid s.t. uid mod len(all_en_strings) == 5,
    %% because 5 is the 0-index of the first string removed by cc.
    %% UID2 and UID4 match this criteria; UID2 has CC = GB, UID4 has CC = US
    %% So, UID2 and UID4 should get same string, but UID4 lives in the US where this string was removed
    %% Thus, UID4 should get binary(int(UID2) + 1)'s string instead
    EnLang = <<"en">>,
    Uid2String = maps:get(EnLang, mod_invites:get_invite_strings(?UID2), undefined),
    Uid2Plus1 = util:to_binary(util:to_integer(?UID2) + 1),
    ok = model_accounts:create_account(Uid2Plus1, ?PHONE2, ?NAME2, ?USER_AGENT2),
    ok = model_accounts:set_push_token(Uid2Plus1, <<>>, <<>>, 0, ?LANG_ID2A),
    Uid2Plus1String = maps:get(EnLang, mod_invites:get_invite_strings(Uid2Plus1), undefined),
    Uid4String = maps:get(EnLang, mod_invites:get_invite_strings(?UID4), undefined),
    [
        ?_assertNotEqual(?UID2, Uid2Plus1),
        ?_assertNotEqual(Uid2String, Uid2Plus1String),
        ?_assertNotEqual(Uid2String, Uid4String),
        ?_assertEqual(Uid4String, Uid2Plus1String)
    ].

invite_strings_test_() ->
    tutil:setup_once(fun setup_invite_strings/0, [
        fun get_invite_strings/1,
        fun get_pre_invite_strings/1,
        fun invite_string_id/1,
        fun rm_invite_string_test/1
    ]).

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
    CleanupInfo = tutil:setup([
        {redis, [redis_accounts, redis_phone]}
    ]),
    phone_number_util:init(undefined, undefined),
    ok = model_accounts:create_account(?UID1, ?PHONE1, ?NAME1, ?USER_AGENT1),
    CleanupInfo.

setup_with_meck() ->
    CleanupInfo1 = setup(),
    CleanupInfo2 = tutil:setup([
        {meck, ejabberd_router, is_my_host, fun(_) -> true end},
        {meck, config, is_prod_env, fun() -> true end}
    ]),
    tutil:combine_cleanup_info([CleanupInfo1, CleanupInfo2]).

setup_redis_only() ->
    tutil:setup([
        {redis, [redis_accounts, redis_phone]}
    ]).

setup_invite_strings() ->
    CleanupInfo = tutil:setup([{redis, redis_accounts}]),
    %% Setup accounts so that each UID has an associated LangId
    ok = model_accounts:create_account(?UID1, ?PHONE1, ?NAME1, ?USER_AGENT1),
    ok = model_accounts:set_push_token(?UID1, <<>>, <<>>, 0, ?LANG_ID1),
    ok = model_accounts:create_account(?UID2, ?PHONE2, ?NAME2, ?USER_AGENT2),
    ok = model_accounts:set_push_token(?UID2, <<>>, <<>>, 0, ?LANG_ID2A),
    ok = model_accounts:create_account(?UID3, ?PHONE3, ?NAME3, ?USER_AGENT3),
    ok = model_accounts:set_push_token(?UID3, <<>>, <<>>, 0, ?LANG_ID3),
    ok = model_accounts:create_account(?UID4, ?PHONE4, ?NAME1, ?USER_AGENT1),
    ok = model_accounts:set_push_token(?UID4, <<>>, <<>>, 0, ?LANG_ID4),
    mod_invites:init_pre_invite_string_table(),
    mod_invites:init_invite_string_table(),
    CleanupInfo.

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

%%% creates an iq with (MAX_NUM_INVITES + 1) phone numbers
%%create_big_invite_iq(Uid) ->
%%    #pb_iq{
%%        from_uid = Uid,
%%        type = set,
%%        payload = #pb_invites_request{invites = [
%%            #pb_invite{phone = integer_to_binary(Ph)} || Ph <- lists:seq(16175289000,16175289000 + ?MAX_NUM_INVITES)
%%        ]}
%%    }.

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
    [?_assertEqual(ExpectedInvsLeft, InvLeft),
    ?_assertEqual(ok, check_refresh_time_tolerance(TimeLeft))].

