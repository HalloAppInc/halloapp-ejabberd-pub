%%%-------------------------------------------------------------------
%%% @author josh
%%% @copyright (C) 2020, HalloApp, Inc.
%%% @doc
%%%
%%% @end
%%% Created : 24. Aug 2020 7:11 PM
%%%-------------------------------------------------------------------
-module(mod_halloapp_http_api_tests).
-author("josh").

-include("account.hrl").
-include("util_http.hrl").
-include("ejabberd_http.hrl").
-include("whisper.hrl").
-include("sms.hrl").
-include("groups.hrl").
-include_lib("eunit/include/eunit.hrl").

-define(UID, <<"1000000000332736727">>).
-define(TEST_PHONE, <<"16175550000">>).
-define(VOIP_PHONE, <<"3544921234">>).
-define(NAME, <<"Josh">>).
-define(UA, <<"HalloApp/iOS1.28.151">>).
-define(ANDROID_UA, <<"HalloApp/Android1.4">>).
-define(BAD_UA, <<"BadUserAgent/1.0">>).
-define(IP1, "1.1.1.1").
-define(SMS_CODE, <<"111111">>).
-define(BAD_SMS_CODE, <<"111110">>).
-define(REQUEST_GET_GROUP_INFO_PATH, [<<"registration">>, <<"get_group_info">>]).
-define(REQUEST_HEADERS(UA), [
    {'Content-Type',<<"application/json">>},
    {'User-Agent',UA}]).

-define(IP, {{0,0,0,0,0,65535,32512,1}, 5580}).
-define(CC1, <<"IN">>).
-define(BAD_HASHCASH_SOLUTION, <<"BadSolution">>).
-define(HASHCASH_TIME_TAKEN_MS, 100).
-define(STATIC_KEY, <<"static_key">>).

%%%----------------------------------------------------------------------
%%% Internal function tests
%%%----------------------------------------------------------------------

check_ua_test() ->
    setup(),
    ?assertEqual(ok, mod_halloapp_http_api:check_ua(?UA)),
    ?assertEqual(ok, mod_halloapp_http_api:check_ua(<<"HalloApp/Android1.0">>)),
    ?assertError(bad_user_agent, mod_halloapp_http_api:check_ua(?BAD_UA)).


check_name_test() ->
    setup(),
    ?assertError(invalid_name, mod_halloapp_http_api:check_name(<<"">>)),
    ?assertEqual(?NAME, mod_halloapp_http_api:check_name(?NAME)),
    TooLongName = list_to_binary(["a" || _ <- lists:seq(1, ?MAX_NAME_SIZE + 5)]),
    ?assertEqual(?MAX_NAME_SIZE, byte_size(mod_halloapp_http_api:check_name(TooLongName))),
    ?assertError(invalid_name, mod_halloapp_http_api:check_name(not_a_name)).


request_and_check_sms_code_test() ->
    setup(),
    tutil:meck_init(ejabberd_router, is_my_host, fun(_) -> true end),
    tutil:meck_init(twilio_verify, send_feedback, fun(_,_) -> ok end),
    ?assertError(wrong_sms_code, mod_halloapp_http_api:check_sms_code(?TEST_PHONE, ?IP1, noise, ?SMS_CODE, ?STATIC_KEY)),
    {ok, _, _} = mod_sms:request_sms(?TEST_PHONE, ?UA),
    ?assertError(wrong_sms_code, mod_halloapp_http_api:check_sms_code(?TEST_PHONE, ?IP1, noise, ?BAD_SMS_CODE, ?STATIC_KEY)),
    ?assertEqual(ok, mod_halloapp_http_api:check_sms_code(?TEST_PHONE, ?IP1, noise, ?SMS_CODE, ?STATIC_KEY)),
    tutil:meck_finish(twilio_verify),
    tutil:meck_finish(ejabberd_router).


check_empty_inviter_list_test() ->
    setup(),
    ?assertEqual({ok, 30, false}, mod_sms:send_otp_to_inviter(?TEST_PHONE, undefined, undefined, undefined)),
    % making sure something got stored in the db
    {ok, [_PhoneVerification]} = model_phone:get_all_verification_info(?TEST_PHONE),
    ok.


get_group_info_test() ->
    {timeout, 10,
        fun() ->
            get_group_info()
        end}.

get_group_info() ->
    setup(),
    GroupName = <<"GroupName1">>,
    Avatar = <<"avatar1">>,
    {ok, Group} = mod_groups:create_group(?UID, GroupName),
    Gid = Group#group.gid,
    mod_groups:set_avatar(Gid, ?UID, Avatar),
    ?assertEqual(true, model_groups:is_admin(Gid, ?UID)),
    {ok, Link} = mod_groups:get_invite_link(Gid, ?UID),
    Data = jiffy:encode(#{group_invite_token => Link}),
    {200, _, ResultJson} = mod_halloapp_http_api:process(?REQUEST_GET_GROUP_INFO_PATH,
        #request{method = 'POST', data = Data, ip = ?IP, headers = ?REQUEST_HEADERS(?UA)}),
    Result = jiffy:decode(ResultJson, [return_maps]),
    ExpectedResult = #{<<"result">> => <<"ok">>, <<"name">> => GroupName, <<"avatar">> => Avatar},
    ?assertEqual(ExpectedResult, Result),

    BadData = jiffy:encode(#{group_invite_token => <<"foobar">>}),
    ?assertEqual(
        util_http:return_400(invalid_invite),
        mod_halloapp_http_api:process(?REQUEST_GET_GROUP_INFO_PATH,
            #request{method = 'POST', data = BadData, ip = ?IP, headers = ?REQUEST_HEADERS(?UA)})),

    ok.

hashcash_test() ->
    Challenge = mod_halloapp_http_api:create_hashcash_challenge(?CC1, ?IP1),
    BadSolution = <<Challenge/binary, ":", ?BAD_HASHCASH_SOLUTION/binary>>,
    %% The following line is not certain to succeed all the time.
    {error, wrong_hashcash_solution} = mod_halloapp_http_api:check_hashcash_solution(
        BadSolution, ?HASHCASH_TIME_TAKEN_MS),
    {error, invalid_hashcash_nonce} = mod_halloapp_http_api:check_hashcash_solution(
        BadSolution, ?HASHCASH_TIME_TAKEN_MS),
    Challenge2 = mod_halloapp_http_api:create_hashcash_challenge(?CC1, ?IP1),
    _StartTime = util:now_ms(),
    GoodSolution = util_hashcash:solve_challenge(Challenge2),
    _EndTime = util:now_ms(),
    %% ?debugFmt("Created hashcash challenge: ~p, Solution: ~p, took: ~pms",
    %%    [Challenge2, GoodSolution, EndTime - StartTime]),
    ok = mod_halloapp_http_api:check_hashcash_solution(GoodSolution, ?HASHCASH_TIME_TAKEN_MS),
    {error, invalid_hashcash_nonce} = mod_halloapp_http_api:check_hashcash_solution(
        GoodSolution, ?HASHCASH_TIME_TAKEN_MS).



%%%----------------------------------------------------------------------
%%% Internal functions
%%%----------------------------------------------------------------------
setup() ->
    tutil:setup(),
    {ok, _} = application:ensure_all_started(stringprep),
    ha_redis:start(),
    mod_libphonenumber:start(<<>>, <<>>),
    clear(),
    ok.


clear() ->
    tutil:cleardb(redis_accounts),
    tutil:cleardb(redis_whisper),
    tutil:cleardb(redis_auth),
    ok.

