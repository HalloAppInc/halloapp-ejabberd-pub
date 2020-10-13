%%%-------------------------------------------------------------------
%%% @author nikola
%%% @copyright (C) 2020, Halloapp Inc.
%%% @doc
%%% Test Utility module
%%% @end
%%% Created : 14. Aug 2020 3:17 PM
%%%-------------------------------------------------------------------
-module(tutil).
-author("nikola").

-include("xmpp.hrl").
-include_lib("eunit/include/eunit.hrl").

%% API
-export([
    setup/0,
    get_result_iq_sub_el/1,
    assert_empty_result_iq/1,
    get_error_iq_sub_el/1,
    cleardb/1
]).


setup() ->
    ?assert(config:is_testing_env()).


get_result_iq_sub_el(#iq{} = IQ) ->
    ?assertEqual(result, IQ#iq.type),
    [Res] = IQ#iq.sub_els,
    Res.


assert_empty_result_iq(#iq{} = IQ) ->
    ?assertEqual(result, IQ#iq.type),
    ?assertEqual([], IQ#iq.sub_els).


get_error_iq_sub_el(#iq{} = IQ) ->
    ?assertEqual(error, IQ#iq.type),
    [Res] = IQ#iq.sub_els,
    Res.

cleardb(DBName) ->
    true = config:is_testing_env(),
    {_, "127.0.0.1", 30001} = config:get_service(DBName),
    RedisClient = list_to_atom(atom_to_list(DBName) ++ "_client"),
    Result = gen_server:call(RedisClient, {qa, ["DBSIZE"]}),
    {ok, [{ok, BinSize} | _]}  = Result,
    DbSize = binary_to_integer(BinSize),
    ?assert(DbSize < 100),
    {ok, ok} = gen_server:call(RedisClient, flushdb).


