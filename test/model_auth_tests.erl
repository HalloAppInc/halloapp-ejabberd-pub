%%%-------------------------------------------------------------------
%%% @author nikola
%%% @copyright (C) 2020, Halloapp Inc.
%%% @doc
%%%
%%% @end
%%% Created : 09. Apr 2020 1:32 PM
%%%-------------------------------------------------------------------
-module(model_auth_tests).
-author("nikola").

-include_lib("eunit/include/eunit.hrl").
-include("password.hrl").

setup() ->
    tutil:setup(),
    ha_redis:start(),
    clear(),
    ok.

clear() ->
    tutil:cleardb(redis_auth).

-define(UID1, <<"1">>).
-define(SPUB1, <<"spub1">>).

-define(UID2, <<"2">>).
-define(SPUB2, <<"spub2">>).

-define(STATIC_KEY1, <<"static_key1">>).
-define(STATIC_KEY2, <<"static_key2">>).


spub_key_test() ->
    ?assertEqual(<<"spb:{1}">>, model_auth:spub_key(?UID1)).

no_spub(Uid) ->
    #s_pub{s_pub = undefined, ts_ms = undefined, uid = Uid}.

set_spub_test() ->
    setup(),
    ok = model_auth:set_spub(?UID1, ?SPUB1),
    ok = model_auth:set_spub(?UID2, ?SPUB2).

set_get_spub_test() ->
    setup(),
    {ok, NoSPub} = model_auth:get_spub(?UID1),
    ?assertEqual(no_spub(?UID1), NoSPub),
    ok = model_auth:set_spub(?UID1, ?SPUB1),
    {ok, #s_pub{s_pub = ?SPUB1, uid = ?UID1}} = model_auth:get_spub(?UID1).

lock_user_test() ->
    setup(),
    ok = model_auth:set_spub(?UID1, ?SPUB1),
    ok = model_auth:lock_user(?UID1),
    {ok, #s_pub{s_pub = Locked}} = model_auth:get_spub(?UID1),
    ?assertNotEqual(Locked, ?SPUB1),
    ok = model_auth:unlock_user(?UID1),
    {ok, #s_pub{s_pub = ?SPUB1}} = model_auth:get_spub(?UID1),
    ok = model_auth:unlock_user(?UID1),
    {ok, #s_pub{s_pub = ?SPUB1}} = model_auth:get_spub(?UID1).

delete_spub_test() ->
    setup(),
    ok = model_auth:set_spub(?UID1, ?SPUB1),
    {ok, #s_pub{s_pub = ?SPUB1, uid = ?UID1}} = model_auth:get_spub(?UID1),
    ok = model_auth:delete_spub(?UID1),
    {ok, NoSPub} = model_auth:get_spub(?UID1),
    ?assertEqual(no_spub(?UID1), NoSPub).

webclient_info_test() ->
    setup(),
    {ok, []} = model_auth:get_static_keys(?UID1),
    ok = model_auth:authenticate_static_key(?UID1, ?STATIC_KEY1),
    {ok, [?STATIC_KEY1]} = model_auth:get_static_keys(?UID1),
    ok = model_auth:authenticate_static_key(?UID1, ?STATIC_KEY2),
    {ok, ListKeys} = model_auth:get_static_keys(?UID1),
    ?assertEqual(sets:from_list([?STATIC_KEY2, ?STATIC_KEY1]), sets:from_list(ListKeys)),
    {ok, ?UID1} = model_auth:get_static_key_uid(?STATIC_KEY1),
    {ok, ?UID1} = model_auth:get_static_key_uid(?STATIC_KEY2),
    ok = model_auth:delete_static_key(?UID1, ?STATIC_KEY2),
    {ok, [?STATIC_KEY1]} = model_auth:get_static_keys(?UID1),
    {ok, ?UID1} = model_auth:get_static_key_uid(?STATIC_KEY1),
    {ok, undefined} = model_auth:get_static_key_uid(?STATIC_KEY2),
    ok.


static_key_attempt_test() ->
    setup(),

    Now = util:now(),
    ?assertEqual(0, model_auth:get_static_key_code_attempts(?STATIC_KEY1, Now)),
    ?assertEqual(1, model_auth:add_static_key_code_attempt(?STATIC_KEY1, Now)),
    ?assertEqual(2, model_auth:add_static_key_code_attempt(?STATIC_KEY1, Now)),
    ?assertEqual(2, model_auth:get_static_key_code_attempts(?STATIC_KEY1, Now)),
    ?assertEqual(0, model_auth:get_static_key_code_attempts(?STATIC_KEY2, Now)),

    % check expiration time
    {ok, TTLBin} = model_phone:q(["TTL", model_auth:static_key_attempt_key(?STATIC_KEY1, Now)]),
    TTL = util_redis:decode_int(TTLBin),
    ?assertEqual(true, TTL > 0),
    ok.

