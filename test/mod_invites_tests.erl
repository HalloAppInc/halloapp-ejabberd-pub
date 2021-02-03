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

%% -------------------------------------------- %%
%% Tests for IQ API
%% --------------------------------------------	%%

get_invites_test() ->
    setup(),
    Result = mod_invites:process_local_iq(create_get_iq(?UID1)),
    ?assertEqual(ok, check_invites_iq_correctness(Result, ?MAX_NUM_INVITES)).

get_invites_error_test() ->
    setup_bare(),
    Actual = mod_invites:process_local_iq(create_get_iq(?UID1)),
    Expected = #iq{type = error, to = #jid{luser = ?UID1}, sub_els = [
        #error_st{type = cancel, reason = no_account, bad_req = 'bad-request'}
    ]},
    ?assertEqual(Expected, Actual).

% tests no_account error
send_invites_error1_test() ->
    setup_bare(),
    Actual = mod_invites:process_local_iq(create_invite_iq(?UID1)),
    Expected = #iq{type = error, to = #jid{luser = ?UID1}, sub_els = [
        #error_st{type = cancel, reason = no_account, bad_req = 'bad-request'}
    ]},
    ?assertEqual(Expected, Actual).

% tests no_invites_left error
send_invites_error2_test() ->
    setup(),
    Result = mod_invites:process_local_iq(create_big_invite_iq(?UID1)),
    ?assertEqual(ok, check_invites_iq_correctness(Result, 0)),
    Oks = [#pb_invite{phone = integer_to_binary(Ph), result = <<"ok">>} ||
        Ph <- lists:seq(16175289000,16175289000 + ?MAX_NUM_INVITES - 1)],
    Expected = lists:append(Oks,
        [#pb_invite{
            phone = integer_to_binary(16175289000 + ?MAX_NUM_INVITES),
            result = <<"failed">>, reason = <<"no_invites_left">>
        }]),
    ?assertEqual(Expected, get_invite_subel_list(Result)).

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
    ?assertEqual(ok, check_invites_iq_correctness(Actual, ?MAX_NUM_INVITES - 2)).

% tests invalid_phone error
send_invites_error4_test() ->
    setup(),
    Result = mod_invites:process_local_iq(create_invite_iq(?UID1)),
    ?assertEqual(ok, check_invites_iq_correctness(Result, ?MAX_NUM_INVITES - 3)),
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
    ?assertEqual(?MAX_NUM_INVITES - 1, mod_invites:get_invites_remaining(?UID1)),
    mod_invites:request_invite(?UID1, ?PHONE3),
    ?assertEqual(?MAX_NUM_INVITES - 2, mod_invites:get_invites_remaining(?UID1)),
    ok = mod_invites:register_user(?UID2, <<>>, ?PHONE2),
    ?assertEqual(?MAX_NUM_INVITES - 1, mod_invites:get_invites_remaining(?UID1)),
    ok = mod_invites:register_user(?UID3, <<>>, ?PHONE3),
    ?assertEqual(?MAX_NUM_INVITES, mod_invites:get_invites_remaining(?UID1)),
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
    ?assertEqual({?PHONE2, ok, undefined}, mod_invites:request_invite(?UID1, ?PHONE2)),
    ?assertEqual(?MAX_NUM_INVITES - 1, mod_invites:get_invites_remaining(?UID1)).

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
    ?assertEqual({?PHONE2, failed, no_invites_left}, mod_invites:request_invite(?UID1, ?PHONE2)),
    ?assertEqual(0, mod_invites:get_invites_remaining(?UID1)),
    ?assertEqual({<<"16175289000">>, ok, undefined}, mod_invites:request_invite(?UID1, <<"16175289000">>)),
    ?assertEqual(0, mod_invites:get_invites_remaining(?UID1)).

% tests that a duplicate invite will not decrease invite limit
request_invite_error3_test() ->
    setup(),
    ?assertEqual(?MAX_NUM_INVITES, mod_invites:get_invites_remaining(?UID1)),
    ?assertEqual({?PHONE2, ok, undefined}, mod_invites:request_invite(?UID1, ?PHONE2)),
    ?assertEqual(?MAX_NUM_INVITES - 1, mod_invites:get_invites_remaining(?UID1)),
    ?assertEqual({?PHONE2, ok, undefined}, mod_invites:request_invite(?UID1, ?PHONE2)),
    ?assertEqual(?MAX_NUM_INVITES - 1, mod_invites:get_invites_remaining(?UID1)).

% tests is_invited
is_invited__test() ->
    setup(),
    ?assertNot(model_invites:is_invited(?PHONE2)),
    {?PHONE2, ok, undefined} = mod_invites:request_invite(?UID1, ?PHONE2),
    ?assert(model_invites:is_invited(?PHONE2)).

% tests record_invited_by using old method
record_invited_by_old_test() ->
    setup(),
    ?assertNot(model_invites:is_invited(?PHONE2)),
    {ok, undefined} = model_invites:get_inviter(?PHONE2),
    {ok, []} = model_invites:get_inviters_list(?PHONE2),
    ok = model_invites:record_invited_by_old(?UID1, ?PHONE2),
    ?assert(model_invites:is_invited(?PHONE2)),
    {ok, ?UID1, _} = model_invites:get_inviter(?PHONE2),
    {ok, [{?UID1, _}]} = model_invites:get_inviters_list(?PHONE2),
    ok = model_invites:record_invited_by_old(?UID3, ?PHONE2),
    {ok, ?UID3, _} = model_invites:get_inviter(?PHONE2),
    {ok, [{?UID3, _}]} = model_invites:get_inviters_list(?PHONE2),
    ok = model_invites:record_invited_by(?UID3, ?PHONE2),
    {ok, ?UID3, _} = model_invites:get_inviter(?PHONE2),
    {ok, [{?UID3, _}]} = model_invites:get_inviters_list(?PHONE2),
    ok = model_invites:record_invited_by(?UID1, ?PHONE2),
    {ok, Res} = model_invites:get_inviters_list(?PHONE2),
    Res2 = [Uid || {Uid, _Ts} <- Res],
    ?assertEqual(sets:from_list(Res2), sets:from_list([?UID1, ?UID3])).


% tests who_invited
who_invited_test() ->
    setup_bare(),
    ?assertEqual({ok, undefined}, model_invites:get_inviter(?PHONE2)),
    setup(),
    {?PHONE2, ok, undefined} = mod_invites:request_invite(?UID1, ?PHONE2),
    {ok, Uid1, _Ts} = model_invites:get_inviter(?PHONE2),
    ?assertEqual(Uid1, ?UID1),
    {ok, Res} = model_invites:get_inviters_list(?PHONE2),
    Res2 = [Uid || {Uid, _Ts1} <- Res], 
    ?assertEqual(sets:from_list(Res2), sets:from_list([?UID1])),
    ok = model_accounts:create_account(?UID3, ?PHONE3, ?NAME3, ?USER_AGENT3),
    ok = model_phone:add_phone(?PHONE3, ?UID3),
    {?PHONE2, ok, undefined} = mod_invites:request_invite(?UID3, ?PHONE2),
    {ok, Uid3, _Ts} = model_invites:get_inviter(?PHONE2),
    ?assert(Uid3 =:= ?UID3 orelse Uid3 =:= ?UID1),
    {ok, Res3} = model_invites:get_inviters_list(?PHONE2),
    Res4 = [Uid || {Uid, _Ts2} <- Res3], 
    ?assertEqual(sets:from_list(Res4), sets:from_list([?UID1, ?UID3])).

% tests notification to inviter
inviter_notification_test() ->
    setup_bare(),
    ?assertEqual({ok, undefined}, model_invites:get_inviter(?PHONE2)),
    setup(),
    ?assertNot(model_invites:record_invite_notification(?PHONE2, ?UID1)),
    {?PHONE2, ok, undefined} = mod_invites:request_invite(?UID1, ?PHONE2),
    ?assert(model_invites:record_invite_notification(?PHONE2, ?UID1)),
    ?assertNot(model_invites:record_invite_notification(?PHONE2, ?UID1)),
    ok = model_accounts:create_account(?UID3, ?PHONE3, ?NAME3, ?USER_AGENT3),
    ok = model_phone:add_phone(?PHONE3, ?UID3),
    ?assertNot(model_invites:record_invite_notification(?PHONE2, ?UID3)).

% tests set of invited users for accuracy
invite_set_test() ->
    setup(),
    ?assertEqual({ok, []}, model_invites:get_sent_invites(?UID1)),
    {?PHONE2, ok, undefined} = mod_invites:request_invite(?UID1, ?PHONE2),
    ?assertEqual({ok, [?PHONE2]}, model_invites:get_sent_invites(?UID1)).

%% --------------------------------------------	%%
%% Tests for internal functions
%% -------------------------------------------- %%

% tests that a + is put in front of phone numbers, if needed
prepend_plus_test() ->
    Number = <<"359 (88) 558 6764">>,
    NumberWithPlus = <<"+359 (88) 558 6764">>,
    ?assertEqual(NumberWithPlus, mod_invites:prepend_plus(Number)),
    ?assertEqual(NumberWithPlus, mod_invites:prepend_plus(NumberWithPlus)).

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
    mod_redis:start(undefined, []),
    phone_number_util:init(undefined, undefined),
    clear(),
    ok = model_accounts:create_account(?UID1, ?PHONE1, ?NAME1, ?USER_AGENT1),
    ok.

setup_bare() ->
    mod_redis:start(undefined, []),
    clear(),
    ok.

clear() ->
    tutil:cleardb(redis_accounts),
    tutil:cleardb(redis_phone).

create_get_iq(Uid) ->
    #iq{
        from = #jid{luser = Uid},
        type = get,
        sub_els = [#pb_invites_request{}]
    }.

create_invite_iq(Uid) ->
    #iq{
        from = #jid{luser = Uid},
        type = set,
        sub_els = [#pb_invites_request{invites = [
            #pb_invite{phone = ?PHONE2},
            #pb_invite{phone = <<"16175283002">>},
            #pb_invite{phone = <<"16175283003">>},
            #pb_invite{phone = <<"212">>}
        ]}]
    }.

% creates an iq with (MAX_NUM_INVITES + 1) phone numbers
create_big_invite_iq(Uid) ->
    #iq{
        from = #jid{luser = Uid},
        type = set,
        sub_els = [#pb_invites_request{invites = [
            #pb_invite{phone = integer_to_binary(Ph)} || Ph <- lists:seq(16175289000,16175289000 + ?MAX_NUM_INVITES)
        ]}]
    }.

get_invites_subel(#iq{} = IQ) ->
    [Res] = IQ#iq.sub_els,
    Res.

get_invite_subel_list(#iq{} = IQ) ->
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

