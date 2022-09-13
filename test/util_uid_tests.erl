%%%-------------------------------------------------------------------
%%% @author nikola
%%% @copyright (C) 2020, Halloapp Inc.
%%% @doc
%%%
%%% @end
%%% Created : 19. Mar 2020 1:32 PM
%%%-------------------------------------------------------------------
-module(util_uid_tests).
-author("nikola").

-include_lib("eunit/include/eunit.hrl").


test_generate_uid(_) ->
    {ok, Uid} = util_uid:generate_uid(),
    X = re:run(Uid, "1000000000[0-9]{9}"),
    {inparallel, [
        ?_assertEqual(19, byte_size(Uid)),
        ?_assertEqual({match, [{0, 19}]}, X)
    ]}.

test_generate_uid_shard_region(_) ->
    {ok, Uid} = util_uid:generate_uid(2, 42),
    X = re:run(Uid, "2000000042[0-9]{9}"),
    [?_assertEqual({match, [{0, 19}]}, X)].

test_generate_uid_invalid_region(_) ->
    {inparallel, [
        ?_assertEqual({error, invalid_region}, util_uid:generate_uid(20, 100)),
        ?_assertEqual({error, invalid_region}, util_uid:generate_uid("foo", 100)),
        ?_assertEqual({error, invalid_region}, util_uid:generate_uid(foo, 100)),
        ?_assertEqual({error, invalid_region}, util_uid:generate_uid(0, 100))
    ]}.

test_generate_uid_invalid_shard(_) ->
    {inparallel, [
        ?_assertEqual({error, invalid_shard}, util_uid:generate_uid(1, 1000000)),
        ?_assertEqual({error, invalid_shard}, util_uid:generate_uid(1, "foo")),
        ?_assertEqual({error, invalid_shard}, util_uid:generate_uid(1, -1))
    ]}.

uid_size_test(_) ->
    [?_assertEqual(19, util_uid:uid_size())].


test_looks_like_uid(_) ->
    {ok, FreshUid} = util_uid:generate_uid(),
    {inparallel, [
        ?_assert(util_uid:looks_like_uid(FreshUid)),
        ?_assert(util_uid:looks_like_uid(<<"1000000000000000001">>)), 
        ?_assertNot(util_uid:looks_like_uid(<<"10000000000000000001">>)), % too long
        ?_assertNot(util_uid:looks_like_uid(<<"0">>)), %too short
        ?_assertNot(util_uid:looks_like_uid("string")) % wrong type
    ]}.

do_util_uid_test_() ->
    % Note, this is an unnecessary amount of complexity -- all of these test functions could just end
    % in _test_() and work great. It's just nice to parallelize to make our tests go super fast
    tutil:true_parallel([
        fun test_generate_uid/1,
        fun test_generate_uid_shard_region/1,
        fun test_generate_uid_invalid_region/1,
        fun test_generate_uid_invalid_shard/1,
        fun uid_size_test/1,
        fun test_looks_like_uid/1
    ]).
