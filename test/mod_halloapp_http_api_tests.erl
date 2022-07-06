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
-define(BAD_PHONE, <<"1617555">>).
-define(VOIP_PHONE, <<"3544921234">>).
-define(NAME, <<"Josh">>).
-define(SERVER, <<"s.halloapp.net">>).
-define(UA, <<"HalloApp/iOS1.28.151">>).
-define(ANDROID_UA, <<"HalloApp/Android1.4">>).
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
-define(REQUEST_OTP_PATH, [<<"registration">>, <<"request_otp">>]).
-define(REQUEST_GET_GROUP_INFO_PATH, [<<"registration">>, <<"get_group_info">>]).
-define(REQUEST_HEADERS(UA), [
    {'Content-Type',<<"application/json">>},
    {'User-Agent',UA}]).
-define(GERMAN_LANG_ID, <<"de">>).
-define(BAD_PUSH_OS, <<"ios_app">>).
-define(PUSH_OS, <<"ios_appclip">>).
-define(PUSH_TOKEN, <<"7f15acdc75e10914e483ce9314779ad2b10ebd9bce586e8352d0971b9772c026">>).

-define(WHISPER_KEY_DATA, [{<<"identity_key">>, ?IDENTITY_KEY}, {<<"signed_key">>, ?SIGNED_KEY},
                {<<"one_time_keys">>, [?ONE_TIME_KEY, ?ONE_TIME_KEY, ?ONE_TIME_KEY,
                    ?ONE_TIME_KEY, ?ONE_TIME_KEY, ?ONE_TIME_KEY,
                    ?ONE_TIME_KEY, ?ONE_TIME_KEY, ?ONE_TIME_KEY, ?ONE_TIME_KEY]}]).

-define(REGISTER2_PATH, [<<"registration">>, <<"register2">>]).
-define(REGISTER2_DATA(Phone, Code, Name, SEdPub, SignedPhrase),
    jsx:encode([{<<"phone">>, Phone}, {<<"code">>, Code}, {<<"name">>, Name},
                {<<"s_ed_pub">>, SEdPub}, {<<"signed_phrase">>, SignedPhrase}] ++
                ?WHISPER_KEY_DATA)).

-define(REGISTER3_DATA(Phone, Code, Name, SEdPub, SignedPhrase, LangId, PushOs, PushToken),
    jsx:encode([{<<"phone">>, Phone}, {<<"code">>, Code}, {<<"name">>, Name},
                {<<"s_ed_pub">>, SEdPub}, {<<"signed_phrase">>, SignedPhrase},
                {<<"lang_id">>, LangId}, {<<"push_os">>, PushOs}, {<<"push_token">>, PushToken}] ++
                ?WHISPER_KEY_DATA)).

-define(UPDATE_KEY_PATH, [<<"registration">>, <<"update_key">>]).
-define(UPDATE_KEY_DATA(UId, Pass, SEdPub, SignedPhrase),
    jsx:encode([{<<"uid">>, UId}, {<<"password">>, Pass},
                {<<"s_ed_pub">>, SEdPub}, {<<"signed_phrase">>, SignedPhrase}] ++
                ?WHISPER_KEY_DATA)).

-define(IP, {{0,0,0,0,0,65535,32512,1}, 5580}).
-define(CC1, <<"IN">>).
-define(HASHCASH_UA, <<"HalloApp/Android10.197">>).
-define(BAD_HASHCASH_SOLUTION, <<"BadSolution">>).
-define(HASHCASH_TIME_TAKEN_MS, 100).
-define(REQUEST_HASHCASH_PATH, [<<"registration">>, <<"request_hashcash">>]).

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
    ?assertEqual(BadUserAgentError, mod_halloapp_http_api:process(?REQUEST_OTP_PATH,
        #request{method = 'POST', data = Data, ip = ?IP, headers = ?REQUEST_HEADERS(?BAD_UA)})),

    BadPhoneData = jsx:encode([{<<"phone">>, ?BAD_PHONE}]),
    % Android phones should return old phone error msgs, IOS with version > 1.19 should return new ones
    BadAndroidPhoneError = util_http:return_400(invalid_phone_number),
    BadIOSPhoneError = util_http:return_400(invalid_length),

    ?assertEqual(BadAndroidPhoneError, mod_halloapp_http_api:process(?REQUEST_OTP_PATH,
        #request{method = 'POST', data = BadPhoneData, ip = ?IP, headers = ?REQUEST_HEADERS(?ANDROID_UA)})),
    ?assertEqual(BadIOSPhoneError, mod_halloapp_http_api:process(?REQUEST_OTP_PATH,
        #request{method = 'POST', data = BadPhoneData, ip = ?IP, headers = ?REQUEST_HEADERS(?UA)})),

    % voip number are currently unsupported – should thrown an error
    VoipPhoneData = jsx:encode([{<<"phone">>, ?VOIP_PHONE}]),
    VoipPhoneError = util_http:return_400(line_type_other),
    ?assertEqual(VoipPhoneError, mod_halloapp_http_api:process(?REQUEST_OTP_PATH,
        #request{method = 'POST', data = VoipPhoneData, ip = ?IP, headers = ?REQUEST_HEADERS(?UA)})),

    ?assert(meck:called(stat, count, ["HA/account", "request_otp_errors", 1,
        [{error, bad_user_agent}, {method, sms}]])),
    meck_finish(stat),
    GoodResponse = {200, ?HEADER(?CT_JSON),
        jiffy:encode({[
            {phone, ?TEST_PHONE},
            {retry_after_secs, 30},
            {result, ok}
        ]})},
    Response = mod_halloapp_http_api:process(?REQUEST_OTP_PATH,
        #request{method = 'POST', data = Data, ip = ?IP, headers = ?REQUEST_HEADERS(?UA)}),
    ?assertEqual(GoodResponse, Response),
    meck_finish(model_phone),
    meck_finish(ejabberd_router).

% tests functionality of getting the sms code for a test number in prod env
% sms code should be sent to the inviter of the test number
% registration should still happen using the test number
request_sms_prod_test() ->
    setup(),
    meck_init(ejabberd_router, is_my_host, fun(_) -> true end),
    meck_init(model_phone, add_gateway_response, fun(_, _, _) -> ok end),
    meck_init(config, get_hallo_env, fun() -> prod end),
    GtwyResp = {ok, #gateway_response{attempt_ts = util:now(), status = sent}},
    % only meck network requests
    meck_init(mbird, send_sms, fun(P,_,_,_) -> self() ! P, GtwyResp end),
    meck_init(twilio, send_sms, fun(P,_,_,_) -> self() ! P, GtwyResp end),
    meck_init(twilio_verify, send_sms, fun(P,_,_,_) -> self() ! P, GtwyResp end),
    meck_init(mbird_verify, send_sms, fun(P,_,_,_) -> self() ! P, GtwyResp end),
    meck_init(otp_checker_protocol, check_otp_request, fun(_,_,_,_,_,_) -> ok end),
    Data = jsx:encode([{<<"phone">>, ?TEST_PHONE}]),
    ok = model_accounts:create_account(?UID, ?PHONE, ?NAME, <<"HalloApp/Android0.127">>, 16175550000),
    ok = model_invites:record_invite(?UID, ?TEST_PHONE, 4),
    GoodResponse = {200, ?HEADER(?CT_JSON),
        jiffy:encode({[
            {phone, ?TEST_PHONE},
            {retry_after_secs, 30},
            {result, ok}
        ]})},
    Response = mod_halloapp_http_api:process(?REQUEST_OTP_PATH,
        #request{method = 'POST', data = Data, ip = ?IP, headers = ?REQUEST_HEADERS(?UA)}),
    ?assertEqual(GoodResponse, Response),
    ?assertEqual(1, collect(?PHONE, 250, 1)),
    ?assert(meck:called(model_phone, add_sms_code2, [?TEST_PHONE, '_', '_'])),
    ?assert(meck:called(mbird, send_sms, [?PHONE,'_','_','_']) orelse
            meck:called(twilio, send_sms, [?PHONE,'_','_','_']) orelse
            meck:called(mbird_verify, send_sms, [?PHONE,'_','_','_']) orelse
            meck:called(twilio_verify, send_sms, [?PHONE,'_','_','_'])),
    meck_finish(otp_checker_protocol),
    meck_finish(mbird),
    meck_finish(twilio),
    meck_finish(twilio_verify),
    meck_finish(mbird_verify),
    meck_finish(model_phone),
    meck_finish(config),
    meck_finish(ejabberd_router).


%% TODO(vipin): Enable it
request_sms_hashcash_test_disable() ->
    setup(),
    meck_init(ejabberd_router, is_my_host, fun(_) -> true end),
    % meck network requests
    meck_init(mod_sms, request_otp, fun(P, _, _, _) -> self() ! P, {ok, 30} end),
    Data = jiffy:encode({[{<<"phone">>, ?TEST_PHONE}, {<<"hashcash_solution">>, ?BAD_HASHCASH_SOLUTION}]}),
    ok = model_accounts:create_account(?UID, ?PHONE, ?NAME, ?UA, 16175550000),
    ok = model_invites:record_invite(?UID, ?TEST_PHONE, 4),
    Response = mod_halloapp_http_api:process(?REQUEST_OTP_PATH,
        #request{method = 'POST', data = Data, ip = ?IP, headers = ?REQUEST_HEADERS(?HASHCASH_UA)}),
    BadHashcashResponse = util_http:return_400(wrong_hashcash_solution),
    ?assertEqual(BadHashcashResponse, Response),

    HashcashRequestData = jiffy:encode({[{<<"country_code">>, ?CC1}]}),
    HashcashResponse = mod_halloapp_http_api:process(?REQUEST_HASHCASH_PATH,
        #request{method = 'POST', data = HashcashRequestData, ip = ?IP,
            headers = ?REQUEST_HEADERS(?HASHCASH_UA)}),
    {200, ?HEADER(?CT_JSON), JsonResponse} = HashcashResponse,
    DecodeJson = jiffy:decode(JsonResponse, [return_maps]),
    Challenge = maps:get(<<"hashcash_challenge">>, DecodeJson, <<>>),
    <<"H:", _Rem/binary>> = Challenge,

    Solution = util_hashcash:solve_challenge(Challenge),
    Data2 = jiffy:encode({[{<<"phone">>, ?TEST_PHONE}, {<<"hashcash_solution">>, Solution}]}),
    Response2 = mod_halloapp_http_api:process(?REQUEST_OTP_PATH,
        #request{method = 'POST', data = Data2, ip = ?IP, headers = ?REQUEST_HEADERS(?HASHCASH_UA)}),
    GoodResponse = {200, ?HEADER(?CT_JSON),
        jiffy:encode({[
            {phone, ?TEST_PHONE},
            {retry_after_secs, 30},
            {result, ok}
        ]})},
    ?assertEqual(GoodResponse, Response2),
    ?assertEqual(1, collect(?TEST_PHONE, 250, 1)),
    ?assert(meck:called(mod_sms, request_otp, [?TEST_PHONE,'_','_','_'])),
    meck_finish(mod_sms),
    meck_finish(ejabberd_router).


% TODO: this a bad test. It changes the environment to prod :( Bad things can happen.
% TODO: Also a bad test because it has 1 second sleep.
backoff_test() ->
    setup(),
    meck_init(ejabberd_router, is_my_host, fun(_) -> true end),
    meck_init(config, get_hallo_env, fun() -> prod end),
    meck_init(otp_checker_protocol, check_otp_request, fun(_,_,_,_,_,_) -> ok end),
    Data = jsx:encode([{<<"phone">>, ?TEST_PHONE}]),
    ok = model_accounts:create_account(?UID, ?PHONE, ?NAME, ?UA, 16175550000),
    ok = model_invites:record_invite(?UID, ?TEST_PHONE, 4),
    {ok, AttemptId1, _} = model_phone:add_sms_code2(?TEST_PHONE, ?SMS_CODE),
    ok = model_phone:add_gateway_response(?TEST_PHONE, AttemptId1,
        #gateway_response{gateway = gw1, gateway_id = <<"gw1">>, status = sent}),
    BadResponse = {400, ?HEADER(?CT_JSON),
        jiffy:encode({[
            {phone, ?TEST_PHONE},
            {retry_after_secs, 30},
            {error, retried_too_soon},
            {result, fail}
        ]})},
    Response = mod_halloapp_http_api:process(?REQUEST_OTP_PATH,
        #request{method = 'POST', data = Data, ip = ?IP, headers = ?REQUEST_HEADERS(?UA)}),
    ?assertEqual(BadResponse, Response),
    %% Sleep for 1 seconds so the timestamp for Attempt1 and Attempt2 is different.
    timer:sleep(timer:seconds(1)),
    {ok, AttemptId2, _} = model_phone:add_sms_code2(?TEST_PHONE, ?SMS_CODE),
    ok = model_phone:add_gateway_response(?TEST_PHONE, AttemptId2,
        #gateway_response{gateway = gw2, gateway_id = <<"gw2">>, status = sent}),
    BadResponse2 = {400, ?HEADER(?CT_JSON),
        jiffy:encode({[
            {phone, ?TEST_PHONE},
            {retry_after_secs, 60},
            {error, retried_too_soon},
            {result, fail}
        ]})},
    Response2 = mod_halloapp_http_api:process(?REQUEST_OTP_PATH,
        #request{method = 'POST', data = Data, ip = ?IP, headers = ?REQUEST_HEADERS(?UA)}),
    ?assertEqual(BadResponse2, Response2),
    meck_finish(otp_checker_protocol),
    meck_finish(config),
    meck_finish(ejabberd_router).

% when gateways fail (sms_fail), check that users can still make requests
% without having to wait (avoid retired_too_soon error)
retried_server_error_test() ->
    setup(),
    meck_init(ejabberd_router, is_my_host, fun(_) -> true end),
    meck_init(config, get_hallo_env, fun() -> prod end),
    ErrMsg = {error, sms_fail, no_retry},
    % only meck network requests
    meck_init(mbird, send_sms, fun(_,_,_,_) -> ErrMsg end),
    meck_init(twilio, send_sms, fun(_,_,_,_) -> ErrMsg end),
    meck_init(twilio_verify, send_sms, fun(_,_,_,_) -> ErrMsg end),
    meck_init(mbird_verify, send_sms, fun(_,_,_,_) -> ErrMsg end),
    meck_init(otp_checker_protocol, check_otp_request, fun(_,_,_,_,_,_) -> ok end),
    Data = jsx:encode([{<<"phone">>, ?TEST_PHONE}]),
    ok = model_accounts:create_account(?UID, ?PHONE, ?NAME, ?UA, 16175550000),
    ok = model_invites:record_invite(?UID, ?TEST_PHONE, 4),
    ServerBadResponse = {400, ?HEADER(?CT_JSON),
        jiffy:encode({[
            {result, fail},
            {error, otp_fail}
        ]})},
    Response = mod_halloapp_http_api:process(?REQUEST_OTP_PATH,
        #request{method = 'POST', data = Data, ip = ?IP, headers = ?REQUEST_HEADERS(?UA)}),
    ?assertEqual(ServerBadResponse, Response),
    Response2 = mod_halloapp_http_api:process(?REQUEST_OTP_PATH,
        #request{method = 'POST', data = Data, ip = ?IP, headers = ?REQUEST_HEADERS(?UA)}),
    ?assertEqual(ServerBadResponse, Response2),
    meck_finish(otp_checker_protocol),
    meck_finish(mbird),
    meck_finish(twilio),
    meck_finish(twilio_verify),
    meck_finish(mbird_verify),
    meck_finish(config),
    meck_finish(ejabberd_router).


request_sms_test_phone_test() ->
    setup(),
    meck_init(ejabberd_router, is_my_host, fun(_) -> true end),
    meck_init(otp_checker_protocol, check_otp_request, fun(_,_,_,_,_,_) -> ok end),
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
    ?assertEqual(GoodResponse, mod_halloapp_http_api:process(?REQUEST_OTP_PATH,
        #request{method = 'POST', data = Data, ip = ?IP, headers = ?REQUEST_HEADERS(?UA)})),
%%    ?assert(meck:called(stat, count, ["HA/account", "request_sms_errors", 1,
%%        [{error, not_invited}]])),
    meck_finish(stat),
    meck_finish(otp_checker_protocol),
    meck_finish(ejabberd_router).


register_spub_test() ->
    setup(),
    meck_init(ejabberd_router, is_my_host, fun(_) -> true end),
    meck_init(ejabberd_sm, kick_user, fun(_, _) -> 1 end),
    meck_init(stat, count, fun(_,_,_,_) -> 1 end),
    meck_init(twilio_verify, send_feedback, fun(_,_) -> ok end),
    meck_init(otp_checker_protocol, check_otp_request, fun(_,_,_,_,_,_) -> ok end),
    Data = jsx:encode([{<<"phone">>, ?TEST_PHONE}]),
    ok = model_invites:record_invite(?UID, ?TEST_PHONE, 4),
    %% Request1
    mod_halloapp_http_api:process(?REQUEST_OTP_PATH,
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
    %% Request2
    mod_halloapp_http_api:process(?REQUEST_OTP_PATH,
        #request{method = 'POST', data = Data, ip = ?IP, headers = ?REQUEST_HEADERS(?UA)}),
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
    %% Request3
    mod_halloapp_http_api:process(?REQUEST_OTP_PATH,
        #request{method = 'POST', data = Data, ip = ?IP, headers = ?REQUEST_HEADERS(?UA)}),
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
    meck_finish(otp_checker_protocol),
    meck_finish(twilio_verify),
    meck_finish(ejabberd_sm),
    meck_finish(ejabberd_router).


register_push_token_test() ->
    setup(),
    meck_init(ejabberd_router, is_my_host, fun(_) -> true end),
    meck_init(ejabberd_sm, kick_user, fun(_, _) -> 1 end),
    meck_init(otp_checker_protocol, check_otp_request, fun(_,_,_,_,_,_) -> ok end),
    Data = jsx:encode([{<<"phone">>, ?TEST_PHONE}]),
    ok = model_invites:record_invite(?UID, ?TEST_PHONE, 4),
    %% Request1
    mod_halloapp_http_api:process(?REQUEST_OTP_PATH,
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
    %% Request2
    mod_halloapp_http_api:process(?REQUEST_OTP_PATH,
        #request{method = 'POST', data = Data, ip = ?IP, headers = ?REQUEST_HEADERS(?UA)}),
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
    meck_finish(otp_checker_protocol),
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


request_and_check_sms_code_test() ->
    setup(),
    meck_init(ejabberd_router, is_my_host, fun(_) -> true end),
    meck_init(twilio_verify, send_feedback, fun(_,_) -> ok end),
    ?assertError(wrong_sms_code, mod_halloapp_http_api:check_sms_code(?TEST_PHONE, ?IP1, noise, ?SMS_CODE)),
    {ok, _} = mod_sms:request_sms(?TEST_PHONE, ?UA),
    ?assertError(wrong_sms_code, mod_halloapp_http_api:check_sms_code(?TEST_PHONE, ?IP1, noise, ?BAD_SMS_CODE)),
    ?assertEqual(ok, mod_halloapp_http_api:check_sms_code(?TEST_PHONE, ?IP1, noise, ?SMS_CODE)),
    meck_finish(twilio_verify),
    meck_finish(ejabberd_router).


check_empty_inviter_list_test() ->
    setup(),
    ?assertEqual({ok, 30}, mod_sms:send_otp_to_inviter(?TEST_PHONE, undefined, undefined, undefined)),
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

