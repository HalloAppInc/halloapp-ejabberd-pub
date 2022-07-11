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

-define(DEFAULT_UA, "HalloApp/Android1.180").
-define(DEFAULT_HOST, "localhost").
-define(DEFAULT_PORT, "5580").

-define(IDENTITY_KEY, <<"ZGFkc2FkYXNma2xqc2RsZmtqYXNkbGtmamFzZGxrZmphc2xrZGZqYXNsO2tkCgo=">>).
-define(SIGNED_KEY, <<"Tmlrb2xhIHdyb3RlIHRoaXMgbmljZSBtZXNzYWdlIG1ha2luZyBzdXJlIGl0IGlzIGxvbmcgCg==">>).
-define(ONE_TIME_KEY, <<"VGhpcyBpcyBvbmUgdGltZSBrZXkgZm9yIHRlc3RzIHRoYXQgaXMgbG9uZwo=">>).
-define(ONE_TIME_KEYS, [?ONE_TIME_KEY, ?ONE_TIME_KEY, ?ONE_TIME_KEY, ?ONE_TIME_KEY, ?ONE_TIME_KEY,
        ?ONE_TIME_KEY, ?ONE_TIME_KEY, ?ONE_TIME_KEY, ?ONE_TIME_KEY, ?ONE_TIME_KEY]).

%% API
-export([
    request_sms/1,
    request_sms/2,
    register/3,
    register/4,
    compose_otp_noise_request/2,
    compose_verify_otp_noise_request/3
]).

%% Noise related definitions.
-define(CURVE_KEY_TYPE, dh25519).
-record(kp,
{
    type :: atom(),
    sec  :: binary(),
    pub  :: binary()
}).


setup() ->
    application:ensure_started(inets).


-spec request_sms(Phone :: phone()) -> {ok, map()} | {error, term()}.
request_sms(Phone) ->
    request_sms(Phone, #{}).


-spec request_sms(Phone :: phone(), Options :: map()) -> {ok, map()} | {error, term()}.
request_sms(Phone, Options) ->
    setup(),
    HashcashChallenge = mod_halloapp_http_api:create_hashcash_challenge(<<>>, <<>>),
    HashcashSolution = util_hashcash:solve_challenge(HashcashChallenge),
    Body = jiffy:encode(#{<<"phone">> => Phone, <<"hashcash_solution">> => HashcashSolution}),
    UA = maps:get(user_agent, Options, ?DEFAULT_UA),
    Headers = [{"user-agent", UA}],
    Host = maps:get(host, Options, ?DEFAULT_HOST),
    Port = maps:get(port, Options, ?DEFAULT_PORT),
    Protocol = get_http_protocol(),
    Request = {Protocol ++ Host ++ ":" ++ Port ++"/api/registration/request_otp", Headers, "application/json", Body},
    {ok, Response} = httpc:request(post, Request, [{timeout, 30000}], []),
    case Response of
        {{_, 200, _}, _ResHeaders, ResponseBody} ->
            ResData = jiffy:decode(ResponseBody, [return_maps]),
            {ok, ResData};
        {{_, HTTPCode, _}, _ResHeaders, ResponseBody} ->
            ResData = jiffy:decode(ResponseBody, [return_maps]),
            {error, {HTTPCode, ResData}}
    end.

-spec register(Phone :: phone(), Code :: binary(), Name :: binary())
            -> {ok, Uid :: uid(), Password :: binary(), Response :: map()} | {error, term()}.
register(Phone, Code, Name) ->
    register(Phone, Code, Name, #{}).

-spec register(Phone :: phone(), Code :: binary(), Name :: binary(), Options :: map())
            -> {ok, Uid :: uid(), Password :: binary(), Response :: map()} | {error, term()}.
register(Phone, Code, Name, Options) ->
    setup(),
    %% TODO: tests should generate these keys.
    KeyPair = ha_enoise:generate_signature_keypair(),
    {SEdSecret, SEdPub} = {maps:get(secret, KeyPair), maps:get(public, KeyPair)},

    %% Convert these signing keys to curve keys.
    {CurveSecret, CurvePub} = {enacl:crypto_sign_ed25519_secret_to_curve25519(maps:get(secret, KeyPair)),
     enacl:crypto_sign_ed25519_public_to_curve25519(maps:get(public, KeyPair))},
    %% TODO: move this code to have an api for these keys.
    ClientKeyPair = #kp{type = ?CURVE_KEY_TYPE, sec = CurveSecret, pub = CurvePub},

    SignedMessage = enacl:sign("HALLO", SEdSecret),
    SEdPubEncoded = base64:encode(SEdPub),
    SignedMessageEncoded = base64:encode(SignedMessage),
    Body = jiffy:encode(#{
        <<"phone">> => Phone,
        <<"code">> => Code,
        <<"name">> => Name,
        <<"s_ed_pub">> => SEdPubEncoded,
        <<"signed_phrase">> => SignedMessageEncoded,
        % TODO: add support for whisper keys - autogenerate keys here.
        <<"identity_key">> => ?IDENTITY_KEY,
        <<"signed_key">> => ?SIGNED_KEY,
        <<"one_time_keys">> => ?ONE_TIME_KEYS
    }),

    UA = maps:get(user_agent, Options, ?DEFAULT_UA),
    Headers = [{"user-agent", UA}],
    Host = maps:get(host, Options, ?DEFAULT_HOST),
    Port = maps:get(port, Options, ?DEFAULT_PORT),
    Protocol = get_http_protocol(),
    Request = {Protocol ++ Host ++ ":" ++ Port ++ "/api/registration/register2", Headers, "application/json", Body},
    {ok, Response} = httpc:request(post, Request, [{timeout, 30000}], []),
    case Response of
        {{_, 200, _}, _ResHeaders, ResponseBody} ->
            ResData = jiffy:decode(ResponseBody, [return_maps]),
            #{
                <<"uid">> := Uid,
                <<"phone">> := Phone,
                <<"result">> := <<"ok">>
            } = ResData,
            {ok, Uid, ClientKeyPair, ResData};
        {{_, HTTPCode, _}, _ResHeaders, ResponseBody} ->
            ResData = jiffy:decode(ResponseBody, [return_maps]),
            {error, {HTTPCode, ResData}}
    end.


get_http_protocol() ->
    HalloEnv = config:get_hallo_env(),
    case HalloEnv =:= test orelse HalloEnv =:= github of
        true -> "http://";
        false -> "https://"
    end.


-spec compose_otp_noise_request(Phone :: phone(), Options :: map()) -> {ok, pb_register_request()}.
compose_otp_noise_request(Phone, Options) ->
    setup(),
    HashcashChallenge = mod_halloapp_http_api:create_hashcash_challenge(<<>>, <<>>),
    HashcashSolution = util_hashcash:solve_challenge(HashcashChallenge),
    OtpRequestPkt = #pb_otp_request {
        phone = Phone,
        hashcash_solution = HashcashSolution,
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

