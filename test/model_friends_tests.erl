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


incoming_outgoing_friend_testset() ->
  [%% UID1 and UID2 should have no added or pending friends
  ?_assertEqual([], model_friends:get_outgoing_friends(?UID1)),
  ?_assertNot(model_friends:is_outgoing(?UID1, ?UID2)),
  ?_assertEqual([], model_friends:get_incoming_friends(?UID1)),
  ?_assertNot(model_friends:is_incoming(?UID1, ?UID2)),
  ?_assertEqual([], model_friends:get_outgoing_friends(?UID2)),
  ?_assertNot(model_friends:is_outgoing(?UID2, ?UID1)),
  ?_assertEqual([], model_friends:get_incoming_friends(?UID2)),
  ?_assertNot(model_friends:is_incoming(?UID2, ?UID1)),
  %% UID1 adds UID2
  ?_assertOk(model_friends:add_outgoing_friend(?UID1, ?UID2)),
  %% UID1 has UID2 as added; UID2 has UID1 as pending
  ?_assertEqual([?UID2], model_friends:get_outgoing_friends(?UID1)),
  ?_assert(model_friends:is_outgoing(?UID1, ?UID2)),
  ?_assertEqual([], model_friends:get_incoming_friends(?UID1)),
  ?_assertNot(model_friends:is_incoming(?UID1, ?UID2)),
  ?_assertEqual([], model_friends:get_outgoing_friends(?UID2)),
  ?_assertNot(model_friends:is_outgoing(?UID2, ?UID1)),
  ?_assertEqual([?UID1], model_friends:get_incoming_friends(?UID2)),
  ?_assert(model_friends:is_incoming(?UID2, ?UID1)),
  %% UID1 revokes their add
  ?_assertOk(model_friends:remove_outgoing_friend(?UID1, ?UID2)),
  %% UID1 and UID2 should have no added or pending friends
  ?_assertEqual([], model_friends:get_outgoing_friends(?UID1)),
  ?_assertNot(model_friends:is_outgoing(?UID1, ?UID2)),
  ?_assertEqual([], model_friends:get_incoming_friends(?UID1)),
  ?_assertNot(model_friends:is_incoming(?UID1, ?UID2)),
  ?_assertEqual([], model_friends:get_outgoing_friends(?UID2)),
  ?_assertNot(model_friends:is_outgoing(?UID2, ?UID1)),
  ?_assertEqual([], model_friends:get_incoming_friends(?UID2)),
  ?_assertNot(model_friends:is_incoming(?UID2, ?UID1)),
  %% UID1 adds UID2 again
  ?_assertOk(model_friends:add_outgoing_friend(?UID1, ?UID2)),
  %% This time, UID2 responds, rejects pending request
  ?_assertNot(model_friends:is_ignored(?UID2, ?UID1)),
  ?_assertNot(model_friends:is_ignored(?UID1, ?UID2)),
  ?_assertOk(model_friends:ignore_incoming_friend(?UID2, ?UID1)),
  ?_assert(model_friends:is_ignored(?UID2, ?UID1)),
  ?_assertNot(model_friends:is_ignored(?UID1, ?UID2)),
  %% UID1 should still have an outgoing friend request, but UID2 should have none incoming requests
  ?_assertEqual([?UID2], model_friends:get_outgoing_friends(?UID1)),
  ?_assert(model_friends:is_outgoing(?UID1, ?UID2)),
  ?_assertEqual([], model_friends:get_incoming_friends(?UID1)),
  ?_assertNot(model_friends:is_incoming(?UID1, ?UID2)),
  ?_assertEqual([], model_friends:get_outgoing_friends(?UID2)),
  ?_assertNot(model_friends:is_outgoing(?UID2, ?UID1)),
  ?_assertEqual([], model_friends:get_incoming_friends(?UID2)),
  ?_assertNot(model_friends:is_incoming(?UID2, ?UID1))].

block_unblock_testset() ->
  %% model doesn't control the ability to add when blocked, so it isn't tested here
  %% just testing that blocking/unblocking modify data as required
  [%% UID1 adds UID2; UID3 adds UID1; UID1 and UID4 are friends; no one is blocked
  ?_assertOk(model_friends:add_outgoing_friend(?UID1, ?UID2)),
  ?_assertOk(model_friends:add_outgoing_friend(?UID3, ?UID1)),
  ?_assertOk(model_friends:add_friend(?UID1, ?UID4)),
  ?_assertNot(model_friends:is_blocked(?UID2, ?UID1)),
  ?_assertNot(model_friends:is_blocked(?UID3, ?UID1)),
  ?_assertNot(model_friends:is_blocked(?UID4, ?UID1)),
  ?_assertNot(model_friends:is_blocked_by(?UID2, ?UID1)),
  ?_assertNot(model_friends:is_blocked_by(?UID3, ?UID1)),
  ?_assertNot(model_friends:is_blocked_by(?UID4, ?UID1)),
  ?_assertNot(model_friends:is_blocked_any(?UID2, ?UID1)),
  ?_assertNot(model_friends:is_blocked_any(?UID3, ?UID1)),
  ?_assertNot(model_friends:is_blocked_any(?UID4, ?UID1)),
  ?_assertEqual([], model_friends:get_blocked_uids(?UID1)),
  ?_assertEqual([], model_friends:get_blocked_uids(?UID2)),
  ?_assertEqual([], model_friends:get_blocked_uids(?UID3)),
  ?_assertEqual([], model_friends:get_blocked_uids(?UID4)),
  %% UID 1 should have: UID2 added, UID3 pending, UID4 friends
  ?_assertEqual([?UID2], model_friends:get_outgoing_friends(?UID1)),
  ?_assertEqual([?UID3], model_friends:get_incoming_friends(?UID1)),
  ?_assertEqual({ok, [?UID4]}, model_friends:get_friends(?UID1)),
  %% UID2, UID3, UID4 block UID1 :(
  ?_assertOk(model_friends:block(?UID2, ?UID1)),
  ?_assert(model_friends:is_blocked(?UID2, ?UID1)),
  ?_assert(model_friends:is_blocked_by(?UID1, ?UID2)),
  ?_assertNot(model_friends:is_blocked(?UID1, ?UID2)),
  ?_assertNot(model_friends:is_blocked_by(?UID2, ?UID1)),
  ?_assert(model_friends:is_blocked_any(?UID2, ?UID1)),
  ?_assertOk(model_friends:block(?UID3, ?UID1)),
  ?_assert(model_friends:is_blocked(?UID3, ?UID1)),
  ?_assert(model_friends:is_blocked_by(?UID1, ?UID3)),
  ?_assertNot(model_friends:is_blocked(?UID1, ?UID3)),
  ?_assertNot(model_friends:is_blocked_by(?UID3, ?UID1)),
  ?_assert(model_friends:is_blocked_any(?UID3, ?UID1)),
  ?_assertOk(model_friends:block(?UID4, ?UID1)),
  ?_assert(model_friends:is_blocked(?UID4, ?UID1)),
  ?_assert(model_friends:is_blocked_by(?UID1, ?UID4)),
  ?_assertNot(model_friends:is_blocked(?UID1, ?UID4)),
  ?_assertNot(model_friends:is_blocked_by(?UID4, ?UID1)),
  ?_assert(model_friends:is_blocked_any(?UID4, ?UID1)),
  ?_assertEqual([], model_friends:get_blocked_uids(?UID1)),
  ?_assertEqual([?UID1], model_friends:get_blocked_uids(?UID2)),
  ?_assertEqual([?UID1], model_friends:get_blocked_uids(?UID3)),
  ?_assertEqual([?UID1], model_friends:get_blocked_uids(?UID4)),
  %% UID1 should have no added, pending, or mutual friends
  ?_assertEqual([], model_friends:get_outgoing_friends(?UID1)),
  ?_assertEqual([], model_friends:get_incoming_friends(?UID1)),
  ?_assertEqual({ok, []}, model_friends:get_friends(?UID1)),
  %% UID2, UID3, UID4 unblock UID1 :)
  ?_assertOk(model_friends:unblock(?UID2, ?UID1)),
  ?_assertNot(model_friends:is_blocked(?UID2, ?UID1)),
  ?_assertNot(model_friends:is_blocked_by(?UID1, ?UID2)),
  ?_assertNot(model_friends:is_blocked_any(?UID1, ?UID2)),
  ?_assertOk(model_friends:unblock(?UID3, ?UID1)),
  ?_assertNot(model_friends:is_blocked(?UID3, ?UID1)),
  ?_assertNot(model_friends:is_blocked_by(?UID1, ?UID3)),
  ?_assertNot(model_friends:is_blocked_any(?UID1, ?UID3)),
  ?_assertOk(model_friends:unblock(?UID4, ?UID1)),
  ?_assertNot(model_friends:is_blocked(?UID4, ?UID1)),
  ?_assertNot(model_friends:is_blocked_by(?UID1, ?UID4)),
  ?_assertNot(model_friends:is_blocked_any(?UID1, ?UID4)),
  ?_assertEqual([], model_friends:get_blocked_uids(?UID1)),
  ?_assertEqual([], model_friends:get_blocked_uids(?UID2)),
  ?_assertEqual([], model_friends:get_blocked_uids(?UID3)),
  ?_assertEqual([], model_friends:get_blocked_uids(?UID4)),
  %% UID1 should have no added, pending, or mutual friends
  ?_assertEqual([], model_friends:get_outgoing_friends(?UID1)),
  ?_assertEqual([], model_friends:get_incoming_friends(?UID1)),
  ?_assertEqual({ok, []}, model_friends:get_friends(?UID1))].


remove_all_outgoing_friends_testset() ->
  Uid1 = tutil:generate_uid(?KATCHUP),
  Uid2 = tutil:generate_uid(?KATCHUP),
  Uid3 = tutil:generate_uid(?KATCHUP),
  Uid4 = tutil:generate_uid(?KATCHUP),
  [
    %% Uid1 sent outgoing friend requests to everyone, Uid2 sent to Uid3 as well
    ?_assertOk(model_friends:add_outgoing_friend(Uid1, Uid2)),
    ?_assertOk(model_friends:add_outgoing_friend(Uid1, Uid3)),
    ?_assertOk(model_friends:add_outgoing_friend(Uid1, Uid4)),
    ?_assertOk(model_friends:add_outgoing_friend(Uid2, Uid3)),
    ?_assert(model_friends:is_outgoing(Uid1, Uid2)),
    ?_assert(model_friends:is_outgoing(Uid1, Uid3)),
    ?_assert(model_friends:is_outgoing(Uid1, Uid4)),
    ?_assert(model_friends:is_outgoing(Uid2, Uid3)),
    ?_assert(model_friends:is_incoming(Uid2, Uid1)),
    ?_assert(model_friends:is_incoming(Uid3, Uid1)),
    ?_assert(model_friends:is_incoming(Uid4, Uid1)),
    ?_assert(model_friends:is_incoming(Uid3, Uid2)),
    %% Remove all of Uid1's outgoing friends
    ?_assertOk(model_friends:remove_all_outgoing_friends(Uid1)),
    %% Uid1 should not have outgoing friends with anyone nor should they have incoming fromm Uid1
    %% Relationship between Uid2 and Uid3 should remain the same
    ?_assertNot(model_friends:is_outgoing(Uid1, Uid2)),
    ?_assertNot(model_friends:is_outgoing(Uid1, Uid3)),
    ?_assertNot(model_friends:is_outgoing(Uid1, Uid4)),
    ?_assert(model_friends:is_outgoing(Uid2, Uid3)),
    ?_assertNot(model_friends:is_incoming(Uid2, Uid1)),
    ?_assertNot(model_friends:is_incoming(Uid3, Uid1)),
    ?_assertNot(model_friends:is_incoming(Uid4, Uid1)),
    ?_assert(model_friends:is_incoming(Uid3, Uid2))
  ].


remove_all_incoming_friends_testset() ->
  Uid1 = tutil:generate_uid(?KATCHUP),
  Uid2 = tutil:generate_uid(?KATCHUP),
  Uid3 = tutil:generate_uid(?KATCHUP),
  Uid4 = tutil:generate_uid(?KATCHUP),
  [
    %% everyone sent outgoing friend requests to Uid1, Uid2 sent to Uid3 as well
    ?_assertOk(model_friends:add_outgoing_friend(Uid2, Uid1)),
    ?_assertOk(model_friends:add_outgoing_friend(Uid3, Uid1)),
    ?_assertOk(model_friends:add_outgoing_friend(Uid4, Uid1)),
    ?_assertOk(model_friends:add_outgoing_friend(Uid2, Uid3)),
    ?_assert(model_friends:is_outgoing(Uid2, Uid1)),
    ?_assert(model_friends:is_outgoing(Uid3, Uid1)),
    ?_assert(model_friends:is_outgoing(Uid4, Uid1)),
    ?_assert(model_friends:is_outgoing(Uid2, Uid3)),
    ?_assert(model_friends:is_incoming(Uid1, Uid2)),
    ?_assert(model_friends:is_incoming(Uid1, Uid3)),
    ?_assert(model_friends:is_incoming(Uid1, Uid4)),
    ?_assert(model_friends:is_incoming(Uid3, Uid2)),
    %% Remove all of Uid1's outgoing friends
    ?_assertOk(model_friends:remove_all_incoming_friends(Uid1)),
    %% Uid1 should not have outgoing friends with anyone nor should they have incoming fromm Uid1
    %% Relationship between Uid2 and Uid3 should remain the same
    ?_assertNot(model_friends:is_outgoing(Uid2, Uid1)),
    ?_assertNot(model_friends:is_outgoing(Uid3, Uid1)),
    ?_assertNot(model_friends:is_outgoing(Uid4, Uid1)),
    ?_assert(model_friends:is_outgoing(Uid2, Uid3)),
    ?_assertNot(model_friends:is_incoming(Uid1, Uid2)),
    ?_assertNot(model_friends:is_incoming(Uid1, Uid3)),
    ?_assertNot(model_friends:is_incoming(Uid1, Uid4)),
    ?_assert(model_friends:is_incoming(Uid3, Uid2))
  ].


remove_all_blocked_friends_testset() ->
  Uid1 = tutil:generate_uid(?KATCHUP),
  Uid2 = tutil:generate_uid(?KATCHUP),
  Uid3 = tutil:generate_uid(?KATCHUP),
  Uid4 = tutil:generate_uid(?KATCHUP),
  [
    %% Uid1 blocks everyone, Uid2 blocks Uid1
    ?_assertOk(model_friends:block(Uid1, Uid2)),
    ?_assertOk(model_friends:block(Uid1, Uid3)),
    ?_assertOk(model_friends:block(Uid1, Uid4)),
    ?_assertOk(model_friends:block(Uid2, Uid1)),
    ?_assert(model_friends:is_blocked(Uid1, Uid2)),
    ?_assert(model_friends:is_blocked(Uid1, Uid3)),
    ?_assert(model_friends:is_blocked(Uid1, Uid4)),
    ?_assert(model_friends:is_blocked(Uid2, Uid1)),
    ?_assert(model_friends:is_blocked_by(Uid2, Uid1)),
    ?_assert(model_friends:is_blocked_by(Uid3, Uid1)),
    ?_assert(model_friends:is_blocked_by(Uid4, Uid1)),
    ?_assert(model_friends:is_blocked_by(Uid1, Uid2)),
    %% Remove all of Uid1's blocks
    ?_assertOk(model_friends:remove_all_blocked_uids(Uid1)),
    %% Uid1 should be blocking no one and no one should be blocked by Uid1
    %% Uid2 should still have Uid3 blocked
    ?_assertNot(model_friends:is_blocked(Uid1, Uid2)),
    ?_assertNot(model_friends:is_blocked(Uid1, Uid3)),
    ?_assertNot(model_friends:is_blocked(Uid1, Uid4)),
    ?_assert(model_friends:is_blocked(Uid2, Uid1)),
    ?_assertNot(model_friends:is_blocked_by(Uid2, Uid1)),
    ?_assertNot(model_friends:is_blocked_by(Uid3, Uid1)),
    ?_assertNot(model_friends:is_blocked_by(Uid4, Uid1)),
    ?_assert(model_friends:is_blocked_by(Uid1, Uid2))
  ].


remove_all_blocked_by_friends_testset() ->
  Uid1 = tutil:generate_uid(?KATCHUP),
  Uid2 = tutil:generate_uid(?KATCHUP),
  Uid3 = tutil:generate_uid(?KATCHUP),
  Uid4 = tutil:generate_uid(?KATCHUP),
  [
    %% Everyone blocks Uid1, Uid1 blocks Uid2
    ?_assertOk(model_friends:block(Uid2, Uid1)),
    ?_assertOk(model_friends:block(Uid3, Uid1)),
    ?_assertOk(model_friends:block(Uid4, Uid1)),
    ?_assertOk(model_friends:block(Uid1, Uid2)),
    ?_assert(model_friends:is_blocked(Uid2, Uid1)),
    ?_assert(model_friends:is_blocked(Uid3, Uid1)),
    ?_assert(model_friends:is_blocked(Uid4, Uid1)),
    ?_assert(model_friends:is_blocked(Uid1, Uid2)),
    ?_assert(model_friends:is_blocked_by(Uid1, Uid2)),
    ?_assert(model_friends:is_blocked_by(Uid1, Uid3)),
    ?_assert(model_friends:is_blocked_by(Uid1, Uid4)),
    ?_assert(model_friends:is_blocked_by(Uid2, Uid1)),
    %% Remove all of Uid1's blocks
    ?_assertOk(model_friends:remove_all_blocked_by_uids(Uid1)),
    %% Uid1 should be blocking no one and no one should be blocked by Uid1
    %% Uid2 should still have Uid3 blocked
    ?_assertNot(model_friends:is_blocked(Uid2, Uid1)),
    ?_assertNot(model_friends:is_blocked(Uid3, Uid1)),
    ?_assertNot(model_friends:is_blocked(Uid4, Uid1)),
    ?_assert(model_friends:is_blocked(Uid1, Uid2)),
    ?_assertNot(model_friends:is_blocked_by(Uid1, Uid2)),
    ?_assertNot(model_friends:is_blocked_by(Uid1, Uid3)),
    ?_assertNot(model_friends:is_blocked_by(Uid1, Uid4)),
    ?_assert(model_friends:is_blocked_by(Uid2, Uid1))
  ].

%% -------------------------------------------- %%
%% Manual test fixture
%% --------------------------------------------	%%
setup_friends_test_() ->
  tutil:setup_foreach(fun setup_friends/0, [
      fun setup_friends_del_friend/1,
      fun setup_friends_get_friends/1,
      fun setup_friends_remove_all_friends/1,
      fun setup_friends_get_mutual_friends/1
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


setup_friends_get_mutual_friends(_) ->
  [?_assertEqual([?UID1], model_friends:get_mutual_friends(?UID2, ?UID3)),
  ?_assertEqual([?UID1], model_friends:get_mutual_friends(?UID3, ?UID2)),
  ?_assertEqual(1, model_friends:get_mutual_friends_count(?UID3, ?UID2)),
  ?_assertEqual([?UID3], model_friends:get_mutual_friends(?UID1, ?UID2))].


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

