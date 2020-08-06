%%%-------------------------------------------------------------------
%%% @author nikola
%%% @copyright (C) 2020, HalloApp, Inc.
%%% @doc
%%%
%%% @end
%%% Created : 21. Apr 2020 5:10 PM
%%%-------------------------------------------------------------------
-module(ejabberd_auth_halloapp_tests).
-author("nikola").
-author("josh").

-include_lib("eunit/include/eunit.hrl").

%% API
-compile(export_all).

-define(UID1, <<"1">>).
-define(PASS1, <<"foo">>).
-define(PHONE1, <<"+12015555551">>).
-define(CODE1, <<"111111">>).

-define(UID2, <<"2">>).
-define(PASS2, <<"bar">>).
-define(PHONE2, <<"+12025555552">>).
-define(CODE2, <<"111112">>).

-define(UID3, <<"3">>).
-define(PASS3, <<"bar3">>).
-define(PHONE3, <<"+12035555553">>).
-define(CODE3, <<"111113">>).

-define(SERVER, <<"s.halloapp.net">>).

-include("password.hrl").

%% ----------------------------------------------
%% Tests
%% ----------------------------------------------

plain_password_req_test() ->
    ?assert(ejabberd_auth_halloapp:plain_password_required(?SERVER)).


store_type_test() ->
    ?assertEqual(external, ejabberd_auth_halloapp:store_type(?SERVER)).


set_password_test() ->
    setup(),
    ?assertEqual({ok, ?PASS1}, ejabberd_auth_halloapp:set_password(?UID1, ?SERVER, ?PASS1)),
    {ok, P} = model_auth:get_password(?UID1),
    HashedPassword = P#password.hashed_password,
    ?assert(HashedPassword /= <<"">>),
    ?assert(ejabberd_auth_halloapp:check_password(?UID1, undefined, ?SERVER, ?PASS1)).


is_password_match_badargg_test() ->
    clear(),
    ?assertError(badarg, ejabberd_auth_halloapp:is_password_match(<<"binary">>, "str")),
    ?assertError(badarg, ejabberd_auth_halloapp:is_password_match("str", <<"binary">>)),
    ?assertError(badarg, ejabberd_auth_halloapp:is_password_match("str", "str")),
    ?assertNotException(error, badarg,
        ejabberd_auth_halloapp:is_password_match(<<"bin">>, <<"bin">>)),
    ?assertNot(ejabberd_auth_halloapp:is_password_match(<<"bin">>, <<"bin">>)).


try_register_test() ->
    clear(),
    {ok, Password, Uid} = ejabberd_auth_halloapp:try_register(?PHONE1, ?SERVER, ?PASS1),
    ?assertEqual(?PASS1, Password),
    ?assert(model_accounts:account_exists(Uid)),
    ?assert(ejabberd_auth_halloapp:check_password(Uid, undefined, ?SERVER, ?PASS1)),
    ?assertEqual({ok, ?PHONE1}, model_accounts:get_phone(Uid)),
    ?assertEqual({ok, Uid}, model_phone:get_uid(?PHONE1)),
    ?assertEqual(ok, ejabberd_auth_halloapp:remove_user(Uid, ?SERVER)).


try_enroll_test() ->
    clear(),
    ?assertEqual(ok, ejabberd_auth_halloapp:remove_enrolled_user(?PHONE1, ?SERVER)),
    {ok, ?CODE1} = ejabberd_auth_halloapp:try_enroll(?PHONE1, ?SERVER, ?CODE1),
    ?assertEqual({ok, ?CODE1}, model_phone:get_sms_code(?PHONE1)),
    ?assertEqual({ok, ?CODE1}, ejabberd_auth_halloapp:get_passcode(?PHONE1, ?SERVER)).


get_passcode_test() ->
    clear(),
    ?assertEqual({error, invalid}, ejabberd_auth_halloapp:get_passcode(?PHONE1, ?SERVER)).


remove_user_test() ->
    clear(),
    {ok, ?PASS1, Uid} = ejabberd_auth_halloapp:try_register(?PHONE1, ?SERVER, ?PASS1),
    ?assert(model_accounts:account_exists(Uid)),
    ?assert(ejabberd_auth_halloapp:check_password(Uid, undefined, ?SERVER, ?PASS1)),
    ?assertEqual(ok, ejabberd_auth_halloapp:remove_user(Uid, ?SERVER)),
    ?assertNot(model_accounts:account_exists(Uid)).


get_uid_get_phone_test() ->
    clear(),
    {ok, ?PASS1, Uid} = ejabberd_auth_halloapp:try_register(?PHONE1, ?SERVER, ?PASS1),
    ?assert(model_accounts:account_exists(Uid)),
    ?assert(ejabberd_auth_halloapp:user_exists(Uid, ?SERVER)),
    ?assertEqual(Uid, ejabberd_auth_halloapp:get_uid(?PHONE1)),
    ?assertEqual(?PHONE1, ejabberd_auth_halloapp:get_phone(Uid)).

%% ----------------------------------------------
%% Internal functions
%% ----------------------------------------------

setup() ->
    {ok, _} = application:ensure_all_started(stringprep),
    {ok, _} = application:ensure_all_started(bcrypt),
    redis_sup:start_link(),
    clear(),
    mod_redis:start(undefined, []),
    ok.


clear() ->
    {ok, ok} = gen_server:call(redis_auth_client, flushdb),
    {ok, ok} = gen_server:call(redis_phone_client, flushdb),
    {ok, ok} = gen_server:call(redis_accounts_client, flushdb).

