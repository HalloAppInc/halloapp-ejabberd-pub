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
  redis_sup:start_link(),
  clear(),
  model_auth:start_link(),
  ok.

clear() ->
  {ok, ok} = gen_server:call(redis_auth_client, flushdb).

-define(UID1, <<"1">>).
-define(SALT1, <<"DE76yR5bKC3bEbN">>).
-define(HASHED_PASSWORD1, <<"mq4W5w4lDonyPkzOwowkqiDogYUeeKG">>).

-define(UID2, <<"2">>).
-define(SALT2, <<"Bym6VTkjedpDUFO">>).
-define(HASHED_PASSWORD2, <<"HLTLvzxmhq8cwhyWftu6lP8nhnmJtad">>).


password_key_test() ->
    ?assertEqual(<<"pas:{1}">>, model_auth:password_key(?UID1)).

no_password(Uid) ->
    #password{salt = undefined, hashed_password = undefined,
        ts_ms = undefined, uid = Uid}.

set_password_test() ->
    setup(),
    ok = model_auth:set_password(?UID1, ?SALT1, ?HASHED_PASSWORD1),
    ok = model_auth:set_password(?UID2, ?SALT2, ?HASHED_PASSWORD2).

set_get_password_test() ->
    setup(),
    {ok, NoPassword} = model_auth:get_password(?UID1),
    ?assertEqual(no_password(?UID1), NoPassword),
    ok = model_auth:set_password(?UID1, ?SALT1, ?HASHED_PASSWORD1),
    {ok, #password{salt = ?SALT1, hashed_password = ?HASHED_PASSWORD1, uid = ?UID1}} =
        model_auth:get_password(?UID1).

delete_password_test() ->
    setup(),
    ok = model_auth:set_password(?UID1, ?SALT1, ?HASHED_PASSWORD1),
    {ok, #password{salt = ?SALT1, hashed_password = ?HASHED_PASSWORD1, uid = ?UID1}} =
        model_auth:get_password(?UID1),
    ok = model_auth:delete_password(?UID1),
    {ok, NoPassword} = model_auth:get_password(?UID1),
    ?assertEqual(no_password(?UID1), NoPassword).

