%%%-------------------------------------------------------------------
%%% @copyright (C) 2020, HalloApp, Inc.
%%% @doc
%%%
%%% @end
%%%-------------------------------------------------------------------
-module(mod_sms_callback_tests).
-author("vipin").

-include("util_http.hrl").
-include("ejabberd_http.hrl").
-include_lib("eunit/include/eunit.hrl").

-define(PHONE, <<"14703381473">>).
-define(TEST_PHONE, <<"16175550000">>).
-define(UA, <<"HalloApp/iPhone1.0">>).

-define(TWILIO_CALLBACK_PATH, [<<"twilio">>]).
-define(TWILIO_CALLBACK_DATA(From, To, Status),
    jsx:encode([{<<"from">>, From}, {<<"to">>, To}, {<<"status">>, Status}])).
-define(TWILIO_CALLBACK_HEADERS(UA), [
    {'Content-Type',<<"application/x-www-form-urlencoded">>},
    {'Accept',<<"*/*">>},
    {'User-Agent',UA}]).
    %% TODO(vipin): Incoroporate Twilio Signature.
    %% {'X-Twilio-Signature', <<"4m6Gt5Y9LmNtpKjQ5Wj0iP73tiXPYDMtM2uHrgpFKCQ=">>}]).

-define(MBIRD_CALLBACK_PATH, [<<"mbird">>]).
-define(MBIRD_CALLBACK_QS(To, Status), [{"recipient", To}, {"status", Status}]).
-define(MBIRD_CALLBACK_HEADERS(UA), [
    {'Content-Type',<<"application/x-www-form-urlencoded">>},
    {'Accept',<<"*/*">>},
    {'User-Agent',UA},
    {'MessageBird-Signature', <<"4m6Gt5Y9LmNtpKjQ5Wj0iP73tiXPYDMtM2uHrgpFKCQ=">>},
    {'MessageBird-Timestamp', calendar:system_time_to_rfc3339(erlang:system_time(second))}]).

%%%----------------------------------------------------------------------

twilio_callback_test() ->
    setup(),
    Data = ?TWILIO_CALLBACK_DATA(?TEST_PHONE, ?PHONE, "delivered"),
    {200, ?HEADER(?CT_JSON), Info} = mod_sms_callback:process(?TWILIO_CALLBACK_PATH,
        #request{method = 'POST', data = Data, headers = ?TWILIO_CALLBACK_HEADERS(?UA)}),
    [{<<"result">>, <<"ok">>}] = jsx:decode(Info).

mbird_callback_test() ->
    setup(),
    Q = ?MBIRD_CALLBACK_QS(binary_to_list(?PHONE), "delivered"),
    {200, ?HEADER(?CT_JSON), Info} = mod_sms_callback:process(?MBIRD_CALLBACK_PATH,
        #request{method = 'GET', q = Q, headers = ?MBIRD_CALLBACK_HEADERS(?UA)}),
    [{<<"result">>, <<"ok">>}] = jsx:decode(Info).

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


