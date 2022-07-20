%%%-------------------------------------------------------------------
%%% @author nikola
%%% @copyright (C) 2020, Halloapp Inc.
%%% @doc
%%%
%%% @end
%%% Created : 19. Mar 2020 1:32 PM
%%%-------------------------------------------------------------------
-module(model_friends_tests).
-author("nikola").

-include_lib("eunit/include/eunit.hrl").

-define(UID1, <<"1000000000376503286">>).
-define(UID2, <<"1000000000789004561">>).
-define(UID3, <<"1000000000565604444">>).

setup() ->
  tutil:setup(),
  ha_redis:start(),
  clear(),
  ok.

clear() ->
  tutil:cleardb(redis_friends).

add_friend_test() ->
  setup(),
  ?assertEqual(ok, model_friends:add_friend(?UID1, ?UID2)),
  ?assertEqual(true, model_friends:is_friend(?UID1, ?UID2)),
  ?assertEqual(true, model_friends:is_friend(?UID2, ?UID1)),
  ?assertEqual(false, model_friends:is_friend(?UID3, ?UID1)),
  ?assertEqual(false, model_friends:is_friend(?UID1, ?UID3)).


add_friends_test() ->
  setup(),
  ?assertEqual(ok, model_friends:add_friends(?UID1, [?UID2, ?UID3])),
  ?assertEqual(true, model_friends:is_friend(?UID1, ?UID2)),
  ?assertEqual(true, model_friends:is_friend(?UID2, ?UID1)),
  ?assertEqual(true, model_friends:is_friend(?UID3, ?UID1)),
  ?assertEqual(true, model_friends:is_friend(?UID1, ?UID3)),
  ?assertEqual(false, model_friends:is_friend(?UID3, ?UID2)),
  ?assertEqual(false, model_friends:is_friend(?UID2, ?UID3)).

is_friend_test() ->
  setup(),
  ?assertEqual(false, model_friends:is_friend(?UID1, ?UID2)),
  ?assertEqual(ok, model_friends:add_friend(?UID1, ?UID2)),
  ?assertEqual(true, model_friends:is_friend(?UID1, ?UID2)),
  ?assertEqual(true, model_friends:is_friend(?UID2, ?UID1)).

del_friend_test() ->
  setup(),
  ?assertEqual(ok, model_friends:add_friend(?UID1, ?UID2)),
  ?assertEqual(ok, model_friends:add_friend(?UID1, ?UID3)),
  ?assertEqual(true, model_friends:is_friend(?UID1, ?UID2)),
  ?assertEqual(true, model_friends:is_friend(?UID2, ?UID1)),
  ?assertEqual(true, model_friends:is_friend(?UID3, ?UID1)),
  ?assertEqual(true, model_friends:is_friend(?UID1, ?UID3)),
  ?assertEqual(ok, model_friends:remove_friend(?UID1, ?UID2)),
  ?assertEqual(false, model_friends:is_friend(?UID1, ?UID2)),
  ?assertEqual(false, model_friends:is_friend(?UID2, ?UID1)),
  ?assertEqual(true, model_friends:is_friend(?UID1, ?UID3)),
  ?assertEqual(ok, model_friends:remove_friend(?UID1, ?UID3)),
  ?assertEqual(false, model_friends:is_friend(?UID1, ?UID3)).

get_friends_test() ->
  setup(),
  ?assertEqual(ok, model_friends:add_friend(?UID1, ?UID2)),
  ?assertEqual(ok, model_friends:add_friend(?UID1, ?UID3)),
  ?assertEqual({ok, [?UID2, ?UID3]}, model_friends:get_friends(?UID1)),
  ?assertEqual(ok, model_friends:remove_friend(?UID1, ?UID3)),
  ?assertEqual({ok, [?UID2]}, model_friends:get_friends(?UID1)).

get_empty_friends_test() ->
  setup(),
  ?assertEqual({ok, []}, model_friends:get_friends(?UID1)).

get_friends_multi_test() ->
  setup(),
  ?assertEqual(ok, model_friends:add_friend(?UID1, ?UID2)),
  ?assertEqual(ok, model_friends:add_friend(?UID1, ?UID3)),
  FriendMap = #{
    ?UID1 => [?UID2, ?UID3],
    ?UID2 => [?UID1],
    ?UID3 => [?UID1]  
  },
  ?assertEqual({ok, FriendMap}, model_friends:get_friends([?UID1, ?UID2, ?UID3])),
  ?assertEqual(ok, model_friends:remove_friend(?UID1, ?UID3)),
  FriendMap1 = #{
    ?UID1 => [?UID2],
    ?UID2 => [?UID1],
    ?UID3 => []  
  },
  ?assertEqual({ok, FriendMap1}, model_friends:get_friends([?UID1, ?UID2, ?UID3])).

get_empty_friends_multi_test() ->
  setup(),
  EmptyFriendMap = #{
    ?UID1 => [],
    ?UID2 => [],
    ?UID3 => []  
  },
  ?assertEqual({ok, EmptyFriendMap}, model_friends:get_friends([?UID1, ?UID2, ?UID3])).

set_friends_test() ->
  setup(),
  ?assertEqual(ok, model_friends:set_friends(?UID1, [?UID2, ?UID3])),
  ?assertEqual({ok, [?UID2, ?UID3]}, model_friends:get_friends(?UID1)).

remove_all_friends_test() ->
  setup(),
  ?assertEqual(ok, model_friends:add_friend(?UID1, ?UID2)),
  ?assertEqual(ok, model_friends:add_friend(?UID1, ?UID3)),
  ?assertEqual(ok, model_friends:remove_all_friends(?UID1)),
  ?assertEqual(false, model_friends:is_friend(?UID1, ?UID2)),
  ?assertEqual(false, model_friends:is_friend(?UID2, ?UID1)),
  ?assertEqual(false, model_friends:is_friend(?UID1, ?UID3)),
  ?assertEqual(false, model_friends:is_friend(?UID3, ?UID1)),
  ?assertEqual(ok, model_friends:remove_all_friends(?UID2)),
  ?assertEqual(false, model_friends:is_friend(?UID1, ?UID2)),
  ?assertEqual(false, model_friends:is_friend(?UID2, ?UID1)).


set_get_friend_recommendations_test() ->
  setup(),
  ?assertEqual([], model_friends:get_friend_recommendations(?UID1)),
  ?assertEqual(ok, model_friends:set_friend_recommendations(?UID1, [?UID2, ?UID3])),
  ?assertEqual([?UID2, ?UID3], model_friends:get_friend_recommendations(?UID1)),
  ?assertEqual([?UID2], model_friends:get_friend_recommendations(?UID1, 1)).

set_get_friend_recommendations_multi_test() ->
  setup(),
  Uids = [?UID1, ?UID2, ?UID3],
  UidRecList = [{?UID1, [?UID2, ?UID3]}, {?UID2, [?UID3]}],
  ?assertEqual(
    #{?UID1 => [], ?UID2 => [], ?UID3 => []}, 
    model_friends:get_friend_recommendations(Uids)),
  ?assertEqual(ok, model_friends:set_friend_recommendations(UidRecList)),
  ?assertEqual(
    #{?UID1 => [?UID2, ?UID3], ?UID2 => [?UID3], ?UID3 => []}, 
    model_friends:get_friend_recommendations(Uids)).


while(0, _F) -> ok;
while(N, F) ->
  erlang:apply(F, [N]),
  while(N -1, F).

perf_test() ->
  setup(),
  N = 10, %% Set to N=100000 to do
  StartTime = util:now_ms(),
  while(N, fun(X) ->
    ok = model_friends:add_friend(integer_to_binary(1), integer_to_binary(X + 1000))
           end),
  EndTime = util:now_ms(),
  T = EndTime - StartTime,
%%  ?debugFmt("~w operations took ~w ms => ~f ops ", [N, T, N / (T / 1000)]),
  {ok, T}.

