%%%-------------------------------------------------------------------
%%% @author nikola
%%% @copyright (C) 2021, Halloapp Inc.
%%% @doc
%%%
%%% @end
%%% Created : 21. Apr 2021
%%%-------------------------------------------------------------------
-module(util_tests).
-author("nikola").

-include_lib("eunit/include/eunit.hrl").

simple_test() ->
    ?assert(true).

random_shuffle_test() ->
    L = [1,2,3,4,5],
    Result = util:random_shuffle([1,2,3,4,5]),
    ?assertEqual(L, lists:sort(Result)),
    ?assertEqual([], util:random_shuffle([])),
    ok.

get_shard_test() ->
    ?assertEqual(util:get_stest_shard_num(), util:get_shard('ejabberd@s-test')),
    ?assertEqual(4, util:get_shard('ejabberd@prod4')),
    ?assertEqual(12, util:get_shard('ejabberd@prod12')),
    ?assertEqual(undefined, util:get_shard('ejabberd@localhost')).

