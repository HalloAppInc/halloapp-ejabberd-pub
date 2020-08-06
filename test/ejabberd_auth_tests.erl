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

-define(UID, <<"1">>).
-define(PHONE, <<"16175280000">>).
-define(SERVER, <<"localhost">>).
-define(PASS, <<"pword">>).
-define(NAME, <<"Testname">>).
-define(UA, "HalloApp/iPhone1.0").


%%====================================================================
%% Tests
%%====================================================================

check_password_test() ->
    setup(),
    ok = ejabberd_auth:set_password(?UID, ?SERVER, ?PASS),
    ?assert(ejabberd_auth:check_password(?UID, <<"">>, ?SERVER, ?PASS)),
    ?assertNot(ejabberd_auth:check_password(?UID, <<"">>, ?SERVER, <<"nopass">>)).


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
    ?assert(ejabberd_auth:check_password(Uid, <<"">>, ?SERVER, ?PASS)),
    meck_finish(ejabberd_router).


user_exists_test() ->
    setup(),
    meck_init(ejabberd_router, is_my_host, fun(_) -> true end),
    ?assertNot(ejabberd_auth:user_exists(?UID, <<"">>)),
    ?assertNot(ejabberd_auth:user_exists(?UID, ?SERVER)),
    {ok, Uid, register} = ejabberd_auth:check_and_register(?PHONE, ?SERVER, ?PASS, ?NAME, ?UA),
    ?assert(ejabberd_auth:user_exists(Uid, ?SERVER)),
    meck_finish(ejabberd_router).


remove_user_test() ->
    setup(),
    {ok, Uid, register} = ejabberd_auth:check_and_register(?PHONE, ?SERVER, ?PASS, ?NAME, ?UA),
    ?assert(ejabberd_auth:user_exists(Uid, ?SERVER)),
    ok = ejabberd_auth:remove_user(Uid, ?SERVER),
    ?assertNot(ejabberd_auth:user_exists(Uid, ?SERVER)),
    {ok, Uid2, register} = ejabberd_auth:check_and_register(?PHONE, ?SERVER, ?PASS, ?NAME, ?UA),
    ?assert(ejabberd_auth:user_exists(Uid2, ?SERVER)),
    ok = ejabberd_auth:remove_user(Uid2, ?SERVER, ?PASS),
    ?assertNot(ejabberd_auth:user_exists(Uid2, ?SERVER)).

%%====================================================================
%% Internal functions
%%====================================================================

setup() ->
    {ok, _} = application:ensure_all_started(stringprep),
    {ok, _} = application:ensure_all_started(bcrypt),
    ejabberd_auth_halloapp:start(?SERVER),
    redis_sup:start_link(),
    clear(),
    mod_redis:start(undefined, []),
    ok.


clear() ->
    {ok, ok} = gen_server:call(redis_auth_client, flushdb),
    {ok, ok} = gen_server:call(redis_phone_client, flushdb),
    {ok, ok} = gen_server:call(redis_accounts_client, flushdb).


meck_init(Mod, FunName, Fun) ->
    meck:new(Mod),
    meck:expect(Mod, FunName, Fun).


meck_finish(Mod) ->
    ?assert(meck:validate(Mod)),
    meck:unload(Mod).

