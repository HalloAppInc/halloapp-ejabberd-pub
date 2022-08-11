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
-define(SPUB, <<"spub">>).
-define(NAME, <<"Testname">>).
-define(UA, <<"HalloApp/iPhone1.0">>).
-define(CAMPAIGN_ID, <<"cmpn">>).
-define(CODE, <<"111111">>).


%%====================================================================
%% Tests
%%====================================================================

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
    tutil:meck_init(ejabberd_sm, kick_user, fun(_, _) -> 1 end),
    {ok, Uid, register} = ejabberd_auth:check_and_register(?PHONE, ?SERVER, ?SPUB, ?NAME, ?UA, ?CAMPAIGN_ID),
    {ok, Uid, login} = ejabberd_auth:check_and_register(?PHONE, ?SERVER, ?SPUB, ?NAME, ?UA, ?CAMPAIGN_ID),
    tutil:meck_finish(ejabberd_sm).


ha_try_register_test() ->
    clear(),
    {ok, SPub, Uid} = ejabberd_auth:ha_try_register(?PHONE, ?SPUB, ?NAME, ?UA, <<>>),
    ?assertEqual(?SPUB, SPub),
    ?assert(model_accounts:account_exists(Uid)),
    ?assert(ejabberd_auth:check_spub(Uid, ?SPUB)),
    ?assertEqual({ok, ?PHONE}, model_accounts:get_phone(Uid)),
    ?assertEqual({ok, Uid}, model_phone:get_uid(?PHONE)),
    ?assertEqual({ok, ?NAME}, model_accounts:get_name(Uid)),
    ?assertEqual({ok, ?UA}, model_accounts:get_signup_user_agent(Uid)).


try_enroll_test() ->
    clear(),
    {ok, AttemptId, _} = ejabberd_auth:try_enroll(?PHONE, ?CODE, <<>>),
    ?assertEqual({ok, ?CODE}, model_phone:get_sms_code2(?PHONE, AttemptId)).


user_exists_test() ->
    setup(),
    tutil:meck_init(ejabberd_router, is_my_host, fun(_) -> true end),
    ?assertNot(ejabberd_auth:user_exists(?UID)),
    ?assertNot(ejabberd_auth:user_exists(?UID)),
    {ok, Uid, register} = ejabberd_auth:check_and_register(?PHONE, ?SERVER, ?SPUB, ?NAME, ?UA, ?CAMPAIGN_ID),
    ?assert(ejabberd_auth:user_exists(Uid)),
    tutil:meck_finish(ejabberd_router).


remove_user_test() ->
    setup(),
    {ok, Uid, register} = ejabberd_auth:check_and_register(?PHONE, ?SERVER, ?SPUB, ?NAME, ?UA, ?CAMPAIGN_ID),
    ?assert(ejabberd_auth:user_exists(Uid)),
    ok = ejabberd_auth:remove_user(Uid, ?SERVER),
    ?assertNot(ejabberd_auth:user_exists(Uid)).


%%====================================================================
%% Internal functions
%%====================================================================

setup() ->
    tutil:setup(),
    {ok, _} = application:ensure_all_started(stringprep),
    ha_redis:start(),
    clear(),
    ok.


clear() ->
    tutil:cleardb(redis_auth),
    tutil:cleardb(redis_phone),
    tutil:cleardb(redis_accounts).

