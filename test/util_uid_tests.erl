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


generate_uid_test() ->
  {ok, Uid} = util_uid:generate_uid(),
  ?assertEqual(19, string:len(integer_to_list(Uid))),
  ?debugVal(Uid),
  X = re:run(integer_to_list(Uid), "1000000000[0-9]{9}"),
  ?assertEqual({match, [{0, 19}]}, X),
  ok.

generate_uid_shard_region_test() ->
  {ok, Uid} = util_uid:generate_uid(2, 42),
  ?debugVal(Uid),
  X = re:run(integer_to_list(Uid), "2000000042[0-9]{9}"),
  ?assertEqual({match, [{0, 19}]}, X),
  ok.

generate_uid_invalid_region_test() ->
  {error, invalid_region} = util_uid:generate_uid(20, 100),
  {error, invalid_region} = util_uid:generate_uid("foo", 100),
  {error, invalid_region} = util_uid:generate_uid(foo, 100),
  {error, invalid_region} = util_uid:generate_uid(0, 100),
  ok.

generate_uid_invalid_shard_test() ->
  {error, invalid_shard} = util_uid:generate_uid(1, 1000000),
  {error, invalid_shard} = util_uid:generate_uid(1, "foo"),
  {error, invalid_shard} = util_uid:generate_uid(1, -1),
  ok.