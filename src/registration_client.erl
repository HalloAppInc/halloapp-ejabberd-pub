%%%-------------------------------------------------------------------
%%% @author nikola
%%% @copyright (C) 2021, Halloapp Inc.
%%% @doc
%%% Registration client using HTTP API that provides interface for
%%% creating accounts
%%% @end
%%% Created : 09. Mar 2021 4:26 PM
%%%-------------------------------------------------------------------
-module(registration_client).
-author("nikola").

-include("ha_types.hrl").
-include("packets.hrl").
-include_lib("stdlib/include/assert.hrl").
-include("sms.hrl").

-define(DEFAULT_UA, "HalloApp/Android1.180").
-define(DEFAULT_HOST, "localhost").
-define(DEFAULT_PORT, "5580").

-define(IDENTITY_KEY, <<"ZGFkc2FkYXNma2xqc2RsZmtqYXNkbGtmamFzZGxrZmphc2xrZGZqYXNsO2tkCgo=">>).
-define(SIGNED_KEY, <<"Tmlrb2xhIHdyb3RlIHRoaXMgbmljZSBtZXNzYWdlIG1ha2luZyBzdXJlIGl0IGlzIGxvbmcgCg==">>).
-define(ONE_TIME_KEY, <<"VGhpcyBpcyBvbmUgdGltZSBrZXkgZm9yIHRlc3RzIHRoYXQgaXMgbG9uZwo=">>).
-define(ONE_TIME_KEYS, [?ONE_TIME_KEY, ?ONE_TIME_KEY, ?ONE_TIME_KEY, ?ONE_TIME_KEY, ?ONE_TIME_KEY,
        ?ONE_TIME_KEY, ?ONE_TIME_KEY, ?ONE_TIME_KEY, ?ONE_TIME_KEY, ?ONE_TIME_KEY]).
-define(CURVE_KEY_TYPE, dh25519).


-record(kp,
{
    type :: atom(),
    sec  :: binary(),
    pub  :: binary()
}).


%% API
-export([
    compose_hashcash_noise_request/0,
    compose_otp_noise_request/2,
    compose_verify_otp_noise_request/3,
    request_sms/2,
    register/4,
    hashcash_register/3
]).


setup() ->
    application:ensure_started(halloapp_register).

-spec request_sms(Phone :: phone(), Options :: map()) -> {ok, pb_register_response()}.
request_sms(Phone, Options) ->
    setup(),
    {ok, RegisterRequestPkt} = compose_otp_noise_request(Phone, Options),

    %% Generate NoiseKeys.
    KeyPair = ha_enoise:generate_signature_keypair(),
    %% Convert these signing keys to curve keys.
    {CurveSecret, CurvePub} = {enacl:crypto_sign_ed25519_secret_to_curve25519(maps:get(secret, KeyPair)),
     enacl:crypto_sign_ed25519_public_to_curve25519(maps:get(public, KeyPair))},

    ClientKeyPair = #kp{type = ?CURVE_KEY_TYPE, sec = CurveSecret, pub = CurvePub},

    %% Connect and requestOtp
    ConnectOptions = #{
        host => maps:get(host, Options, "localhost"), 
        port => 5208, 
        state => register},
    {ok, Client, ActualResponse} = ha_client:connect_and_send(RegisterRequestPkt, ClientKeyPair, ConnectOptions),

    ha_client:stop(Client),

    {ok, ActualResponse#pb_register_response.response}.

-spec register(Phone :: phone(), Code :: binary(), Name :: binary(), Options :: map()) -> {ok, pb_verify_otp_response()} | {ok, pb_verify_otp_response(), #kp{}}.
register(Phone, Code, Name, Options) ->
    setup(),
    %% Compose RequestOtp
    {ok, RegisterRequestPkt} = compose_otp_noise_request(Phone, #{}),

    %% Generate NoiseKeys.
    KeyPair = ha_enoise:generate_signature_keypair(),
    {SEdSecret, SEdPub} = {maps:get(secret, KeyPair), maps:get(public, KeyPair)},
    %% Convert these signing keys to curve keys.
    {CurveSecret, CurvePub} = {enacl:crypto_sign_ed25519_secret_to_curve25519(maps:get(secret, KeyPair)),
     enacl:crypto_sign_ed25519_public_to_curve25519(maps:get(public, KeyPair))},

    ClientKeyPair = #kp{type = ?CURVE_KEY_TYPE, sec = CurveSecret, pub = CurvePub},
    SignedMessage = enacl:sign("HALLO", SEdSecret),

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
    ?assertEqual(ExpectedResponse, ActualResponse),

    VerifyOtpOptions = #{name => Name, static_key => SEdPub, signed_phrase => SignedMessage},
    VerifyOtpOptions1 = maps:merge(Options, VerifyOtpOptions),
    {ok, VerifyOtpRequestPkt} = compose_verify_otp_noise_request(Phone, Code, VerifyOtpOptions1),

    %% Send verify_otp request on the same connection.
    ok = ha_client:send(Client, enif_protobuf:encode(VerifyOtpRequestPkt)),
    ActualResponse2 = ha_client:recv(Client),

    ha_client:stop(Client),

    %% Return result
    Response2 = ActualResponse2#pb_register_response.response,
    case maps:get(return_keypair, Options, false) of
        false -> {ok, Response2};
        true -> {ok, Response2, ClientKeyPair}
    end.


-spec hashcash_register(Name :: binary(), Phone :: binary(), Options :: map()) -> ok | {error, any()}.
hashcash_register(Name, Phone, Options) ->
    setup(),
    KeyPair = ha_enoise:generate_signature_keypair(),
    {CurveSecret, CurvePub} = {
        enacl:crypto_sign_ed25519_secret_to_curve25519(maps:get(secret, KeyPair)),
        enacl:crypto_sign_ed25519_public_to_curve25519(maps:get(public, KeyPair))},
    ClientKeyPair = {kp, dh25519, CurveSecret, CurvePub},
    Host = maps:get(host, Options, "127.0.0.1"),
    Port = maps:get(port, Options, 5208),
    ClientOptions = #{host => Host, port => Port, state => register},
    % request hashcash challenge
    {ok, HashcashRequestPkt} = compose_hashcash_noise_request(),
    case ha_client:connect_and_send(HashcashRequestPkt, ClientKeyPair, ClientOptions) of
        {error, _} = Error -> Error;
        {ok, Pid, Resp1} ->
            Result = case Resp1 of
                #pb_register_response{response = #pb_hashcash_response{hashcash_challenge = Challenge}} ->
                % ask for an otp request for the test number
                {ok, RegisterRequestPkt} = compose_otp_noise_request(Phone, #{challenge => Challenge}),
                ha_client:send(Pid, enif_protobuf:encode(RegisterRequestPkt)),
                Resp2 = ha_client:recv(Pid),
                case Resp2 of
                    #pb_register_response{response = #pb_otp_response{result = success}} ->
                        % look up otp code from redis.
                        {ok, VerifyAttempts} = model_phone:get_verification_attempt_list(Phone),
                        SortedVerifyAttempts = lists:keysort(2, VerifyAttempts),
                        {AttemptId, _TTL} = lists:last(SortedVerifyAttempts),
                        {ok, Code} = model_phone:get_sms_code2(Phone, AttemptId),
                        % verify with the code.
                        SignedMessage = enacl:sign("HALLO", maps:get(secret, KeyPair)),
                        VerifyOtpOptions = #{name => Name, static_key => maps:get(public, KeyPair), signed_phrase => SignedMessage}, 
                        {ok, VerifyOTPRequestPkt} = registration_client:compose_verify_otp_noise_request(Phone, Code, VerifyOtpOptions),
                        ha_client:send(Pid, enif_protobuf:encode(VerifyOTPRequestPkt)),
                        Resp3 = ha_client:recv(Pid),
                        case Resp3 of
                            #pb_register_response{response = #pb_verify_otp_response{result = success}} -> ok;
                            BadResp -> {error, {bad_verify_otp_response, BadResp}}
                        end;
                    BadResp -> {error, {bad_otp_response, BadResp}} 
                end;
                BadResp -> {error, {bad_hashcash_response, BadResp}}
            end,
            ha_client:stop(Pid),
            Result
    end.

-spec compose_hashcash_noise_request() -> {ok, pb_register_request()}.
compose_hashcash_noise_request() ->
    {ok, #pb_register_request{request = #pb_hashcash_request{}}}.

-spec compose_otp_noise_request(Phone :: phone(), Options :: map()) -> {ok, pb_register_request()}.
compose_otp_noise_request(Phone, Options) ->
    setup(),
    HashcashChallenge = maps:get(challenge, Options, mod_halloapp_http_api:create_hashcash_challenge(<<>>, <<>>)),
    HashcashSolution = util_hashcash:solve_challenge(HashcashChallenge),
    OtpRequestPkt = #pb_otp_request {
        phone = Phone,
        hashcash_solution = maps:get(hashcash, Options, HashcashSolution),
        method = maps:get(method, Options, sms),
        lang_id = maps:get(lang_id, Options, <<"en-US">>),
        user_agent = maps:get(user_agent, Options, ?DEFAULT_UA)
    },
    RegisterRequestPkt = #pb_register_request{
        request = OtpRequestPkt
    },
    {ok, RegisterRequestPkt}.


-spec compose_verify_otp_noise_request(Phone :: phone(), Code :: binary(),
    Options :: map()) -> {ok, pb_register_request()}.
compose_verify_otp_noise_request(Phone, Code, Options) ->
    setup(),
    VerifyOtpRequestPkt = #pb_verify_otp_request {
        phone = Phone,
        code = Code,
        name = maps:get(name, Options, undefined),
        static_key = maps:get(static_key, Options, undefined),
        signed_phrase = maps:get(signed_phrase, Options, undefined),
        identity_key = maps:get(identity_key, Options, ?IDENTITY_KEY),
        signed_key = maps:get(signed_key, Options, ?SIGNED_KEY),
        one_time_keys = maps:get(one_time_keys, Options, ?ONE_TIME_KEYS),
        user_agent = maps:get(user_agent, Options, ?DEFAULT_UA)
    },
    RegisterRequestPkt = #pb_register_request{
        request = VerifyOtpRequestPkt
    },
    {ok, RegisterRequestPkt}.

