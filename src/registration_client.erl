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

-define(DEFAULT_UA, "HalloApp/Android1.130").
-define(DEFAULT_HOST, "localhost").
-define(DEFAULT_PORT, "5580").

-define(IDENTITY_KEY, <<"ZGFkc2FkYXNma2xqc2RsZmtqYXNkbGtmamFzZGxrZmphc2xrZGZqYXNsO2tkCgo=">>).
-define(SIGNED_KEY, <<"Tmlrb2xhIHdyb3RlIHRoaXMgbmljZSBtZXNzYWdlIG1ha2luZyBzdXJlIGl0IGlzIGxvbmcgCg==">>).
-define(ONE_TIME_KEY, <<"VGhpcyBpcyBvbmUgdGltZSBrZXkgZm9yIHRlc3RzIHRoYXQgaXMgbG9uZwo=">>).

%% API
-export([
    request_sms/1,
    request_sms/2,
    register/3,
    register/4
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
    Body = jiffy:encode(#{<<"phone">> => Phone}),
    UA = maps:get(user_agent, Options, ?DEFAULT_UA),
    Headers = [{"user-agent", UA}],
    Host = maps:get(host, Options, ?DEFAULT_HOST),
    Port = maps:get(port, Options, ?DEFAULT_PORT),
    Protocol = get_http_protocol(),
    Request = {Protocol ++ Host ++ ":" ++ Port ++"/api/registration/request_sms", Headers, "application/json", Body},
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
        <<"one_time_keys">> => [?ONE_TIME_KEY, ?ONE_TIME_KEY, ?ONE_TIME_KEY, ?ONE_TIME_KEY,
            ?ONE_TIME_KEY, ?ONE_TIME_KEY, ?ONE_TIME_KEY, ?ONE_TIME_KEY, ?ONE_TIME_KEY, ?ONE_TIME_KEY]
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
