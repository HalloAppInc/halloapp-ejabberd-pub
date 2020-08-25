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
-include("bosh.hrl").
-include("ejabberd_http.hrl").
-include_lib("eunit/include/eunit.hrl").

-define(UID, <<"1">>).
-define(PHONE, <<"16175550000">>).
-define(NAME, <<"Josh">>).
-define(SERVER, <<"s.halloapp.net">>).
-define(UA, <<"HalloApp/iPhone1.0">>).
-define(BAD_UA, <<"BadUserAgent/1.0">>).
-define(SMS_CODE, <<"111111">>).
-define(BAD_SMS_CODE, <<"111110">>).
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

%%%----------------------------------------------------------------------
%%% IQ tests
%%%----------------------------------------------------------------------

request_sms_test() ->
    setup(),
    meck_init(ejabberd_router, is_my_host, fun(_) -> true end),
    Data = jsx:encode([{<<"phone">>, ?PHONE}]),
    NotInvitedError = mod_halloapp_http_api:return_400(not_invited),
    ?assertEqual(NotInvitedError, mod_halloapp_http_api:process(?REQUEST_SMS_PATH,
        #request{method = 'POST', data = Data, headers = ?REQUEST_SMS_HEADERS(?UA)})),
    ok = model_invites:record_invite(?UID, ?PHONE, 4),
    BadUserAgentError = mod_halloapp_http_api:return_400(),
    ?assertEqual(BadUserAgentError, mod_halloapp_http_api:process(?REQUEST_SMS_PATH,
        #request{method = 'POST', data = Data, headers = ?REQUEST_SMS_HEADERS(?BAD_UA)})),
    GoodResponse = {200, ?HEADER(?CT_JSON),
        jiffy:encode({[
            {phone, ?PHONE},
            {result, ok}
        ]})},
    ?assertEqual(GoodResponse, mod_halloapp_http_api:process(?REQUEST_SMS_PATH,
        #request{method = 'POST', data = Data, headers = ?REQUEST_SMS_HEADERS(?UA)})),
    meck_finish(ejabberd_router).


register_test() ->
    setup(),
    meck_init(ejabberd_router, is_my_host, fun(_) -> true end),
    Data = jsx:encode([{<<"phone">>, ?PHONE}]),
    ok = model_invites:record_invite(?UID, ?PHONE, 4),
    mod_halloapp_http_api:process(?REQUEST_SMS_PATH,
        #request{method = 'POST', data = Data, headers = ?REQUEST_SMS_HEADERS(?UA)}),
    BadCodeData = ?REGISTER_DATA(?PHONE, ?BAD_SMS_CODE, ?NAME),
    BadCodeError = mod_halloapp_http_api:return_400(wrong_sms_code),
    ?assertEqual(BadCodeError, mod_halloapp_http_api:process(?REGISTER_PATH,
        #request{method = 'POST', data = BadCodeData, headers = ?REGISTER_HEADERS(?UA)})),
    GoodData = ?REGISTER_DATA(?PHONE, ?SMS_CODE, ?NAME),
    BadUserAgentError = mod_halloapp_http_api:return_400(),
    ?assertEqual(BadUserAgentError, mod_halloapp_http_api:process(?REGISTER_PATH,
        #request{method = 'POST', data = GoodData, headers = ?REGISTER_HEADERS(?BAD_UA)})),
    {200, ?HEADER(?CT_JSON), Info} = mod_halloapp_http_api:process(?REGISTER_PATH,
        #request{method = 'POST', data = GoodData, headers = ?REGISTER_HEADERS(?UA)}),
    [{<<"uid">>, Uid}, {<<"phone">>, ?PHONE}, {<<"password">>, Pass},
        {<<"name">>, ?NAME}, {<<"result">>, <<"ok">>}] = jsx:decode(Info),
    ?assert(ejabberd_auth:check_password(Uid, <<>>, ?SERVER, Pass)),
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
    ?assertError(not_invited, mod_halloapp_http_api:check_invited(?PHONE)),
    model_invites:record_invite(?UID, ?PHONE, 4),
    ?assertEqual(ok, mod_halloapp_http_api:check_invited(?PHONE)),
    clear(),
    ?assertError(not_invited, mod_halloapp_http_api:check_invited(?PHONE)),
    {ok, _Pass, _Uid} = ejabberd_auth:ha_try_register(?PHONE, ?SERVER, <<"pass">>, ?NAME, ?UA),
    ?assertEqual(ok, mod_halloapp_http_api:check_invited(?PHONE)).


request_and_check_sms_code_test() ->
    setup(),
    meck_init(ejabberd_router, is_my_host, fun(_) -> true end),
    ?assertError(wrong_sms_code, mod_halloapp_http_api:check_sms_code(?PHONE, ?SMS_CODE)),
    ok = mod_halloapp_http_api:request_sms(?PHONE, ?UA),
    ?assertError(wrong_sms_code, mod_halloapp_http_api:check_sms_code(?PHONE, ?BAD_SMS_CODE)),
    ?assertEqual(ok, mod_halloapp_http_api:check_sms_code(?PHONE, ?SMS_CODE)),
    meck_finish(ejabberd_router).

%%%----------------------------------------------------------------------
%%% Internal functions
%%%----------------------------------------------------------------------

setup() ->
    {ok, _} = application:ensure_all_started(stringprep),
    {ok, _} = application:ensure_all_started(bcrypt),
    redis_sup:start_link(),
    clear(),
    mod_redis:start(undefined, []),
    ok.


clear() ->
    {ok, ok} = gen_server:call(redis_accounts_client, flushdb),
    ok.


meck_init(Mod, FunName, Fun) ->
    meck:new(Mod),
    meck:expect(Mod, FunName, Fun).


meck_finish(Mod) ->
    ?assert(meck:validate(Mod)),
    meck:unload(Mod).

