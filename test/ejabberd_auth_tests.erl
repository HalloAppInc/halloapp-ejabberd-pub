%%%-------------------------------------------------------------------
%%% @author josh
%%% @copyright (C) 2020, HalloApp, Inc.
%%% @doc
%%%
%%% @end
%%% Created : 30. Jul 2020 2:54 PM
%%%-------------------------------------------------------------------
-module(ejabberd_auth_tests).
-author("josh").

-include_lib("eunit/include/eunit.hrl").
-include("password.hrl").

-define(UID, <<"1">>).
-define(PHONE, <<"16175280000">>).
-define(SERVER, <<"s.halloapp.net">>).
-define(PASS, <<"pword">>).
-define(SPUB, <<"spub">>).
-define(NAME, <<"Testname">>).
-define(UA, <<"HalloApp/iPhone1.0">>).
-define(CODE, <<"111111">>).


%%====================================================================
%% Tests
%%====================================================================

plain_password_req_test() ->
    ?assert(ejabberd_auth:plain_password_required()).


store_type_test() ->
    ?assertEqual(external, ejabberd_auth:store_type()).


check_password_test() ->
    setup(),
    ok = ejabberd_auth:set_password(?UID, ?PASS),
    {ok, P} = model_auth:get_password(?UID),
    HashedPassword = P#password.hashed_password,
    ?assert(HashedPassword /= <<"">>),
    ?assert(ejabberd_auth:check_password(?UID, ?PASS)),
    ?assertNot(ejabberd_auth:check_password(?UID, <<"nopass">>)).


check_spub_test() ->
    setup(),
    ok = ejabberd_auth:set_spub(?UID, ?SPUB),
    {ok, S} = model_auth:get_spub(?UID),
    SPub = S#s_pub.s_pub,
    ?assert(SPub /= <<"">>),
    ?assert(ejabberd_auth:check_spub(?UID, ?SPUB)),
    ?assertNot(ejabberd_auth:check_spub(?UID, <<"nopass">>)).


check_and_register_test() ->
    setup(),
    meck_init(ejabberd_sm, kick_user, fun(_, _) -> 1 end),
    {ok, Uid, register} = ejabberd_auth:check_and_register(?PHONE, ?SERVER, ?PASS, ?NAME, ?UA),
    {ok, Uid, login} = ejabberd_auth:check_and_register(?PHONE, ?SERVER, ?PASS, ?NAME, ?UA),
    meck_finish(ejabberd_sm).


try_register_test() ->
    setup(),
    meck_init(ejabberd_router, is_my_host, fun(_) -> true end),
    ok = ejabberd_auth:try_register(?PHONE, ?SERVER, ?PASS),
    {ok, Uid} = model_phone:get_uid(?PHONE),
    ?assert(ejabberd_auth:check_password(Uid, ?PASS)),
    meck_finish(ejabberd_router).


ha_try_register_test() ->
    clear(),
    {ok, Password, Uid} = ejabberd_auth:ha_try_register(?PHONE, ?PASS, ?NAME, ?UA),
    ?assertEqual(?PASS, Password),
    ?assert(model_accounts:account_exists(Uid)),
    ?assert(ejabberd_auth:check_password(Uid, ?PASS)),
    ?assertEqual({ok, ?PHONE}, model_accounts:get_phone(Uid)),
    ?assertEqual({ok, Uid}, model_phone:get_uid(?PHONE)),
    ?assertEqual({ok, ?NAME}, model_accounts:get_name(Uid)),
    ?assertEqual({ok, ?UA}, model_accounts:get_signup_user_agent(Uid)).


try_enroll_test() ->
    clear(),
    {ok, _} = ejabberd_auth:try_enroll(?PHONE, ?CODE),
    ?assertEqual({ok, ?CODE}, ejabberd_admin:get_user_passcode(?PHONE, ?SERVER)).


user_exists_test() ->
    setup(),
    meck_init(ejabberd_router, is_my_host, fun(_) -> true end),
    ?assertNot(ejabberd_auth:user_exists(?UID)),
    ?assertNot(ejabberd_auth:user_exists(?UID)),
    {ok, Uid, register} = ejabberd_auth:check_and_register(?PHONE, ?SERVER, ?PASS, ?NAME, ?UA),
    ?assert(ejabberd_auth:user_exists(Uid)),
    meck_finish(ejabberd_router).


remove_user_test() ->
    setup(),
    {ok, Uid, register} = ejabberd_auth:check_and_register(?PHONE, ?SERVER, ?PASS, ?NAME, ?UA),
    ?assert(ejabberd_auth:user_exists(Uid)),
    ok = ejabberd_auth:remove_user(Uid, ?SERVER),
    ?assertNot(ejabberd_auth:user_exists(Uid)),
    {ok, Uid2, register} = ejabberd_auth:check_and_register(?PHONE, ?SERVER, ?PASS, ?NAME, ?UA),
    ?assert(ejabberd_auth:user_exists(Uid2)),
    ok = ejabberd_auth:remove_user(Uid2, ?SERVER, ?PASS),
    ?assertNot(ejabberd_auth:user_exists(Uid2)).


is_password_match_badargg_test() ->
    clear(),
    ?assertError(badarg, ejabberd_auth:is_password_match(<<"binary">>, "str")),
    ?assertError(badarg, ejabberd_auth:is_password_match("str", <<"binary">>)),
    ?assertError(badarg, ejabberd_auth:is_password_match("str", "str")),
    ?assertNotException(error, badarg, ejabberd_auth:is_password_match(<<"bin">>, <<"bin">>)),
    ?assertNot(ejabberd_auth:is_password_match(<<"bin">>, <<"bin">>)).


%%====================================================================
%% Internal functions
%%====================================================================

setup() ->
    tutil:setup(),
    {ok, _} = application:ensure_all_started(stringprep),
    {ok, _} = application:ensure_all_started(bcrypt),
    redis_sup:start_link(),
    clear(),
    mod_redis:start(undefined, []),
    ok.


clear() ->
    tutil:cleardb(redis_auth),
    tutil:cleardb(redis_phone),
    tutil:cleardb(redis_accounts).


meck_init(Mod, FunName, Fun) ->
    meck:new(Mod),
    meck:expect(Mod, FunName, Fun).


meck_finish(Mod) ->
    ?assert(meck:validate(Mod)),
    meck:unload(Mod).

