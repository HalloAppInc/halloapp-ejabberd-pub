%%%-------------------------------------------------------------------
%%% @author nikola
%%% @copyright (C) 2020, Halloapp Inc.
%%% @doc
%%%
%%% @end
%%% Created : 09. Apr 2020 1:32 PM
%%%-------------------------------------------------------------------
-module(model_accounts_tests).
-author("nikola").

-include_lib("eunit/include/eunit.hrl").

setup() ->
  redis_sup:start_link(),
  clear(),
  model_accounts:start_link(),
  ok.

clear() ->
  ok = gen_server:cast(redis_accounts_client, flushdb).

key_test() ->
    ?assertEqual(<<"acc:{1}">>, model_accounts:key(<<"1">>)).

get_set_name_test() ->
    setup(),
    ok = model_accounts:set_name(<<"1">>, <<"John">>),
    {ok, Name} = model_accounts:get_name(<<"1">>),
    ?assertEqual(<<"John">>, Name).

get_name_missing_test() ->
    setup(),
    {ok, undefined} = model_accounts:get_name(<<"2">>).
