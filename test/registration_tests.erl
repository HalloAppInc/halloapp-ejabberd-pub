%%%-----------------------------------------------------------------------------------
%%% @author nikola
%%% @copyright (C) 2021, Halloapp Inc.
%%% @doc
%%% Includes tests for registration using noise.
%%% - successful registration on multiple noise connections for request_otp and verify_otp
%%% - failure cases with invalid phone number, bad user agent and wrong smscode.
%%%
%%% @end
%%% Created : 09. Mar 2021 4:38 PM
%%%-----------------------------------------------------------------------------------
-module(registration_tests).
-author("nikola").

-compile(export_all).
-include("suite.hrl").
-include("sms.hrl").
-include("packets.hrl").
-include("account_test_data.hrl").
-include_lib("stdlib/include/assert.hrl").
-include_lib("eunit/include/eunit.hrl").

-define(PHONE10, <<"12065550010">>).
-define(PHONE11, <<"12065550011">>).
-define(NAME10, <<"Elon Musk10">>).
-define(NAME11, <<"Elon Musk11">>).

%% Noise related definitions.
-define(CURVE_KEY_TYPE, dh25519).
-record(kp,
{
    type :: atom(),
    sec  :: binary(),
    pub  :: binary()
}).

group() ->
    {registration, [sequence], [
        registration_request_sms_test,
        registration_request_sms_fail_test,
        registration_register_fail_test,
        registration_register_test,
        registration_request_and_verify_otp_noise_test,
        registration_request_and_verify_otp_noise2_test,
        registration_request_otp_noise_invalid_phone_fail_test,
        registration_request_otp_noise_bad_request_fail_test,
        registration_verify_otp_fail_noise_test
    ]}.

request_sms_test(_Conf) ->
    {ok, Resp} = registration_client:request_sms(?PHONE10),
    ct:pal("~p", [Resp]),
    #{
        <<"phone">> := ?PHONE10,
        <<"retry_after_secs">> := 30,
        <<"result">> := <<"ok">>
    } = Resp,
    ok.

request_sms_fail_test(_Conf) ->
%%    % use some random non-test number, get not_invited
%%    {error, {400, Resp}} = registration_client:request_sms(<<12066580001>>),
%%    ct:pal("~p", [Resp]),
%%    #{
%%        <<"result">> := <<"fail">>,
%%        <<"error">> := <<"not_invited">>
%%    } = Resp,

    % use some random non-test number, get bad_request
    {error, {400, Resp2}} = registration_client:request_sms(<<"12066580001">>, #{user_agent => "BadUserAgent/1.0"}),
    ct:pal("~p", [Resp2]),
    #{
        <<"result">> := <<"fail">>,
        <<"error">> := <<"bad_request">>
    } = Resp2,
    ok,

    % use some random non-test number, get not_invited
    {error, {400, Resp3}} = registration_client:request_sms(<<"123">>, #{user_agent => "HalloApp/iOS1.2.93"}),
    ct:pal("~p", [Resp3]),
    #{
        <<"result">> := <<"fail">>,
        <<"error">> := <<"invalid_phone_number">>
    } = Resp3,
    ok.


register_fail_test(_Conf) ->
    % try passing the wrong code
    {error, {400, Data1}} = registration_client:register(?PHONE10, <<"111112">>, ?NAME10),
    ct:pal("~p", [Data1]),
    #{
        <<"result">> := <<"fail">>,
        <<"error">> := <<"wrong_sms_code">>
    } = Data1,

    % Passing bad user agent results in bad_request
    {error, {400, Data2}} = registration_client:register(?PHONE10, <<"111111">>, ?NAME10,
        #{user_agent => "BadUserAgent/1.0"}),
    ct:pal("~p", [Data2]),
    #{
        <<"result">> := <<"fail">>,
        <<"error">> := <<"bad_request">>
    } = Data2,

    % Passing invalid name.
    {error, {400, Data3}} = registration_client:register(?PHONE10, <<"111111">>, <<>>),
    ct:pal("~p", [Data3]),
    #{
        <<"result">> := <<"fail">>,
        <<"error">> := <<"invalid_name">>
    } = Data3,
    ok.


register_test(_Conf) ->
    registration_client:request_sms(?PHONE10, #{}),
    {ok, Uid, _ClientKeyPair, Data} = registration_client:register(?PHONE10, <<"111111">>, ?NAME10),
    ct:pal("~p", [Data]),
    #{
        <<"name">> := ?NAME10,
        <<"phone">> := ?PHONE10,
        <<"result">> := <<"ok">>
    } = Data,
    ?assertEqual(true, model_accounts:account_exists(Uid)),
    ?assertEqual({ok, ?NAME10}, model_accounts:get_name(Uid)),
    ok.


%% request_otp and verify_otp on the same connection.
request_and_verify_otp_noise_test(_Conf) ->
    Phone = ?PHONE10,
    Name = ?NAME10,

    %% Compose RequestOtp
    RequestOtpOptions = #{},
    {ok, RegisterRequestPkt} = registration_client:compose_otp_noise_request(Phone, RequestOtpOptions),

    %% Generate NoiseKeys.
    KeyPair = ha_enoise:generate_signature_keypair(),
    {SEdSecret, SEdPub} = {maps:get(secret, KeyPair), maps:get(public, KeyPair)},
    %% Convert these signing keys to curve keys.
    {CurveSecret, CurvePub} = {enacl:crypto_sign_ed25519_secret_to_curve25519(maps:get(secret, KeyPair)),
     enacl:crypto_sign_ed25519_public_to_curve25519(maps:get(public, KeyPair))},
    %% TODO: move this code to have an api for these keys.
    ClientKeyPair = #kp{type = ?CURVE_KEY_TYPE, sec = CurveSecret, pub = CurvePub},
    SignedMessage = enacl:sign("HALLO", SEdSecret),
    % SEdPubEncoded = base64:encode(SEdPub),
    % SignedMessageEncoded = base64:encode(SignedMessage),

    %% Connect and requestOtp
    ConnectOptions = #{host => "localhost", port => 5208, state => register},
    {ok, Client, ActualResponse} = ha_client:connect_and_send(RegisterRequestPkt, ClientKeyPair, ConnectOptions),

    %% Check result.
    ExpectedResponse = #pb_register_response{
        response = #pb_otp_response{
            phone = Phone,
            result = success,
            reason = unknown_reason,
            retry_after_secs = 30
    }},
    % ?debugFmt("response: ~p", [ActualResponse]),
    ?assertEqual(ExpectedResponse, ActualResponse),

    %% Compose VerifyOtpRequest
    OtpCode = case model_phone:get_all_verification_info(Phone) of
        {ok, []} -> undefined;
        {ok, [#verification_info{code = Code} | _]} -> Code
    end,
    VerifyOtpOptions = #{name => Name, static_key => SEdPub, signed_phrase => SignedMessage},
    {ok, VerifyOtpRequestPkt} = registration_client:compose_verify_otp_noise_request(Phone, OtpCode, VerifyOtpOptions),

    %% Send verify_otp request on the same connection.
    ok = ha_client:send(Client, enif_protobuf:encode(VerifyOtpRequestPkt)),
    ActualResponse2 = ha_client:recv(Client),

    %% Check result.
    % ?debugFmt("response2: ~p", [ActualResponse2]),
    Response2 = ActualResponse2#pb_register_response.response,
    ?assertEqual(Phone, Response2#pb_verify_otp_response.phone),
    ?assertEqual(success, Response2#pb_verify_otp_response.result),
    ?assertEqual(Name, Response2#pb_verify_otp_response.name),
    ok.


%% request_otp and verify_otp on different connections.
request_and_verify_otp_noise2_test(_Conf) ->
    Phone = ?PHONE11,
    Name = ?NAME11,

    %% Compose RequestOtp
    RequestOtpOptions = #{},
    {ok, RegisterRequestPkt} = registration_client:compose_otp_noise_request(Phone, RequestOtpOptions),

    %% Generate NoiseKeys.
    KeyPair = ha_enoise:generate_signature_keypair(),
    {SEdSecret, SEdPub} = {maps:get(secret, KeyPair), maps:get(public, KeyPair)},
    %% Convert these signing keys to curve keys.
    {CurveSecret, CurvePub} = {enacl:crypto_sign_ed25519_secret_to_curve25519(maps:get(secret, KeyPair)),
     enacl:crypto_sign_ed25519_public_to_curve25519(maps:get(public, KeyPair))},
    %% TODO: move this code to have an api for these keys.
    ClientKeyPair = #kp{type = ?CURVE_KEY_TYPE, sec = CurveSecret, pub = CurvePub},
    SignedMessage = enacl:sign("HALLO", SEdSecret),
    % SEdPubEncoded = base64:encode(SEdPub),
    % SignedMessageEncoded = base64:encode(SignedMessage),

    %% Connect and requestOtp
    ConnectOptions = #{host => "localhost", port => 5208, state => register},
    {ok, Client, ActualResponse} = ha_client:connect_and_send(RegisterRequestPkt, ClientKeyPair, ConnectOptions),

    %% Check result.
    ExpectedResponse = #pb_register_response{
        response = #pb_otp_response{
            phone = Phone,
            result = success,
            reason = unknown_reason,
            retry_after_secs = 30
    }},
    % ?debugFmt("response: ~p", [ActualResponse]),
    ?assertEqual(ExpectedResponse, ActualResponse),

    %% Disconnect client.
    ha_client:stop(Client),

    %% Compose VerifyOtpRequest
    OtpCode = case model_phone:get_all_verification_info(Phone) of
        {ok, []} -> undefined;
        {ok, [#verification_info{code = Code} | _]} -> Code
    end,
    VerifyOtpOptions = #{name => Name, static_key => SEdPub, signed_phrase => SignedMessage},
    {ok, VerifyOtpRequestPkt} = registration_client:compose_verify_otp_noise_request(Phone, OtpCode, VerifyOtpOptions),

    %% Send verify_otp request on a different connection.
    {ok, Client2, ActualResponse2} = ha_client:connect_and_send(VerifyOtpRequestPkt, ClientKeyPair, ConnectOptions),

    %% Check result.
    % ?debugFmt("response2: ~p", [ActualResponse2]),
    Response2 = ActualResponse2#pb_register_response.response,
    ?assertEqual(Phone, Response2#pb_verify_otp_response.phone),
    ?assertEqual(success, Response2#pb_verify_otp_response.result),
    ?assertEqual(Name, Response2#pb_verify_otp_response.name),
    ok.


request_otp_noise_invalid_phone_fail_test(_Conf) ->
    Phone = <<"14055887">>,
    Name = ?NAME11,

    %% Compose RequestOtp - invalid phonenumber
    RequestOtpOptions = #{},
    {ok, RegisterRequestPkt} = registration_client:compose_otp_noise_request(Phone, RequestOtpOptions),

    %% Generate NoiseKeys.
    KeyPair = ha_enoise:generate_signature_keypair(),
    {SEdSecret, SEdPub} = {maps:get(secret, KeyPair), maps:get(public, KeyPair)},
    %% Convert these signing keys to curve keys.
    {CurveSecret, CurvePub} = {enacl:crypto_sign_ed25519_secret_to_curve25519(maps:get(secret, KeyPair)),
     enacl:crypto_sign_ed25519_public_to_curve25519(maps:get(public, KeyPair))},
    %% TODO: move this code to have an api for these keys.
    ClientKeyPair = #kp{type = ?CURVE_KEY_TYPE, sec = CurveSecret, pub = CurvePub},

    %% Connect and requestOtp - should fail because of invalid phonenumber.
    ConnectOptions = #{host => "localhost", port => 5208, state => register},
    {ok, Client, ActualResponse} = ha_client:connect_and_send(RegisterRequestPkt, ClientKeyPair, ConnectOptions),

    %% Check result.
    ExpectedResponse = #pb_register_response{
        response = #pb_otp_response{
            result = failure,
            reason = invalid_phone_number
    }},
    % ?debugFmt("response: ~p", [ActualResponse]),
    ?assertEqual(ExpectedResponse, ActualResponse),
    ok.


request_otp_noise_bad_request_fail_test(_Conf) ->
    Phone = ?PHONE11,
    Name = ?NAME11,

    %% Compose RequestOtp - bad useragent
    RequestOtpOptions = #{user_agent => <<"BadUserAgent/1.0">>},
    {ok, RegisterRequestPkt} = registration_client:compose_otp_noise_request(Phone, RequestOtpOptions),

    %% Generate NoiseKeys.
    KeyPair = ha_enoise:generate_signature_keypair(),
    {SEdSecret, SEdPub} = {maps:get(secret, KeyPair), maps:get(public, KeyPair)},
    %% Convert these signing keys to curve keys.
    {CurveSecret, CurvePub} = {enacl:crypto_sign_ed25519_secret_to_curve25519(maps:get(secret, KeyPair)),
     enacl:crypto_sign_ed25519_public_to_curve25519(maps:get(public, KeyPair))},
    %% TODO: move this code to have an api for these keys.
    ClientKeyPair = #kp{type = ?CURVE_KEY_TYPE, sec = CurveSecret, pub = CurvePub},

    %% Connect and requestOtp - should fail because of bad useragent.
    ConnectOptions = #{host => "localhost", port => 5208, state => register},
    {ok, Client, ActualResponse} = ha_client:connect_and_send(RegisterRequestPkt, ClientKeyPair, ConnectOptions),

    %% Check result - bad useragent request - so should fail.
    ExpectedResponse = #pb_register_response{
        response = #pb_otp_response{
            result = failure,
            reason = bad_request
    }},
    % ?debugFmt("response: ~p", [ActualResponse]),
    ?assertEqual(ExpectedResponse, ActualResponse),
    ok.


verify_otp_fail_noise_test(_Conf) ->
    Phone = ?PHONE11,
    Name = ?NAME11,

    %% Compose RequestOtp
    RequestOtpOptions = #{},
    {ok, RegisterRequestPkt} = registration_client:compose_otp_noise_request(Phone, RequestOtpOptions),

    %% Generate NoiseKeys.
    KeyPair = ha_enoise:generate_signature_keypair(),
    {SEdSecret, SEdPub} = {maps:get(secret, KeyPair), maps:get(public, KeyPair)},
    %% Convert these signing keys to curve keys.
    {CurveSecret, CurvePub} = {enacl:crypto_sign_ed25519_secret_to_curve25519(maps:get(secret, KeyPair)),
     enacl:crypto_sign_ed25519_public_to_curve25519(maps:get(public, KeyPair))},
    %% TODO: move this code to have an api for these keys.
    ClientKeyPair = #kp{type = ?CURVE_KEY_TYPE, sec = CurveSecret, pub = CurvePub},
    SignedMessage = enacl:sign("HALLO", SEdSecret),

    %% Connect and requestOtp
    ConnectOptions = #{host => "localhost", port => 5208, state => register},
    {ok, Client, ActualResponse} = ha_client:connect_and_send(RegisterRequestPkt, ClientKeyPair, ConnectOptions),
    %% Disconnect client.
    ha_client:stop(Client),

    %% Check result.
    ExpectedResponse = #pb_register_response{
        response = #pb_otp_response{
            phone = Phone,
            result = success,
            reason = unknown,
            retry_after_secs = 30
    }},
    ?debugFmt("response: ~p", [ActualResponse]),
    ?assertEqual(ExpectedResponse, ActualResponse),

    %% Compose VerifyOtpRequest
    VerifyOtpOptions = #{name => Name, static_key => SEdPub, signed_phrase => SignedMessage},
    {ok, VerifyOtpRequestPkt} = registration_client:compose_verify_otp_noise_request(Phone, <<"123">>, VerifyOtpOptions),

    %% Send verify_otp request on a different connection.
    {ok, Client2, ActualResponse2} = ha_client:connect_and_send(VerifyOtpRequestPkt, ClientKeyPair, ConnectOptions),

    %% Check result.
    % ?debugFmt("response2: ~p", [ActualResponse2]),
    Response2 = ActualResponse2#pb_register_response.response,
    ?assertEqual(failure, Response2#pb_verify_otp_response.result),
    ?assertEqual(wrong_sms_code, Response2#pb_verify_otp_response.reason),

    VerifyOtpOptions2 = #{name => Name, static_key => SEdPub, signed_phrase => <<>>},
    OtpCode = case model_phone:get_all_verification_info(Phone) of
        {ok, []} -> undefined;
        {ok, [#verification_info{code = Code} | _]} -> Code
    end,
    {ok, VerifyOtpRequestPkt2} = registration_client:compose_verify_otp_noise_request(Phone, OtpCode, VerifyOtpOptions2),

    %% Send verify_otp request on the same connection.
    ok = ha_client:send(Client2, enif_protobuf:encode(VerifyOtpRequestPkt2)),
    ActualResponse3 = ha_client:recv(Client2),
    %% Check result.
    ?debugFmt("response3: ~p", [ActualResponse3]),
    Response3 = ActualResponse3#pb_register_response.response,
    ?assertEqual(failure, Response3#pb_verify_otp_response.result),
    ?assertEqual(unable_to_open_signed_phrase, Response3#pb_verify_otp_response.reason),
    ok.

%% TODO(murali@): add different failure cases in tests.
%% TODO(murali@): use IK handshake as well - extend ha_client to perform IK handshake.

