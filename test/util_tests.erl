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


test_random_shuffle(_) ->
    L = [1,2,3,4,5],
    Result = util:random_shuffle([1,2,3,4,5]),
    [
        ?_assertEqual(L, lists:sort(Result)),
        ?_assertEqual([], util:random_shuffle([]))
    ].

test_get_shard(_) ->
    [
        ?_assertEqual(util:get_stest_shard_num(), util:get_shard('ejabberd@s-test')),
        ?_assertEqual(util:get_stest_shard_num() + 1, util:get_shard('ejabberd@s-test1')),
        ?_assertEqual(4, util:get_shard('ejabberd@prod4')),
        ?_assertEqual(12, util:get_shard('ejabberd@prod12')),
        ?_assertEqual(undefined, util:get_shard('ejabberd@localhost'))
    ].

test_type(_) ->
    [
        ?_assertEqual("binary", util:type(<<"hello">>)),
        ?_assertEqual("list", util:type("hello")),
        ?_assertEqual("boolean", util:type(true)),
        ?_assertEqual("atom", util:type(hello)),
        ?_assertEqual("float", util:type(1.2)),
        ?_assertEqual("integer", util:type(5)),
        ?_assertEqual("map", util:type(#{})),
        ?_assertEqual("tuple", util:type({a, b})),
        ?_assertEqual("bitstring", util:type(<<0:1,4:6>>))
    ].

test_to_integer(_) ->
    [
        ?_assertEqual(5, util:to_integer("5")),
        ?_assertEqual(5, util:to_integer(<<"5">>)),
        ?_assertEqual(5, util:to_integer(5.0)),
        ?_assertEqual(5, util:to_integer(5.2)),
        ?_assertEqual(5, util:to_integer(5)),
        ?_assertError(badarg, util:to_integer(<<"abc">>)),
        ?_assertError(badarg, util:to_integer(some_atom))
    ].

test_to_integer_maybe(_) ->
    [
        ?_assertEqual(5, util:to_integer_maybe("5")),
        ?_assertEqual(undefined, util:to_integer_maybe("abc"))
    ].

test_to_float(_) ->
    [
        ?_assertEqual(1.2, util:to_float("1.2")),
        ?_assertEqual(1.0, util:to_float("1")),
        ?_assertEqual(1.2, util:to_float(<<"1.2">>)),
        ?_assertEqual(1.2, util:to_float(1.2)),
        ?_assertEqual(1.0, util:to_float(1)),
        ?_assertError(badarg, util:to_float(foo)),
        ?_assertError(badarg, util:to_float("1.2bla")),
        ?_assertError(badarg, util:to_float("bla1.2"))
    ].

test_to_float_maybe(_) ->
    [
        ?_assertEqual(1.2, util:to_float_maybe("1.2")),
        ?_assertEqual(undefined, util:to_float_maybe(foo))
    ].

test_to_atom(_) ->
    [
        ?_assertEqual(foo, util:to_atom("foo")),
        ?_assertEqual(foo, util:to_atom(<<"foo">>)),
        ?_assertEqual(false, util:to_atom(false)),
        ?_assertEqual(foo, util:to_atom(foo)),
        ?_assertError(badarg, util:to_atom(34))
    ].

test_to_atom_maybe(_) ->
    [
        ?_assertEqual(foo, util:to_atom_maybe("foo")),
        ?_assertEqual(undefined, util:to_atom_maybe(34))
    ].

test_to_binary(_) ->
    [
        ?_assertEqual(<<"foo">>, util:to_binary(<<"foo">>)),
        ?_assertEqual(<<"foo">>, util:to_binary("foo")),
        ?_assertEqual(<<"5">>, util:to_binary(5)),
        ?_assertEqual(<<"5.5">>, util:to_binary(5.5)),
        ?_assertEqual(<<"false">>, util:to_binary(false)),
        ?_assertEqual(<<"foo">>, util:to_binary(foo)),
        ?_assertError(badarg, util:to_binary(#{}))
    ].

test_to_binary_maybe(_) ->
    [
        ?_assertEqual(<<"foo">>, util:to_binary_maybe("foo")),
        ?_assertEqual(<<>>, util:to_binary_maybe(#{}))
    ].

test_to_list(_) ->
    [
        ?_assertEqual("foo", util:to_list("foo")),
        ?_assertEqual("foo", util:to_list(<<"foo">>)),
        ?_assertEqual("1", util:to_list(1)),
        ?_assertEqual("1.0", util:to_list(1.0)),
        ?_assertEqual("true", util:to_list(true)),
        ?_assertEqual("foo", util:to_list(foo)),
        ?_assertError(badarg, util:to_list(#{}))
    ].

test_to_list_maybe(_) ->
    [
        ?_assertEqual("foo", util:to_list_maybe(<<"foo">>)),
        ?_assertEqual(undefined, util:to_list_maybe(#{}))
    ].


test_list_to_map(_) ->
    [
        ?_assertEqual(#{}, util:list_to_map([])),
        ?_assertEqual(#{k1 => v1}, util:list_to_map([k1, v1])),
        ?_assertEqual(#{k1 => v1, k2 => v2}, util:list_to_map([k1, v1, k2, v2])),
        ?_assertError(badarg, util:list_to_map([k1, v1, foo]))
    ].

test_normalize_scores(_) ->
    [
        ?_assertEqual([0.2, 0.3, 0.5], util:normalize_scores([2,3,5])),
        ?_assertEqual(#{a => 0.2, b => 0.3, c => 0.5},
            util:normalize_scores(#{a => 2, b => 3, c => 5}))
    ].

test_remove_cc_from_langid(_) ->
    [
        ?_assertEqual(<<"en">>, util:remove_cc_from_langid(<<"en-US">>)),
        ?_assertEqual(<<"pt">>, util:remove_cc_from_langid(<<"pt-BR">>)),
        ?_assertEqual(<<"ar">>, util:remove_cc_from_langid(<<"ar">>))
    ].


do_util_test_() ->
    % Note, this is an unnecessary amount of complexity -- all of these test functions could just end
    % in _test_() and work great. It's just fun to parallelize to go super duper fast
    tutil:true_parallel([
        fun test_random_shuffle/1,
        fun test_get_shard/1,
        fun test_type/1,
        fun test_to_integer/1,
        fun test_to_integer_maybe/1,
        fun test_to_float/1,
        fun test_to_float_maybe/1,
        fun test_to_atom/1,
        fun test_to_atom_maybe/1,
        fun test_to_binary/1,
        fun test_to_binary_maybe/1,
        fun test_to_list/1,
        fun test_to_list_maybe/1,
        fun test_list_to_map/1,
        fun test_normalize_scores/1,
        fun test_remove_cc_from_langid/1
    ]).
