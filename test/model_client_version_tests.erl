%%%-------------------------------------------------------------------
%%% @author nikola
%%% @copyright (C) 2020, Halloapp Inc.
%%% @doc
%%%
%%% @end
%%% Created : 09. Apr 2020 1:32 PM
%%%-------------------------------------------------------------------
-module(model_client_version_tests).
-author("nikola").

-include_lib("eunit/include/eunit.hrl").

-define(VERSION1, <<"Android1">>).
-define(TS1, 1).

-define(VERSION2, <<"Android2">>).
-define(TS2, 2).

setup() ->
    redis_sup:start_link(),
    clear(),
    ok.

clear() ->
    {ok, ok} = gen_server:call(redis_accounts_client, flushdb).

version_key_test() ->
    ?assertEqual(<<"clv:Android1">>, model_client_version:version_key(?VERSION1)).

no_get_version_ts_test() ->
    setup(),
    ?assertEqual(undefined, model_client_version:get_version_ts(?VERSION1)).

set_get_version_ts_test() ->
    setup(),
    ?assertEqual(true, model_client_version:set_version_ts(?VERSION1, ?TS1)),
    ?assertEqual(?TS1, model_client_version:get_version_ts(?VERSION1)).

already_set_test() ->
    setup(),
    ?assertEqual(true, model_client_version:set_version_ts(?VERSION1, ?TS1)),
    ?assertEqual(false, model_client_version:set_version_ts(?VERSION1, ?TS2)),
    ?assertEqual(?TS1, model_client_version:get_version_ts(?VERSION1)).

two_version_test() ->
    setup(),
    ?assertEqual(true, model_client_version:set_version_ts(?VERSION1, ?TS1)),
    ?assertEqual(true, model_client_version:set_version_ts(?VERSION2, ?TS2)),
    ?assertEqual(?TS1, model_client_version:get_version_ts(?VERSION1)),
    ?assertEqual(?TS2, model_client_version:get_version_ts(?VERSION2)).

