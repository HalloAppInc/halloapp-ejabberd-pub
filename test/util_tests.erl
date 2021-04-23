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
