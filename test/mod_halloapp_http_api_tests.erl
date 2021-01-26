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
-include_lib("eunit/include/eunit.hrl").

-define(UID, <<"1">>).
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
-define(REQUEST_SMS_HEADERS(UA), [
    {'Content-Type',<<"application/x-www-form-urlencoded">>},
    {'Content-Length',<<"24">>},
    {'Accept',<<"*/*">>},
    {'User-Agent',UA},
    {'Host',<<"127.0.0.1:5580">>}]).
-define(REGISTER_PATH, [<<"registration">>, <<"register">>]).
-define(REGISTER_HEADERS(UA), [
    {'Content-Type',<<"application/x-www-form-urlencoded">>},
    {'Content-Length',<<"58">>},
    {'Accept',<<"*/*">>},
    {'User-Agent',UA},
    {'Host',<<"127.0.0.1:5580">>}]).
-define(REGISTER_DATA(Phone, Code, Name),
    jsx:encode([{<<"phone">>, Phone}, {<<"code">>, Code}, {<<"name">>, Name}])).
-define(REGISTER_DATA_W(Phone, Code, Name, WhisperKey, SignedKey, OneTimeKeys),
    jsx:encode([{<<"phone">>, Phone}, {<<"code">>, Code}, {<<"name">>, Name},
        {<<"identity_key">>, WhisperKey}, {<<"signed_key">>, SignedKey},
        {<<"one_time_keys">>, OneTimeKeys}])).

-define(REGISTER2_PATH, [<<"registration">>, <<"register2">>]).
-define(REGISTER2_DATA(Phone, Code, Name, SEdPub, SignedPhrase),
    jsx:encode([{<<"phone">>, Phone}, {<<"code">>, Code}, {<<"name">>, Name},
                {<<"s_ed_pub">>, SEdPub}, {<<"signed_phrase">>, SignedPhrase}])).

-define(UPDATE_KEY_PATH, [<<"registration">>, <<"update_key">>]).
-define(UPDATE_KEY_DATA(UId, Pass, SEdPub, SignedPhrase),
    jsx:encode([{<<"uid">>, UId}, {<<"password">>, Pass},
                {<<"s_ed_pub">>, SEdPub}, {<<"signed_phrase">>, SignedPhrase}])).


%%%----------------------------------------------------------------------
%%% IQ tests
%%%----------------------------------------------------------------------

request_sms_test() ->
    setup(),
    meck_init(ejabberd_router, is_my_host, fun(_) -> true end),
    meck_init(stat, count, fun(_,_,_,_) -> "Logged a metric!" end),
    Data = jsx:encode([{<<"phone">>, ?TEST_PHONE}]),
    ok = model_invites:record_invite(?UID, ?TEST_PHONE, 4),
    BadUserAgentError = util_http:return_400(),
    ?assertEqual(BadUserAgentError, mod_halloapp_http_api:process(?REQUEST_SMS_PATH,
        #request{method = 'POST', data = Data, headers = ?REQUEST_SMS_HEADERS(?BAD_UA)})),
    ?assert(meck:called(stat, count, ["HA/account", "request_sms_errors", 1,
        [{error, bad_user_agent}]])),
    meck_finish(stat),
    GoodResponse = {200, ?HEADER(?CT_JSON),
        jiffy:encode({[
            {phone, ?TEST_PHONE},
            {retry_after_secs, ?SMS_RETRY_AFTER_SECS},
            {result, ok}
        ]})},
    ?assertEqual(GoodResponse, mod_halloapp_http_api:process(?REQUEST_SMS_PATH,
        #request{method = 'POST', data = Data, headers = ?REQUEST_SMS_HEADERS(?UA)})),
    meck_finish(ejabberd_router).


request_sms_test_phone_test() ->
    setup(),
    meck_init(ejabberd_router, is_my_host, fun(_) -> true end),
    meck_init(stat, count, fun(_,_,_,_) -> "Logged a metric!" end),
    Data = jsx:encode([{<<"phone">>, ?PHONE}]),
    NotInvitedError = util_http:return_400(not_invited),
    ?assertEqual(NotInvitedError, mod_halloapp_http_api:process(?REQUEST_SMS_PATH,
        #request{method = 'POST', data = Data, headers = ?REQUEST_SMS_HEADERS(?UA)})),
    ?assert(meck:called(stat, count, ["HA/account", "request_sms_errors", 1,
        [{error, not_invited}]])),
    meck_finish(stat),
    meck_finish(ejabberd_router).


register_test() ->
    setup(),
    meck_init(ejabberd_router, is_my_host, fun(_) -> true end),
    meck_init(ejabberd_sm, kick_user, fun(_, _) -> 1 end),
    Data = jsx:encode([{<<"phone">>, ?TEST_PHONE}]),
    ok = model_invites:record_invite(?UID, ?TEST_PHONE, 4),
    mod_halloapp_http_api:process(?REQUEST_SMS_PATH,
        #request{method = 'POST', data = Data, headers = ?REQUEST_SMS_HEADERS(?UA)}),
    BadCodeData = ?REGISTER_DATA(?TEST_PHONE, ?BAD_SMS_CODE, ?NAME),
    BadCodeError = util_http:return_400(wrong_sms_code),
    ?assertEqual(BadCodeError, mod_halloapp_http_api:process(?REGISTER_PATH,
        #request{method = 'POST', data = BadCodeData, headers = ?REGISTER_HEADERS(?UA)})),
    GoodData = ?REGISTER_DATA(?TEST_PHONE, ?SMS_CODE, ?NAME),
    BadUserAgentError = util_http:return_400(),
    ?assertEqual(BadUserAgentError, mod_halloapp_http_api:process(?REGISTER_PATH,
        #request{method = 'POST', data = GoodData, headers = ?REGISTER_HEADERS(?BAD_UA)})),
    {200, ?HEADER(?CT_JSON), RegInfo} = mod_halloapp_http_api:process(?REGISTER_PATH,
        #request{method = 'POST', data = GoodData, headers = ?REGISTER_HEADERS(?UA)}),
    [{<<"uid">>, Uid}, {<<"phone">>, ?TEST_PHONE}, {<<"password">>, RegPass},
        {<<"name">>, ?NAME}, {<<"result">>, <<"ok">>}] = jsx:decode(RegInfo),
    ?assert(ejabberd_auth:check_password(Uid, RegPass)),
    %% RE-reg
    {200, ?HEADER(?CT_JSON), Info} = mod_halloapp_http_api:process(?REGISTER_PATH,
        #request{method = 'POST', data = GoodData, headers = ?REGISTER_HEADERS(?UA)}),
    [{<<"uid">>, Uid}, {<<"phone">>, ?TEST_PHONE}, {<<"password">>, Pass},
        {<<"name">>, ?NAME}, {<<"result">>, <<"ok">>}] = jsx:decode(Info),
    ?assert(ejabberd_auth:check_password(Uid, Pass)),
    meck_finish(ejabberd_sm),
    meck_finish(ejabberd_router).

% TODO: add tests for bad keys (too small, too large, too few, too many)
register_and_whisper_test() ->
    setup(),
    meck_init(ejabberd_router, is_my_host, fun(_) -> true end),
    meck_init(ejabberd_sm, kick_user, fun(_, _) -> 1 end),
    Data = jsx:encode([{<<"phone">>, ?TEST_PHONE}]),
    ok = model_invites:record_invite(?UID, ?TEST_PHONE, 4),
    mod_halloapp_http_api:process(?REQUEST_SMS_PATH,
        #request{method = 'POST', data = Data, headers = ?REQUEST_SMS_HEADERS(?UA)}),
    OneTimeKeys = [?ONE_TIME_KEY || _X <- lists:seq(0, 9)],
    GoodData = ?REGISTER_DATA_W(?TEST_PHONE, ?SMS_CODE, ?NAME, ?IDENTITY_KEY, ?SIGNED_KEY, OneTimeKeys),
    {200, ?HEADER(?CT_JSON), RegInfo} = mod_halloapp_http_api:process(?REGISTER_PATH,
        #request{method = 'POST', data = GoodData, headers = ?REGISTER_HEADERS(?UA)}),
    [{<<"uid">>, Uid}, {<<"phone">>, ?TEST_PHONE}, {<<"password">>, RegPass},
        {<<"name">>, ?NAME}, {<<"result">>, <<"ok">>}] = jsx:decode(RegInfo),
    ?assert(ejabberd_auth:check_password(Uid, RegPass)),
    WhisperKeySet = #user_whisper_key_set{
        uid = Uid,
        identity_key = ?IDENTITY_KEY,
        signed_key = ?SIGNED_KEY,
        one_time_key = ?ONE_TIME_KEY
    },
    ?assertEqual({ok, WhisperKeySet}, model_whisper_keys:get_key_set(Uid)),
    ?assertEqual({ok, 9}, model_whisper_keys:count_otp_keys(Uid)),

    meck_finish(ejabberd_sm),
    meck_finish(ejabberd_router).

register_spub_test() ->
    setup(),
    meck_init(ejabberd_router, is_my_host, fun(_) -> true end),
    meck_init(ejabberd_sm, kick_user, fun(_, _) -> 1 end),
    meck_init(stat, count, fun(_,_,_,_) -> 1 end),
    Data = jsx:encode([{<<"phone">>, ?TEST_PHONE}]),
    ok = model_invites:record_invite(?UID, ?TEST_PHONE, 4),
    mod_halloapp_http_api:process(?REQUEST_SMS_PATH,
        #request{method = 'POST', data = Data, headers = ?REQUEST_SMS_HEADERS(?UA)}),
    KeyPair = ha_enoise:generate_signature_keypair(),
    {SEdSecret, SEdPub} = {maps:get(secret, KeyPair), maps:get(public, KeyPair)},
    SignedMessage = enacl:sign("HALLO", SEdSecret),
    SEdPubEncoded = base64:encode(SEdPub),
    SignedMessageEncoded = base64:encode(SignedMessage),
    BadCodeData = ?REGISTER2_DATA(?TEST_PHONE, ?BAD_SMS_CODE, ?NAME, SEdPubEncoded,
                                  SignedMessageEncoded),
    BadCodeError = util_http:return_400(wrong_sms_code),
    ?assertEqual(BadCodeError, mod_halloapp_http_api:process(?REGISTER2_PATH,
        #request{method = 'POST', data = BadCodeData, headers = ?REGISTER_HEADERS(?UA)})),
    ?assert(meck:called(stat, count, ["HA/account", "register_errors", 1,
        [{error, wrong_sms_code}]])),
    GoodData = ?REGISTER2_DATA(?TEST_PHONE, ?SMS_CODE, ?NAME, SEdPubEncoded, SignedMessageEncoded),
    BadUserAgentError = util_http:return_400(),
    ?assertEqual(BadUserAgentError, mod_halloapp_http_api:process(?REGISTER2_PATH,
        #request{method = 'POST', data = GoodData, headers = ?REGISTER_HEADERS(?BAD_UA)})),
    ?assert(meck:called(stat, count, ["HA/account", "register_errors", 1,
        [{error, bad_user_agent}]])),
    meck_finish(stat),
    {200, ?HEADER(?CT_JSON), RegInfo} = mod_halloapp_http_api:process(?REGISTER2_PATH,
        #request{method = 'POST', data = GoodData, headers = ?REGISTER_HEADERS(?UA)}),
    [{<<"uid">>, Uid}, {<<"phone">>, ?TEST_PHONE},
        {<<"name">>, ?NAME}, {<<"result">>, <<"ok">>}] = jsx:decode(RegInfo),
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
        #request{method = 'POST', data = GoodData2, headers = ?REGISTER_HEADERS(?UA)}),
    [{<<"uid">>, Uid}, {<<"phone">>, ?TEST_PHONE},
        {<<"name">>, ?NAME}, {<<"result">>, <<"ok">>}] = jsx:decode(Info),
    SPub2 = enacl:crypto_sign_ed25519_public_to_curve25519(SEdPub2),
    ?assert(ejabberd_auth:check_spub(Uid, base64:encode(SPub2))),
    meck_finish(ejabberd_sm),
    meck_finish(ejabberd_router).

update_key_test() ->
    setup(),
    meck_init(ejabberd_router, is_my_host, fun(_) -> true end),
    Data = jsx:encode([{<<"phone">>, ?TEST_PHONE}]),
    ok = model_invites:record_invite(?UID, ?PHONE, 4),
    mod_halloapp_http_api:process(?REQUEST_SMS_PATH,
        #request{method = 'POST', data = Data, headers = ?REQUEST_SMS_HEADERS(?UA)}),
    RegisterData = ?REGISTER_DATA(?TEST_PHONE, ?SMS_CODE, ?NAME),
    {200, ?HEADER(?CT_JSON), Info} = mod_halloapp_http_api:process(?REGISTER_PATH,
        #request{method = 'POST', data = RegisterData, headers = ?REGISTER_HEADERS(?UA)}),
    [{<<"uid">>, Uid}, {<<"phone">>, ?TEST_PHONE}, {<<"password">>, Pass},
        {<<"name">>, ?NAME}, {<<"result">>, <<"ok">>}] = jsx:decode(Info),
    ?assert(ejabberd_auth:check_password(Uid, Pass)),

    KeyPair = ha_enoise:generate_signature_keypair(),
    {SEdSecret, SEdPub} = {maps:get(secret, KeyPair), maps:get(public, KeyPair)},
    SignedMessage = enacl:sign("HALLO", SEdSecret),
    SEdPubEncoded = base64:encode(SEdPub),
    SignedMessageEncoded = base64:encode(SignedMessage),

    BadData1 = ?UPDATE_KEY_DATA(Uid, ?BAD_PASSWORD, SEdPubEncoded, SignedMessageEncoded),
    ?assertEqual(util_http:return_400(invalid_password),
                 mod_halloapp_http_api:process(?UPDATE_KEY_PATH, #request{method = 'POST',
         data = BadData1, headers = ?REGISTER_HEADERS(?UA)})),

    BadData2 = ?UPDATE_KEY_DATA(Uid, Pass, SEdPubEncoded, base64:encode(?BAD_SIGNED_MESSAGE)),
    ?assertEqual(util_http:return_400(unable_to_open_signed_phrase),
                 mod_halloapp_http_api:process(?UPDATE_KEY_PATH, #request{method = 'POST',
         data = BadData2, headers = ?REGISTER_HEADERS(?UA)})),

    BadSignedMessage = enacl:sign("BAD", SEdSecret),
    BadSignedMessageEncoded = base64:encode(BadSignedMessage),
    BadData3 = ?UPDATE_KEY_DATA(Uid, Pass, SEdPubEncoded, BadSignedMessageEncoded),
    ?assertEqual(util_http:return_400(invalid_signed_phrase),
                 mod_halloapp_http_api:process(?UPDATE_KEY_PATH, #request{method = 'POST',
         data = BadData3, headers = ?REGISTER_HEADERS(?UA)})),

    UpdateKeyData = ?UPDATE_KEY_DATA(Uid, Pass, SEdPubEncoded, SignedMessageEncoded),
    {200, ?HEADER(?CT_JSON), Info2} = mod_halloapp_http_api:process(?UPDATE_KEY_PATH,
        #request{method = 'POST', data = UpdateKeyData, headers = ?REGISTER_HEADERS(?UA)}),
    [{<<"result">>, <<"ok">>}] = jsx:decode(Info2),
    SPub = enacl:crypto_sign_ed25519_public_to_curve25519(SEdPub),
    ?assert(ejabberd_auth:check_spub(Uid, base64:encode(SPub))),
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
    ?assertEqual(ok, mod_halloapp_http_api:check_invited(?TEST_PHONE, <<"">>, ?IP1)),

    ?assertError(not_invited, mod_halloapp_http_api:check_invited(?PHONE, <<"">>, ?IP1)),
    model_invites:record_invite(?UID, ?PHONE, 4),
    ?assertEqual(ok, mod_halloapp_http_api:check_invited(?PHONE, <<"">>, ?IP1)),
    clear(),
    ?assertError(not_invited, mod_halloapp_http_api:check_invited(?PHONE, <<"">>, ?IP1)),
    {ok, _Pass, _Uid} = ejabberd_auth:ha_try_register(?PHONE, <<"pass">>, ?NAME, ?UA),
    ?assertEqual(ok, mod_halloapp_http_api:check_invited(?PHONE, <<"">>, ?IP1)).


request_and_check_sms_code_test() ->
    setup(),
    meck_init(ejabberd_router, is_my_host, fun(_) -> true end),
    ?assertError(wrong_sms_code, mod_halloapp_http_api:check_sms_code(?TEST_PHONE, ?SMS_CODE)),
    ok = mod_sms:request_sms(?TEST_PHONE, ?UA),
    ?assertError(wrong_sms_code, mod_halloapp_http_api:check_sms_code(?TEST_PHONE, ?BAD_SMS_CODE)),
    ?assertEqual(ok, mod_halloapp_http_api:check_sms_code(?TEST_PHONE, ?SMS_CODE)),
    meck_finish(ejabberd_router).


is_version_invite_opened_test() ->
%%    ?assertEqual(true, mod_halloapp_http_api:is_version_invite_opened(<<"HalloApp/iOS1.0.79">>)),
    ?assertEqual(false, mod_halloapp_http_api:is_version_invite_opened(<<"HalloApp/iOS1.1">>)),
    ok.


check_invited_by_version_test() ->
    setup(),
    ?assertError(not_invited, mod_halloapp_http_api:check_invited(
        <<"16501231234">>, <<"HalloApp/iOS1.0.79">>, ?IP1)),
    ?assertError(not_invited, mod_halloapp_http_api:check_invited(
        <<"16501231234">>, <<"HalloApp/iOS1.1">>, ?IP1)),
    ok.

check_invited_by_ip_test() ->
    setup(),
    ?assertEqual(ok, mod_halloapp_http_api:check_invited(
        ?PHONE, <<"">>, ?APPLE_IP)),
    ?assertError(not_invited, mod_halloapp_http_api:check_invited(
        ?PHONE, <<"">>, ?IP1)),
    ok.

log_if_registration_error_test() ->
    setup(),
    meck_init(ejabberd_router, is_my_host, fun(_) -> true end),
    meck_init(ejabberd_sm, kick_user, fun(_, _) -> 1 end),
    meck_init(stat, count, fun(_,_,_,_) -> "Logged a metric!" end),

    BadCodeData = ?REGISTER_DATA(?TEST_PHONE, ?BAD_SMS_CODE, ?NAME),
    BadCodeError = util_http:return_400(wrong_sms_code),
    ?assertEqual(BadCodeError, mod_halloapp_http_api:process(?REGISTER_PATH,
        #request{method = 'POST', data = BadCodeData, headers = ?REGISTER_HEADERS(?UA)})),
    ?assert(meck:called(stat, count, ["HA/account", "register_errors", 1,
        [{error, wrong_sms_code}]])),

    GoodData = ?REGISTER_DATA(?TEST_PHONE, ?SMS_CODE, ?NAME),
    BadUserAgentError = util_http:return_400(),
    ?assertEqual(BadUserAgentError, mod_halloapp_http_api:process(?REGISTER_PATH,
        #request{method = 'POST', data = GoodData, headers = ?REGISTER_HEADERS(?BAD_UA)})),
    ?assert(meck:called(stat, count, ["HA/account", "register_errors", 1,
        [{error, bad_user_agent}]])),

    meck_finish(stat),
    meck_finish(ejabberd_sm),
    meck_finish(ejabberd_router).



%%%----------------------------------------------------------------------
%%% Internal functions
%%%----------------------------------------------------------------------

setup() ->
    tutil:setup(),
    {ok, _} = application:ensure_all_started(stringprep),
    {ok, _} = application:ensure_all_started(bcrypt),
    redis_sup:start_link(),
    clear(),
    mod_redis:start(undefined, []),
    ok.


clear() ->
    tutil:cleardb(redis_accounts),
    tutil:cleardb(redis_whisper),
    ok.


meck_init(Mod, FunName, Fun) ->
    meck:new(Mod),
    meck:expect(Mod, FunName, Fun).


meck_finish(Mod) ->
    ?assert(meck:validate(Mod)),
    meck:unload(Mod).

