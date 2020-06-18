%%%-------------------------------------------------------------------
%%% File: mod_invites_tests.erl
%%% Copyright (C) 2020, Halloapp Inc.
%%%
%%%-------------------------------------------------------------------
-module(mod_invites_tests).
-author("josh").

-include("invites.hrl").
-include_lib("eunit/include/eunit.hrl").


-define(UID1, <<"1">>).
-define(PHONE1, <<"16505551111">>).
-define(NAME1, <<"Name1">>).
-define(USER_AGENT1, <<"HalloApp/Android1.0">>).

-define(UID2, <<"2">>).
-define(PHONE2, <<"16175287001">>).
-define(NAME2, <<"Name2">>).
-define(USER_AGENT2, <<"HalloApp/Android1.0">>).

setup() ->
    mod_redis:start(undefined, []),
    clear(),
    ok = model_accounts:create_account(?UID1, ?PHONE1, ?NAME1, ?USER_AGENT1),
    ok.

setup_bare() ->
    mod_redis:start(undefined, []),
    clear(),
    ok.


clear() ->
    ok = gen_server:cast(redis_accounts_client, flushdb),
    ok = gen_server:cast(redis_phone_client, flushdb).


%% -------------------------------------------- %%
%% Tests for public API calls
%% --------------------------------------------	%%

% tests setting the invite limit for the first time (i.e., a user that has not yet sent an invite)
reset_invs_for_first_time_test() ->
    setup(),
    ?assertEqual(?MAX_NUM_INVITES, mod_invites:get_invites_remaining(?UID1)).

% tests that sending one invite will decrease the invites sent for that week by 1
get_invites_remaining1_test() ->
    setup(),
    ?assertEqual(?MAX_NUM_INVITES, mod_invites:get_invites_remaining(?UID1)),
    {ok, NumLeft} = mod_invites:request_invite(?UID1, ?PHONE2),
    ?assertEqual(?MAX_NUM_INVITES - 1, NumLeft),
    ?assertEqual(?MAX_NUM_INVITES - 1, mod_invites:get_invites_remaining(?UID1)).

% tests get_time_until_refresh function on a randomly chosen timestamp
time_until_refresh1_test() ->
    ?assertEqual(271422, mod_invites:get_time_until_refresh(1594240578)).

% tests get_time_until_refresh function's edge case where the refresh time just passed
time_until_refresh2_test() ->
    ?assertEqual(604800, mod_invites:get_time_until_refresh(1593907200)).

% tests the no_account error when the from_uid of request_invite is invalid
request_invite_error1_test() ->
    setup_bare(),
    {Status, Desc} = mod_invites:request_invite(?UID1, ?PHONE1),
    ?assertEqual(error, Status),
    ?assertEqual(no_account, Desc).

% tests the existing_user error of the request_invite function
request_invite_error2_test() ->
    setup(),
    ok = model_accounts:create_account(?UID2, ?PHONE2, ?NAME2, ?USER_AGENT2),
    ok = model_phone:add_phone(?PHONE2, ?UID2),
    ?assertEqual({error, existing_user}, mod_invites:request_invite(?UID1, ?PHONE2)).


% tests the exceeded_invite_limit error of the request_invite function
% also tests whether request_invite is returning the correct number of invites remaining
request_invite_error3_test() ->
    setup(),
    Nums = [?PHONE2 || _ <- lists:seq(1,?MAX_NUM_INVITES + 1)],
    Results = [mod_invites:request_invite(?UID1, X) || X <- Nums],
    Oks = [Msg || {Msg,ActualNum} <- Results, ExpectedNum <- lists:seq(?MAX_NUM_INVITES-1, 0, -1),
        Msg == ok, ActualNum == ExpectedNum ],
    Errs = [Msg || {Msg,Desc} <- Results, Msg == error, Desc == no_invites_left],
    ?assertEqual(?MAX_NUM_INVITES, length(Oks)),
    ?assertEqual(1, length(Errs)).

% tests is_invited
is_invited__test() ->
    setup(),
    ?assertNot(model_invites:is_invited(?PHONE2)),
    {ok, _} = mod_invites:request_invite(?UID1, ?PHONE2),
    ?assert(model_invites:is_invited(?PHONE2)).

% tests who_invited
who_invited_test() ->
    setup_bare(),
    ?assertEqual({ok, undefined}, model_invites:get_inviter(?PHONE2)),
    setup(),
    {ok, _} = mod_invites:request_invite(?UID1, ?PHONE2),
    {ok, Uid, _Ts} = model_invites:get_inviter(?PHONE2),
    ?assertEqual(Uid, ?UID1).

% tests set of invited users for accuracy
invite_set_test() ->
    setup(),
    ?assertEqual({ok, []}, model_invites:q_accounts(["SMEMBERS", model_invites:acc_invites_key(?UID1)])),
    {ok, _} = mod_invites:request_invite(?UID1, ?PHONE2),
    ?assertEqual({ok, [?PHONE2]}, model_invites:q_accounts(["SMEMBERS", model_invites:acc_invites_key(?UID1)])).


%% --------------------------------------------	%%
%% Tests for internal functions
%% -------------------------------------------- %%

% tests the ability to get the next sunday at midnight for a randomly chosen time
next_sunday1_test() ->
    TestTime = 1585045819,
    Expected = 1585440000,
    ?assertEqual(Expected, mod_invites:get_next_sunday_midnight(TestTime)).

% tests the ability to get the next sunday when it is already sunday at midnight
next_sunday2_test() ->
    TestTime = 1593907200,
    Expected = 1594512000,
    ?assertEqual(Expected, mod_invites:get_next_sunday_midnight(TestTime)).

% tests the ability to get the previous sunday at midnight for a randomly chosen time
prev_sunday1_test() ->
    TestTime = 1585045819,
    Expected = 1584835200,
    ?assertEqual(Expected, mod_invites:get_last_sunday_midnight(TestTime)).

% tests the ability to get the previous sunday when it is already sunday at midnight
prev_sunday2_test() ->
    TestTime = 1593907200,
    Expected = 1593907200,
    ?assertEqual(Expected, mod_invites:get_last_sunday_midnight(TestTime)).

