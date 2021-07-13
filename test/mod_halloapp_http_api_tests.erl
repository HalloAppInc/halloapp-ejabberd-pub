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
-define(PHONE, <<"14703381473">>).
-define(TEST_PHONE, <<"16175550000">>).
-define(NAME, <<"Josh">>).
-define(SERVER, <<"s.halloapp.net">>).
-define(UA, <<"HalloApp/iPhone1.0">>).
-define(BAD_UA, <<"BadUserAgent/1.0">>).
-define(IP1, "1.1.1.1").
-define(APPLE_IP, "17.3.4.5").
-define(SMS_CODE, <<"111111">>).
-define(BAD_SMS_CODE, <<"111110">>).
-define(BAD_PASSWORD, <<"BADPASS">>).
-define(BAD_SIGNED_MESSAGE, <<"BADSIGNEDMESSAGE">>).
-define(IDENTITY_KEY, <<"ZGFkc2FkYXNma2xqc2RsZmtqYXNkbGtmamFzZGxrZmphc2xrZGZqYXNsO2tkCgo=">>).
-define(SIGNED_KEY, <<"Tmlrb2xhIHdyb3RlIHRoaXMgbmljZSBtZXNzYWdlIG1ha2luZyBzdXJlIGl0IGlzIGxvbmcgCg==">>).
-define(ONE_TIME_KEY, <<"VGhpcyBpcyBvbmUgdGltZSBrZXkgZm9yIHRlc3RzIHRoYXQgaXMgbG9uZwo=">>).
-define(REQUEST_SMS_PATH, [<<"registration">>, <<"request_sms">>]).
-define(REQUEST_GET_GROUP_INFO_PATH, [<<"registration">>, <<"get_group_info">>]).
-define(REQUEST_HEADERS(UA), [
    {'Content-Type',<<"application/json">>},
    {'User-Agent',UA}]).
-define(GERMAN_LANG_ID, <<"de">>).
-define(BAD_PUSH_OS, <<"ios_app">>).
-define(PUSH_OS, <<"ios_appclip">>).
-define(PUSH_TOKEN, <<"7f15acdc75e10914e483ce9314779ad2b10ebd9bce586e8352d0971b9772c026">>).

-define(REGISTER2_PATH, [<<"registration">>, <<"register2">>]).
-define(REGISTER2_DATA(Phone, Code, Name, SEdPub, SignedPhrase),
    jsx:encode([{<<"phone">>, Phone}, {<<"code">>, Code}, {<<"name">>, Name},
                {<<"s_ed_pub">>, SEdPub}, {<<"signed_phrase">>, SignedPhrase}])).

-define(REGISTER3_DATA(Phone, Code, Name, SEdPub, SignedPhrase, LangId, PushOs, PushToken),
    jsx:encode([{<<"phone">>, Phone}, {<<"code">>, Code}, {<<"name">>, Name},
                {<<"s_ed_pub">>, SEdPub}, {<<"signed_phrase">>, SignedPhrase},
                {<<"lang_id">>, LangId}, {<<"push_os">>, PushOs}, {<<"push_token">>, PushToken}])).

-define(UPDATE_KEY_PATH, [<<"registration">>, <<"update_key">>]).
-define(UPDATE_KEY_DATA(UId, Pass, SEdPub, SignedPhrase),
    jsx:encode([{<<"uid">>, UId}, {<<"password">>, Pass},
                {<<"s_ed_pub">>, SEdPub}, {<<"signed_phrase">>, SignedPhrase}])).

-define(IP, {{0,0,0,0,0,65535,32512,1}, 5580}).

%%%----------------------------------------------------------------------
%%% IQ tests
%%%----------------------------------------------------------------------

request_sms_test() ->
    setup(),
    meck_init(ejabberd_router, is_my_host, fun(_) -> true end),
    meck_init(stat, count, fun(_,_,_,_) -> "Logged a metric!" end),
    meck_init(model_phone, add_gateway_response, fun(_, _, _) -> ok end),
    Data = jsx:encode([{<<"phone">>, ?TEST_PHONE}]),
    ok = model_accounts:create_account(?UID, ?PHONE, ?NAME, <<"HalloApp/Android0.127">>, 16175550000),
    ok = model_invites:record_invite(?UID, ?TEST_PHONE, 4),
    BadUserAgentError = util_http:return_400(),
    ?assertEqual(BadUserAgentError, mod_halloapp_http_api:process(?REQUEST_SMS_PATH,
        #request{method = 'POST', data = Data, ip = ?IP, headers = ?REQUEST_HEADERS(?BAD_UA)})),
    ?assert(meck:called(stat, count, ["HA/account", "request_sms_errors", 1,
        [{error, bad_user_agent}]])),
    meck_finish(stat),
    GoodResponse = {200, ?HEADER(?CT_JSON),
        jiffy:encode({[
            {phone, ?TEST_PHONE},
            {retry_after_secs, 30},
            {result, ok}
        ]})},
    Response = mod_halloapp_http_api:process(?REQUEST_SMS_PATH,
        #request{method = 'POST', data = Data, ip = ?IP, headers = ?REQUEST_HEADERS(?UA)}),
    ?assertEqual(GoodResponse, Response),
    meck_finish(model_phone),
    meck_finish(ejabberd_router).

% tests functionality of getting the sms code for a test number in prod env
% sms code should be sent to the inviter of the test number
request_sms_prod_test() ->
    setup(),
    meck_init(ejabberd_router, is_my_host, fun(_) -> true end),
    meck_init(model_phone, add_gateway_response, fun(_, _, _) -> ok end),
    meck_init(config, is_prod_env, fun() -> true end),
    meck_init(mod_sms, send_otp_internal,
        fun(P,_,_,_,_,_) ->
            self() ! P,
            {ok, #gateway_response{attempt_ts = util:now()}}
        end),
    Data = jsx:encode([{<<"phone">>, ?TEST_PHONE}]),
    ok = model_accounts:create_account(?UID, ?PHONE, ?NAME, <<"HalloApp/Android0.127">>, 16175550000),
    ok = model_invites:record_invite(?UID, ?TEST_PHONE, 4),
    GoodResponse = {200, ?HEADER(?CT_JSON),
        jiffy:encode({[
            {phone, ?TEST_PHONE},
            {retry_after_secs, 30},
            {result, ok}
        ]})},
    Response = mod_halloapp_http_api:process(?REQUEST_SMS_PATH,
        #request{method = 'POST', data = Data, ip = ?IP, headers = ?REQUEST_HEADERS(?UA)}),
    ?assertEqual(GoodResponse, Response),
    ?assertEqual(1, collect(?PHONE, 250, 1)),
    meck_finish(model_phone),
    meck_finish(config),
    meck_finish(mod_sms),
    meck_finish(ejabberd_router).

backoff_test() ->
    setup(),
    meck_init(ejabberd_router, is_my_host, fun(_) -> true end),
    meck_init(config, is_prod_env, fun() -> true end),
    Data = jsx:encode([{<<"phone">>, ?TEST_PHONE}]),
    ok = model_accounts:create_account(?UID, ?PHONE, ?NAME, ?UA, 16175550000),
    ok = model_invites:record_invite(?UID, ?TEST_PHONE, 4),
    {ok, _AttemptId1, _} = model_phone:add_sms_code2(?TEST_PHONE, ?SMS_CODE),
    BadResponse = {400, ?HEADER(?CT_JSON),
        jiffy:encode({[
            {phone, ?TEST_PHONE},
            {retry_after_secs, 30},
            {error, retried_too_soon},
            {result, fail}
        ]})},
    Response = mod_halloapp_http_api:process(?REQUEST_SMS_PATH,
        #request{method = 'POST', data = Data, ip = ?IP, headers = ?REQUEST_HEADERS(?UA)}),
    ?assertEqual(BadResponse, Response),
    %% Sleep for 1 seconds so the timestamp for Attempt1 and Attempt2 is different.
    timer:sleep(timer:seconds(1)),
    {ok, _AttemptId2, _} = model_phone:add_sms_code2(?TEST_PHONE, ?SMS_CODE),
    BadResponse2 = {400, ?HEADER(?CT_JSON),
        jiffy:encode({[
            {phone, ?TEST_PHONE},
            {retry_after_secs, 60},
            {error, retried_too_soon},
            {result, fail}
        ]})},
    Response2 = mod_halloapp_http_api:process(?REQUEST_SMS_PATH,
        #request{method = 'POST', data = Data, ip = ?IP, headers = ?REQUEST_HEADERS(?UA)}),
    ?assertEqual(BadResponse2, Response2),
    meck_finish(config),
    meck_finish(ejabberd_router).


request_sms_test_phone_test() ->
    setup(),
    meck_init(ejabberd_router, is_my_host, fun(_) -> true end),
    meck:new(stat, [passthrough]),
    meck:expect(stat, count, fun(_,_,_,_) -> "Logged a metric!" end),
    Data = jsx:encode([{<<"phone">>, ?PHONE}]),
    GoodResponse = {200, ?HEADER(?CT_JSON),
        jiffy:encode({[
            {phone, ?PHONE},
            {retry_after_secs, 30},
            {result, ok}
        ]})},
%%    NotInvitedError = util_http:return_400(not_invited),
    ?assertEqual(GoodResponse, mod_halloapp_http_api:process(?REQUEST_SMS_PATH,
        #request{method = 'POST', data = Data, ip = ?IP, headers = ?REQUEST_HEADERS(?UA)})),
%%    ?assert(meck:called(stat, count, ["HA/account", "request_sms_errors", 1,
%%        [{error, not_invited}]])),
    meck_finish(stat),
    meck_finish(ejabberd_router).


register_spub_test() ->
    setup(),
    meck_init(ejabberd_router, is_my_host, fun(_) -> true end),
    meck_init(ejabberd_sm, kick_user, fun(_, _) -> 1 end),
    meck_init(stat, count, fun(_,_,_,_) -> 1 end),
    Data = jsx:encode([{<<"phone">>, ?TEST_PHONE}]),
    ok = model_invites:record_invite(?UID, ?TEST_PHONE, 4),
    mod_halloapp_http_api:process(?REQUEST_SMS_PATH,
        #request{method = 'POST', data = Data, ip = ?IP, headers = ?REQUEST_HEADERS(?UA)}),
    KeyPair = ha_enoise:generate_signature_keypair(),
    {SEdSecret, SEdPub} = {maps:get(secret, KeyPair), maps:get(public, KeyPair)},
    SignedMessage = enacl:sign("HALLO", SEdSecret),
    SEdPubEncoded = base64:encode(SEdPub),
    SignedMessageEncoded = base64:encode(SignedMessage),
    BadCodeData = ?REGISTER2_DATA(?TEST_PHONE, ?BAD_SMS_CODE, ?NAME, SEdPubEncoded,
                                  SignedMessageEncoded),
    BadCodeError = util_http:return_400(wrong_sms_code),
    ?assertEqual(BadCodeError, mod_halloapp_http_api:process(?REGISTER2_PATH,
        #request{method = 'POST', data = BadCodeData, ip = ?IP, headers = ?REQUEST_HEADERS(?UA)})),
    ?assert(meck:called(stat, count, ["HA/account", "register_errors", 1,
        [{error, wrong_sms_code}]])),
    GoodData = ?REGISTER2_DATA(?TEST_PHONE, ?SMS_CODE, ?NAME, SEdPubEncoded, SignedMessageEncoded),
    BadUserAgentError = util_http:return_400(),
    ?assertEqual(BadUserAgentError, mod_halloapp_http_api:process(?REGISTER2_PATH,
        #request{method = 'POST', data = GoodData, ip = ?IP, headers = ?REQUEST_HEADERS(?BAD_UA)})),
    ?assert(meck:called(stat, count, ["HA/account", "register_errors", 1,
        [{error, bad_user_agent}]])),
    meck_finish(stat),
    {200, ?HEADER(?CT_JSON), RegInfo} = mod_halloapp_http_api:process(?REGISTER2_PATH,
        #request{method = 'POST', data = GoodData, ip = ?IP, headers = ?REQUEST_HEADERS(?UA)}),
    #{
        <<"uid">> := Uid,
        <<"phone">> := ?TEST_PHONE,
        <<"name">> := ?NAME,
        <<"result">> := <<"ok">>
    } = jiffy:decode(RegInfo, [return_maps]),
    SPub = enacl:crypto_sign_ed25519_public_to_curve25519(SEdPub),
    ?assert(ejabberd_auth:check_spub(Uid, base64:encode(SPub))),
    %% Re-reg
    KeyPair2 = ha_enoise:generate_signature_keypair(),
    {SEdSecret2, SEdPub2} = {maps:get(secret, KeyPair2), maps:get(public, KeyPair2)},
    SignedMessage2 = enacl:sign("HALLO", SEdSecret2),
    SEdPubEncoded2 = base64:encode(SEdPub2),
    SignedMessageEncoded2 = base64:encode(SignedMessage2),
    GoodData2 = ?REGISTER2_DATA(?TEST_PHONE, ?SMS_CODE, ?NAME, SEdPubEncoded2, SignedMessageEncoded2),
    {200, ?HEADER(?CT_JSON), Info} = mod_halloapp_http_api:process(?REGISTER2_PATH,
        #request{method = 'POST', data = GoodData2, ip = ?IP, headers = ?REQUEST_HEADERS(?UA)}),
    #{
        <<"uid">> := Uid,
        <<"phone">> := ?TEST_PHONE,
        <<"name">> := ?NAME,
        <<"result">> := <<"ok">>
    } = jiffy:decode(Info, [return_maps]),
    SPub2 = enacl:crypto_sign_ed25519_public_to_curve25519(SEdPub2),
    ?assert(ejabberd_auth:check_spub(Uid, base64:encode(SPub2))),
    meck_finish(ejabberd_sm),
    meck_finish(ejabberd_router).


register_push_token_test() ->
    setup(),
    meck_init(ejabberd_router, is_my_host, fun(_) -> true end),
    meck_init(ejabberd_sm, kick_user, fun(_, _) -> 1 end),
    Data = jsx:encode([{<<"phone">>, ?TEST_PHONE}]),
    ok = model_invites:record_invite(?UID, ?TEST_PHONE, 4),
    mod_halloapp_http_api:process(?REQUEST_SMS_PATH,
        #request{method = 'POST', data = Data, ip = ?IP, headers = ?REQUEST_HEADERS(?UA)}),
    KeyPair = ha_enoise:generate_signature_keypair(),
    {SEdSecret, SEdPub} = {maps:get(secret, KeyPair), maps:get(public, KeyPair)},
    SignedMessage = enacl:sign("HALLO", SEdSecret),
    SEdPubEncoded = base64:encode(SEdPub),
    SignedMessageEncoded = base64:encode(SignedMessage),
    GoodData1 = ?REGISTER3_DATA(?TEST_PHONE, ?SMS_CODE, ?NAME,
        SEdPubEncoded, SignedMessageEncoded, ?GERMAN_LANG_ID, ?BAD_PUSH_OS, ?PUSH_TOKEN),
    {200, ?HEADER(?CT_JSON), RegInfo} = mod_halloapp_http_api:process(?REGISTER2_PATH,
        #request{method = 'POST', data = GoodData1,
        ip = ?IP, headers = ?REQUEST_HEADERS(?UA)}),
    #{
        <<"uid">> := Uid,
        <<"phone">> := ?TEST_PHONE,
        <<"name">> := ?NAME,
        <<"result">> := <<"ok">>
    } = jiffy:decode(RegInfo, [return_maps]),
    SPub = enacl:crypto_sign_ed25519_public_to_curve25519(SEdPub),
    ?assert(ejabberd_auth:check_spub(Uid, base64:encode(SPub))),
    {ok, PushInfo1} = model_accounts:get_push_info(Uid),
    ?assertEqual(undefined, PushInfo1#push_info.lang_id),
    ?assertEqual(undefined, PushInfo1#push_info.os),
    ?assertEqual(undefined, PushInfo1#push_info.token),
    %% Re-reg with correct Os
    KeyPair2 = ha_enoise:generate_signature_keypair(),
    {SEdSecret2, SEdPub2} = {maps:get(secret, KeyPair2), maps:get(public, KeyPair2)},
    SignedMessage2 = enacl:sign("HALLO", SEdSecret2),
    SEdPubEncoded2 = base64:encode(SEdPub2),
    SignedMessageEncoded2 = base64:encode(SignedMessage2),
    GoodData2 = ?REGISTER3_DATA(?TEST_PHONE, ?SMS_CODE, ?NAME,
        SEdPubEncoded2, SignedMessageEncoded2, ?GERMAN_LANG_ID, ?PUSH_OS, ?PUSH_TOKEN),
    {200, ?HEADER(?CT_JSON), Info} = mod_halloapp_http_api:process(?REGISTER2_PATH,
        #request{method = 'POST', data = GoodData2, ip = ?IP, headers = ?REQUEST_HEADERS(?UA)}),
    #{
        <<"uid">> := Uid,
        <<"phone">> := ?TEST_PHONE,
        <<"name">> := ?NAME,
        <<"result">> := <<"ok">>
    } = jiffy:decode(Info, [return_maps]),
    SPub2 = enacl:crypto_sign_ed25519_public_to_curve25519(SEdPub2),
    ?assert(ejabberd_auth:check_spub(Uid, base64:encode(SPub2))),
    {ok, PushInfo2} = model_accounts:get_push_info(Uid),
    ?assertEqual(?GERMAN_LANG_ID, PushInfo2#push_info.lang_id),
    ?assertEqual(?PUSH_OS, PushInfo2#push_info.os),
    ?assertEqual(?PUSH_TOKEN, PushInfo2#push_info.token),
    meck_finish(ejabberd_sm),
    meck_finish(ejabberd_router).


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


check_invited_test() ->
    setup(),
    ?assertEqual(ok, mod_halloapp_http_api:check_invited(?TEST_PHONE, <<"">>, ?IP1, undefined)),

%%    ?assertError(not_invited, mod_halloapp_http_api:check_invited(?PHONE, <<"">>, ?IP1, undefined)),
    ?assertEqual(ok, mod_halloapp_http_api:check_invited(?PHONE, <<"">>, ?IP1, undefined)),
    model_invites:record_invite(?UID, ?PHONE, 4),
    ?assertEqual(ok, mod_halloapp_http_api:check_invited(?PHONE, <<"">>, ?IP1, undefined)),
    ok.


check_invited_reregister_test() ->
    setup(),
    % make sure existing user can re-register
%%    ?assertError(not_invited, mod_halloapp_http_api:check_invited(?PHONE, <<"">>, ?IP1, undefined)),
    ?assertEqual(ok, mod_halloapp_http_api:check_invited(?PHONE, <<"">>, ?IP1, undefined)),
    {ok, _Pass, _Uid} = ejabberd_auth:ha_try_register(?PHONE, <<"pass">>, ?NAME, ?UA),
    ?assertEqual(ok, mod_halloapp_http_api:check_invited(?PHONE, <<"">>, ?IP1, undefined)),
    ok.


request_and_check_sms_code_test() ->
    setup(),
    meck_init(ejabberd_router, is_my_host, fun(_) -> true end),
    ?assertError(wrong_sms_code, mod_halloapp_http_api:check_sms_code(?TEST_PHONE, ?SMS_CODE)),
    {ok, _} = mod_sms:request_sms(?TEST_PHONE, ?UA),
    ?assertError(wrong_sms_code, mod_halloapp_http_api:check_sms_code(?TEST_PHONE, ?BAD_SMS_CODE)),
    ?assertEqual(ok, mod_halloapp_http_api:check_sms_code(?TEST_PHONE, ?SMS_CODE)),
    meck_finish(ejabberd_router).


is_version_invite_opened_test() ->
%%    ?assertEqual(true, mod_halloapp_http_api:is_version_invite_opened(<<"HalloApp/iOS1.0.79">>)),
    ?assertEqual(false, mod_halloapp_http_api:is_version_invite_opened(<<"HalloApp/iOS1.1">>)),
    ok.


check_invited_by_version_test() ->
    setup(),
    ?assertEqual(ok, mod_halloapp_http_api:check_invited(
        <<"16501231234">>, <<"HalloApp/iOS1.0.79">>, ?IP1, undefined)),
    ?assertEqual(ok, mod_halloapp_http_api:check_invited(
        <<"16501231234">>, <<"HalloApp/iOS1.1">>, ?IP1, undefined)),
    ok.

check_invited_by_ip_test() ->
    setup(),
    ?assertEqual(ok, mod_halloapp_http_api:check_invited(
        ?PHONE, <<"">>, ?APPLE_IP, undefined)),
    ?assertEqual(ok, mod_halloapp_http_api:check_invited(
        ?PHONE, <<"">>, ?IP1, undefined)),
    ok.

check_invited_by_group_invite_test() ->
    setup(),
    {ok, Gid} = model_groups:create_group(?UID, <<"Gname">>),
    {true, Token} = model_groups:get_invite_link(Gid),
    ?assertEqual(ok, mod_halloapp_http_api:check_invited(
        ?PHONE, <<"">>, ?IP1, undefined)),
    ?assertEqual(ok, mod_halloapp_http_api:check_invited(
        ?PHONE, <<"">>, ?IP1, Token)),
    ok.
 
check_empty_inviter_list_test() ->
    setup(),
    ?assertEqual({error, not_invited}, mod_sms:send_otp_to_inviter(?TEST_PHONE, undefined, undefined, undefined, undefined)),
    ok. 

check_has_inviter_test() -> 
    setup(),
    meck_init(config, is_prod_env, fun() -> true end), 
    ?assertEqual(ok, mod_halloapp_http_api:check_invited(
                ?TEST_PHONE, <<"">>, ?IP1, undefined)),
    meck_finish(config),
    ok.


get_group_info_test() ->
    setup(),
    GroupName = <<"GroupName1">>,
    {ok, Group} = mod_groups:create_group(?UID, GroupName),
    Gid = Group#group.gid,
    ?assertEqual(true, model_groups:is_admin(Gid, ?UID)),
    {ok, Link} = mod_groups:get_invite_link(Gid, ?UID),
    Data = jiffy:encode(#{group_invite_token => Link}),
    {200, _, ResultJson} = mod_halloapp_http_api:process(?REQUEST_GET_GROUP_INFO_PATH,
        #request{method = 'POST', data = Data, ip = ?IP, headers = ?REQUEST_HEADERS(?UA)}),
    Result = jiffy:decode(ResultJson, [return_maps]),
    ExpectedResult = #{<<"result">> => <<"ok">>, <<"name">> => GroupName},
    ?assertEqual(ExpectedResult, Result),

    BadData = jiffy:encode(#{group_invite_token => <<"foobar">>}),
    ?assertEqual(
        util_http:return_400(invalid_invite),
        mod_halloapp_http_api:process(?REQUEST_GET_GROUP_INFO_PATH,
            #request{method = 'POST', data = BadData, ip = ?IP, headers = ?REQUEST_HEADERS(?UA)})),

    ?assertEqual(
        util_http:return_400(),
        mod_halloapp_http_api:process(?REQUEST_GET_GROUP_INFO_PATH,
            #request{method = 'POST', data = Data, ip = ?IP, headers = ?REQUEST_HEADERS(?BAD_UA)})),

    ok.


%%%----------------------------------------------------------------------
%%% Internal functions
%%%----------------------------------------------------------------------
setup() ->
    tutil:setup(),
    {ok, _} = application:ensure_all_started(stringprep),
    ha_redis:start(),
    clear(),
    ok.


clear() ->
    tutil:cleardb(redis_accounts),
    tutil:cleardb(redis_whisper),
    ok.


meck_init(Mod, FunName, Fun) ->
    meck:new(Mod, [passthrough]),
    meck:expect(Mod, FunName, Fun).


meck_finish(Mod) ->
    ?assert(meck:validate(Mod)),
    meck:unload(Mod).

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

