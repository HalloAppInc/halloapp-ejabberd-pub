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

setup() ->
  redis_sup:start_link(),
  clear(),
  model_friends:start_link(),
  ok.

clear() ->
  ok = gen_server:cast(redis_friends_client, flushdb).

add_friend_test() ->
  setup(),
  {ok, true} = model_friends:add_friend(1, 2),
  {ok, false} = model_friends:add_friend(1, 2).

is_friend_test() ->
  setup(),
  {ok, false} = model_friends:is_friend(1, 2),
  {ok, true} = model_friends:add_friend(1, 2),
  {ok, true} = model_friends:is_friend(1, 2).

del_friend_test() ->
  setup(),
  {ok, true} = model_friends:add_friend(1, 2),
  {ok, true} = model_friends:is_friend(1, 2),
  {ok, true} = model_friends:remove_friend(1, 2),
  {ok, false} = model_friends:is_friend(1, 2).

get_friends_test() ->
  setup(),
  {ok, true} = model_friends:add_friend(1, 2),
  {ok, true} = model_friends:add_friend(1, 3),
  {ok, [2, 3]} = model_friends:get_friends(1),
  {ok, true} = model_friends:remove_friend(1, 3),
  {ok, [2]} = model_friends:get_friends(1).

get_empty_friends_test() ->
  setup(),
  {ok, []} = model_friends:get_friends(1).

set_friends_test() ->
  setup(),
  {ok, 2} = model_friends:set_friends(1, [2, 3]),
  {ok, [2, 3]} = model_friends:get_friends(1).

remove_all_friends_test() ->
  setup(),
  model_friends:add_friend(1, 2),
  model_friends:add_friend(1, 3),
  {ok, true} = model_friends:remove_all_friends(1),
  {ok, false} = model_friends:remove_all_friends(2).

while(0, _F) -> ok;
while(N, F) ->
  erlang:apply(F, [N]),
  while(N -1, F).

perf_test() ->
  setup(),
  N = 10, %% Set to N=100000 to do
  StartTime = util:now_ms(),
  while(N, fun(X) ->
    {ok, true} = model_friends:add_friend(1, X + 1000)
           end),
  EndTime = util:now_ms(),
  T = EndTime - StartTime,
%%  ?debugFmt("~w operations took ~w ms => ~f ops ", [N, T, N / (T / 1000)]),
  {ok, T}.
