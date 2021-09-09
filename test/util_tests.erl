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

type_test() ->
    ?assertEqual("binary", util:type(<<"hello">>)),
    ?assertEqual("list", util:type("hello")),
    ?assertEqual("boolean", util:type(true)),
    ?assertEqual("atom", util:type(hello)),
    ?assertEqual("float", util:type(1.2)),
    ?assertEqual("integer", util:type(5)),
    ?assertEqual("map", util:type(#{})),
    ?assertEqual("tuple", util:type({a, b})),
    ?assertEqual("bitstring", util:type(<<0:1,4:6>>)),

    ok.

to_integer_test() ->
    ?assertEqual(5, util:to_integer("5")),
    ?assertEqual(5, util:to_integer(<<"5">>)),
    ?assertEqual(5, util:to_integer(5.0)),
    ?assertEqual(5, util:to_integer(5.2)),
    ?assertEqual(5, util:to_integer(5)),
    ?assertError(badarg, util:to_integer(<<"abc">>)),
    ?assertError(badarg, util:to_integer(some_atom)),
    ok.

to_integer_maybe_test() ->
    ?assertEqual(5, util:to_integer_maybe("5")),
    ?assertEqual(undefined, util:to_integer_maybe("abc")),
    ok.

to_float_test() ->
    ?assertEqual(1.2, util:to_float("1.2")),
    ?assertEqual(1.0, util:to_float("1")),
    ?assertEqual(1.2, util:to_float(<<"1.2">>)),
    ?assertEqual(1.2, util:to_float(1.2)),
    ?assertEqual(1.0, util:to_float(1)),
    ?assertError(badarg, util:to_float(foo)),
    ?assertError(badarg, util:to_float("1.2bla")),
    ?assertError(badarg, util:to_float("bla1.2")),
    ok.

to_float_maybe_test() ->
    ?assertEqual(1.2, util:to_float_maybe("1.2")),
    ?assertEqual(undefined, util:to_float_maybe(foo)),
    ok.

to_atom_test() ->
    ?assertEqual(foo, util:to_atom("foo")),
    ?assertEqual(foo, util:to_atom(<<"foo">>)),
    ?assertEqual(false, util:to_atom(false)),
    ?assertEqual(foo, util:to_atom(foo)),
    ?assertError(badarg, util:to_atom(34)),
    ok.

to_atom_maybe_test() ->
    ?assertEqual(foo, util:to_atom_maybe("foo")),
    ?assertEqual(undefined, util:to_atom_maybe(34)),
    ok.

to_binary_test() ->
    ?assertEqual(<<"foo">>, util:to_binary(<<"foo">>)),
    ?assertEqual(<<"foo">>, util:to_binary("foo")),
    ?assertEqual(<<"5">>, util:to_binary(5)),
    ?assertEqual(<<"5.5">>, util:to_binary(5.5)),
    ?assertEqual(<<"false">>, util:to_binary(false)),
    ?assertEqual(<<"foo">>, util:to_binary(foo)),
    ?assertError(badarg, util:to_binary(#{})),
    ok.

to_binary_maybe_test() ->
    ?assertEqual(<<"foo">>, util:to_binary_maybe("foo")),
    ?assertEqual(<<>>, util:to_binary_maybe(#{})),
    ok.

to_list_test() ->
    ?assertEqual("foo", util:to_list("foo")),
    ?assertEqual("foo", util:to_list(<<"foo">>)),
    ?assertEqual("1", util:to_list(1)),
    ?assertEqual("1.0", util:to_list(1.0)),
    ?assertEqual("true", util:to_list(true)),
    ?assertEqual("foo", util:to_list(foo)),
    ?assertError(badarg, util:to_list(#{})),
    ok.

to_list_maybe_test() ->
    ?assertEqual("foo", util:to_list_maybe(<<"foo">>)),
    ?assertEqual(undefined, util:to_list_maybe(#{})),
    ok.


list_to_map_test() ->
    ?assertEqual(#{}, util:list_to_map([])),
    ?assertEqual(#{k1 => v1}, util:list_to_map([k1, v1])),
    ?assertEqual(#{k1 => v1, k2 => v2}, util:list_to_map([k1, v1, k2, v2])),
    ?assertError(badarg, util:list_to_map([k1, v1, foo])),
    ok.
