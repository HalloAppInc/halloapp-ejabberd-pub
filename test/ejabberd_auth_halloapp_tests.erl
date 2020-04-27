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

%%setup() ->
%%    {ok, _} = application:ensure_all_started(stringprep),
%%    {ok, _} = application:ensure_all_started(bcrypt),
%%    ejabberd_mnesia:start(),
%%    ejabberd_auth_halloapp:start(?SERVER),
%%    %% Could not start the mod_pubsub because it wants some config
%%%%    mod_pubsub:start(?SERVER,[]),
%%    redis_sup:start_link(),
%%    clear(),
%%    model_auth:start_link(),
%%    model_accounts:start_link(),
%%    model_phone:start_link(),
%%    ok.
%%
%%teardown() ->
%%    application:stop(strigprep),
%%    application:stop(bcrypt),
%%    %% TODO: could not figure out how to stop ejabberd_mnesia...
%%%%    ejabberd_mnesia:stop(),
%%    ok.
%%
%%clear() ->
%%    clear_mnesia(),
%%    clear_redis().
%%
%%clear_mnesia() ->
%%    mnesia:clear_table(passwd),
%%    mnesia:clear_table(user_phone),
%%    mnesia:clear_table(enrolled_users).
%%
%%clear_redis() ->
%%    ok = gen_server:cast(redis_auth_client, flushdb),
%%    ok = gen_server:cast(redis_phone_client, flushdb),
%%    ok = gen_server:cast(redis_accounts_client, flushdb).
%%
%%single_test(T) ->
%%    list_to_atom("sm_" ++ atom_to_list(T)).
%%
%%
%%simple_test() ->
%%    ?assert(true).
%%
%%store_type_test() ->
%%    ?assertEqual(external, ejabberd_auth_halloapp:store_type(?SERVER)).
%%
%%set_password_test() ->
%%    setup(),
%%    ?assertEqual({cache, {ok, ?PASS1}},
%%        ejabberd_auth_halloapp:set_password(?UID1, ?SERVER, ?PASS1)),
%%    ?assertEqual({cache, {ok, ?PASS1}}, ejabberd_auth_mnesia:get_password(?UID1, ?SERVER)),
%%    {ok, P} = model_auth:get_password(?UID1),
%%    HashedPassword = P#password.hashed_password,
%%    ?assert(HashedPassword /= <<"">>),
%%    ?assertEqual({cache, true},
%%        ejabberd_auth_halloapp:check_password_internal(?UID1, undefined, ?SERVER, ?PASS1)),
%%    ok.
%%
%%check_password_test() ->
%%    clear(),
%%    ?assertEqual({cache, {ok, ?PASS1}},
%%            ejabberd_auth_halloapp:set_password(?UID1, ?SERVER, ?PASS1)),
%%    ?assertEqual({cache, true}, ejabberd_auth_halloapp:check_password(
%%            ?UID1, undefined, ?SERVER, ?PASS1)),
%%    ?assertEqual({cache, true}, ejabberd_auth_halloapp:check_password_internal(
%%        ?UID1, undefined, ?SERVER, ?PASS1)),
%%    ok.
%%
%%is_password_match_badargg_test() ->
%%    clear(),
%%    ?assertError(badarg, ejabberd_auth_halloapp:is_password_match(<<"binary">>, "str")),
%%    ?assertError(badarg, ejabberd_auth_halloapp:is_password_match("str", <<"binary">>)),
%%    ?assertError(badarg, ejabberd_auth_halloapp:is_password_match("str", "str")),
%%    ?assertNotException(error, badarg,
%%        ejabberd_auth_halloapp:is_password_match(<<"bin">>, <<"bin">>)),
%%    ?assertEqual(false, ejabberd_auth_halloapp:is_password_match(<<"bin">>, <<"bin">>)),
%%    ok.
%%
%%try_register_test() ->
%%    clear(),
%%    {cache, {ok, Password, Uid}} = ejabberd_auth_halloapp:try_register(?PHONE1, ?SERVER, ?PASS1),
%%    ?assertEqual(?PASS1, Password),
%%    ?assert(model_accounts:account_exists(Uid)),
%%    ?assertEqual({cache, true},
%%        ejabberd_auth_halloapp:check_password(Uid, undefined, ?SERVER, ?PASS1)),
%%    ?assertEqual({ok, ?PHONE1}, model_accounts:get_phone(Uid)),
%%    ?assertEqual({ok, Uid}, model_phone:get_uid(?PHONE1)),
%%    ?assertEqual(ok, ejabberd_auth_halloapp:remove_user(Uid, ?SERVER)),
%%    ok.
%%
%%try_enroll_test() ->
%%    clear(),
%%    ?assertEqual(ok, ejabberd_auth_halloapp:remove_enrolled_user(?PHONE1, ?SERVER)),
%%    {ok, ?CODE1} = ejabberd_auth_halloapp:try_enroll(?PHONE1, ?SERVER, ?CODE1),
%%    ?assertEqual({ok, ?CODE1}, model_phone:get_sms_code(?PHONE1)),
%%    ?assertEqual({ok, ?CODE1}, ejabberd_auth_halloapp:get_passcode(?PHONE1, ?SERVER)),
%%    ?assertEqual({ok, ?CODE1}, ejabberd_auth_halloapp:get_passcode_internal(?PHONE1, ?SERVER)),
%%    ok.
%%
%%get_passcode_test() ->
%%    clear(),
%%    ?assertEqual({error, invalid}, ejabberd_auth_halloapp:get_passcode(?PHONE1, ?SERVER)),
%%    ?assertEqual({error, invalid}, ejabberd_auth_halloapp:get_passcode_internal(?PHONE1, ?SERVER)),
%%    ok.
%%
%%remove_user_test() ->
%%    clear(),
%%    {cache, {ok, ?PASS1, Uid}} = ejabberd_auth_halloapp:try_register(?PHONE1, ?SERVER, ?PASS1),
%%    ?assert(model_accounts:account_exists(Uid)),
%%    ?assertEqual({cache, true},
%%        ejabberd_auth_halloapp:check_password(Uid, undefined, ?SERVER, ?PASS1)),
%%    ?assertEqual(ok, ejabberd_auth_halloapp:remove_user(Uid, ?SERVER)),
%%    ok.
%%
%%get_uid_get_phone_test() ->
%%    clear(),
%%    {cache, {ok, ?PASS1, Uid}} = ejabberd_auth_halloapp:try_register(?PHONE1, ?SERVER, ?PASS1),
%%    ?assert(model_accounts:account_exists(Uid)),
%%    ?assertEqual(Uid, ejabberd_auth_halloapp:get_uid(?PHONE1)),
%%    ?assertEqual(Uid, ejabberd_auth_halloapp:get_uid_internal(?PHONE1)),
%%    ?assertEqual(?PHONE1, ejabberd_auth_halloapp:get_phone(Uid)),
%%    ?assertEqual(?PHONE1, ejabberd_auth_halloapp:get_phone_internal(Uid)),
%%    ok.
%%
%%migration_test() ->
%%    clear(),
%%    {ok, ?CODE1} = ejabberd_auth_halloapp:try_enroll(?PHONE1, ?SERVER, ?CODE1),
%%    {cache, {ok, ?PASS1, Uid1}} = ejabberd_auth_halloapp:try_register(?PHONE1, ?SERVER, ?PASS1),
%%
%%    {ok, ?CODE2} = ejabberd_auth_halloapp:try_enroll(?PHONE2, ?SERVER, ?CODE2),
%%    {cache, {ok, ?PASS2, Uid2}} = ejabberd_auth_halloapp:try_register(?PHONE2, ?SERVER, ?PASS2),
%%
%%    {ok, ?CODE3} = ejabberd_auth_halloapp:try_enroll(?PHONE3, ?SERVER, ?CODE3),
%%    {cache, {ok, ?PASS3, Uid3}} = ejabberd_auth_halloapp:try_register(?PHONE3, ?SERVER, ?PASS3),
%%
%%    clear_redis(),
%%
%%    ?assertEqual(false, model_accounts:account_exists(Uid1)),
%%    ?assertEqual(false, model_accounts:account_exists(Uid2)),
%%    ?assertEqual(false, model_accounts:account_exists(Uid3)),
%%
%%    {ok, 3, 3} = ejabberd_auth_halloapp:migrate_all(),
%%
%%    ?assertEqual(true, model_accounts:account_exists(Uid1)),
%%    ?assertEqual(true, model_accounts:account_exists(Uid2)),
%%    ?assertEqual(true, model_accounts:account_exists(Uid3)),
%%    ?assertEqual({ok, Uid1}, model_phone:get_uid(?PHONE1)),
%%    ?assertEqual({ok, Uid2}, model_phone:get_uid(?PHONE2)),
%%    ?assertEqual({ok, Uid3}, model_phone:get_uid(?PHONE3)),
%%    ?assertEqual({ok, ?PHONE1}, model_accounts:get_phone(Uid1)),
%%    ?assertEqual({ok, ?PHONE2}, model_accounts:get_phone(Uid2)),
%%    ?assertEqual({ok, ?PHONE3}, model_accounts:get_phone(Uid3)),
%%    ok.

%%shutdown_test() ->
%%    teardown(),
%%    ok.