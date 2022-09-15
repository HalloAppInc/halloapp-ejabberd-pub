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

-include("tutil.hrl").

-define(UID1, <<"1000000000376503286">>).
-define(UID2, <<"1000000000789004561">>).
-define(UID3, <<"1000000000565604444">>).
-define(UID4, <<"1000000000669309703">>).


setup() ->
  tutil:setup([
      {redis, [redis_friends]}
  ]).

% Set up a generic friend network for use in tests
% These exact calls are tested in add_friends_testset
setup_friends() ->
  CleanupInfo = setup(),
  ok = model_friends:add_friend(?UID1, ?UID2),
  ok = model_friends:add_friends(?UID3, [?UID1, ?UID2]),
  CleanupInfo.


%% -------------------------------------------- %%
%% Testsets for Friendship API
%% --------------------------------------------	%%
is_friend_empty_testset(_) ->
  NotFriends = model_friends:is_friend(?UID1, ?UID2),
  [?_assertNot(NotFriends)].

get_empty_friends_testset(_) ->
  EmptyFriends = model_friends:get_friends(?UID1),
  [?_assertEqual({ok, []}, EmptyFriends)].

get_empty_friends_multi_testset(_) ->
  EmptyFriendMap = #{
    ?UID1 => [],
    ?UID2 => [],
    ?UID3 => []  
  },
  EmptyRes = model_friends:get_friends([?UID1, ?UID2, ?UID3]),
  [?_assertEqual({ok, EmptyFriendMap}, EmptyRes)].


% Tests everything done in setup_friends
add_friends_testset(_) ->
  % adding single friend
  ?assertOk(model_friends:add_friend(?UID1, ?UID2)),
  Friend12 = model_friends:is_friend(?UID1, ?UID2),
  Friend21 = model_friends:is_friend(?UID2, ?UID1),
  NotFriend13 = model_friends:is_friend(?UID1, ?UID3),
  NotFriend23 = model_friends:is_friend(?UID2, ?UID3),
  SingleAddTests = [
    ?_assert(Friend12),
    ?_assert(Friend21),
    ?_assertNot(NotFriend13),
    ?_assertNot(NotFriend23)
  ],
  % Adding multiple friends
  ?assertOk(model_friends:add_friends(?UID3, [?UID1, ?UID2])),
  Friend13 = model_friends:is_friend(?UID1, ?UID3),
  Friend31 = model_friends:is_friend(?UID3, ?UID1),
  Friend23 = model_friends:is_friend(?UID2, ?UID3),
  Friend32 = model_friends:is_friend(?UID3, ?UID2),
  MultiAddTests = [
    ?_assert(Friend13),
    ?_assert(Friend31),
    ?_assert(Friend23),
    ?_assert(Friend32)
  ],
  
  [SingleAddTests, MultiAddTests].


set_get_friend_scores_testset(_) ->
  FriendScoreMap = #{?UID2 => 2, ?UID3 => 3},
  EmptyScores = model_friends:get_friend_scores(?UID1),
  ok = model_friends:set_friend_scores(?UID1, FriendScoreMap),
  FullScores =  model_friends:get_friend_scores(?UID1),
  [?_assertEqual({ok, #{}}, EmptyScores), ?_assertEqual({ok, FriendScoreMap}, FullScores)].


%% -------------------------------------------- %%
%% Manual test fixture
%% --------------------------------------------	%%
setup_friends_test_() ->
  tutil:setup_foreach(fun setup_friends/0, [
      fun setup_friends_del_friend/1,
      fun setup_friends_get_friends/1,
      fun setup_friends_set_friends/1,
      fun setup_friends_remove_all_friends/1
    ]).


%% ------------------------------------------------- %%
%% Tests that use state set up by setup_friends/0:
%%    - ?UID1 friends with ?UID2 & ?UID3,
%%    - ?UID2 friends with ?UID1 & ?UID3,
%%    - ?UID3 friends with ?UID1 & ?UID2,
%%    - ?UID4 friends with nobody. 
%% -------------------------------------------------	%%
setup_friends_del_friend(_) ->
  Friend12Before = model_friends:is_friend(?UID1, ?UID2),
  Friend21Before = model_friends:is_friend(?UID2, ?UID1),
  ?assertOk(model_friends:remove_friend(?UID1, ?UID2)),
  NotFriend12 = model_friends:is_friend(?UID1, ?UID2),
  NotFriend21 = model_friends:is_friend(?UID2, ?UID1),
  Friend13 = model_friends:is_friend(?UID1, ?UID3),
  ?assertOk(model_friends:remove_friend(?UID1, ?UID3)),
  NotFriend13 = model_friends:is_friend(?UID1, ?UID3),
  NotFriend31 = model_friends:is_friend(?UID3, ?UID1),
  [
    ?_assert(Friend12Before), ?_assert(Friend21Before),
    ?_assertNot(NotFriend12), ?_assertNot(NotFriend21), ?_assert(Friend13), 
    ?_assertNot(NotFriend13), ?_assertNot(NotFriend31)
  ].


setup_friends_get_friends(_) ->
  {ok, Uid1Friends} = model_friends:get_friends(?UID1),
  {ok, FriendMap1} = model_friends:get_friends([?UID1, ?UID2, ?UID3]),
  ?assertOk(model_friends:remove_friend(?UID1, ?UID3)),
  {ok, Uid1Friends2} = model_friends:get_friends(?UID1),
  {ok, FriendMap2} = model_friends:get_friends([?UID1, ?UID2, ?UID3]),

  SingleTests = [
    ?_assertEqual(sets:from_list([?UID2, ?UID3]), sets:from_list(Uid1Friends)),
    ?_assertEqual(sets:from_list([?UID2]), sets:from_list(Uid1Friends2))
  ],
  MultiTests = [
    ?_assertEqual(sets:from_list([?UID2, ?UID3]), sets:from_list(maps:get(?UID1, FriendMap1))),
    ?_assertEqual(sets:from_list([?UID1, ?UID3]), sets:from_list(maps:get(?UID2, FriendMap1))),
    ?_assertEqual(sets:from_list([?UID1, ?UID2]), sets:from_list(maps:get(?UID3, FriendMap1))),
    ?_assertEqual([?UID2], maps:get(?UID1, FriendMap2)),
    ?_assertEqual(sets:from_list([?UID1, ?UID3]), sets:from_list(maps:get(?UID2, FriendMap2))),
    ?_assertEqual([?UID2], maps:get(?UID3, FriendMap2))
  ],

  [SingleTests, MultiTests].


setup_friends_set_friends(_) ->
  TrueUid1Friends = [?UID2, ?UID4],
  ?assertOk(model_friends:set_friends(?UID1, TrueUid1Friends)),
  {ok, Uid1Friends} = model_friends:get_friends(?UID1),

  [?_assertEqual(sets:from_list(TrueUid1Friends), sets:from_list(Uid1Friends))].


setup_friends_remove_all_friends(_) ->
  ?assertOk(model_friends:remove_all_friends(?UID1)),
  {ok, Uid1FriendsPost} = model_friends:get_friends(?UID1),
  NotFriend21 = model_friends:is_friend(?UID2, ?UID1),
  NotFriend31 = model_friends:is_friend(?UID3, ?UID1),
  [
    ?_assertEqual([], Uid1FriendsPost), 
    ?_assertNot(NotFriend21), 
    ?_assertNot(NotFriend31)
  ].


% perf_setup() ->
%   tutil:setup(),
%   ha_redis:start(),
%   clear(),
%   ok.

% clear() ->
%   tutil:cleardb(redis_friends).

% while(0, _F) -> ok;
% while(N, F) ->
%   erlang:apply(F, [N]),
%   while(N -1, F).

% perf_test() ->
%   perf_setup(),
%   N = 10, %% Set to N=100000 to do
%   StartTime = util:now_ms(),
%   while(N, fun(X) ->
%     ok = model_friends:add_friend(integer_to_binary(1), integer_to_binary(X + 1000))
%            end),
%   EndTime = util:now_ms(),
%   T = EndTime - StartTime,
% %%  ?debugFmt("~w operations took ~w ms => ~f ops ", [N, T, N / (T / 1000)]),
%   {ok, T}.

