%%%-------------------------------------------------------------------
%%% @author josh
%%% @copyright (C) 2022, HalloApp, Inc.
%%% @doc
%%%
%%% @end
%%%-------------------------------------------------------------------
-module(model_follow_tests).
-author("josh").

-include("tutil.hrl").

-define(USERS_PER_PAGE, 3).

setup() ->
    tutil:setup([
        {redis, [redis_friends]}
    ]).

%%====================================================================
%% Tests
%%====================================================================

follow_unfollow_testparallel() ->
    Uid1 = tutil:generate_uid(?KATCHUP),
    Uid2 = tutil:generate_uid(?KATCHUP),
    [
        %% No one is following each other
        ?_assertNot(model_follow:is_following(Uid1, Uid2)),
        ?_assertNot(model_follow:is_following(Uid2, Uid1)),
        ?_assertNot(model_follow:is_follower(Uid1, Uid2)),
        ?_assertNot(model_follow:is_follower(Uid2, Uid1)),
        %% Uid1 follows Uid2
        ?_assertOk(model_follow:follow(Uid1, Uid2)),
        ?_assert(model_follow:is_following(Uid1, Uid2)),
        ?_assertNot(model_follow:is_following(Uid2, Uid1)),
        ?_assertNot(model_follow:is_follower(Uid1, Uid2)),
        ?_assert(model_follow:is_follower(Uid2, Uid1)),
        %% Uid2 follows Uid1
        ?_assertOk(model_follow:follow(Uid2, Uid1)),
        ?_assert(model_follow:is_following(Uid1, Uid2)),
        ?_assert(model_follow:is_following(Uid2, Uid1)),
        ?_assert(model_follow:is_follower(Uid1, Uid2)),
        ?_assert(model_follow:is_follower(Uid2, Uid1)),
        %% Uid1 unfollows Uid2
        ?_assertOk(model_follow:unfollow(Uid1, Uid2)),
        ?_assertNot(model_follow:is_following(Uid1, Uid2)),
        ?_assert(model_follow:is_following(Uid2, Uid1)),
        ?_assert(model_follow:is_follower(Uid1, Uid2)),
        ?_assertNot(model_follow:is_follower(Uid2, Uid1)),
        %% Uid2 unfollows Uid1
        ?_assertOk(model_follow:unfollow(Uid2, Uid1)),
        ?_assertNot(model_follow:is_following(Uid1, Uid2)),
        ?_assertNot(model_follow:is_following(Uid2, Uid1)),
        ?_assertNot(model_follow:is_follower(Uid1, Uid2)),
        ?_assertNot(model_follow:is_follower(Uid2, Uid1))
    ].


get_all_following_testparallel() ->
    %% this test is also sufficient to test get_followers and get_all_followers,
    %% because they call the same underlying function that does all the work
    Uid1 = tutil:generate_uid(?KATCHUP),
    Uid2 = tutil:generate_uid(?KATCHUP),
    T2 = 2,
    Uid3 = tutil:generate_uid(?KATCHUP),
    T3 = 3,
    Uid4 = tutil:generate_uid(?KATCHUP),
    T4 = 4,
    Uid5 = tutil:generate_uid(?KATCHUP),
    T5 = 5,
    Uid6 = tutil:generate_uid(?KATCHUP),
    T6 = 6,
    %% Uid1 is following everybody
    lists:foreach(
        fun({Ouid, T}) -> model_follow:follow(Uid1, Ouid, T) end,
        [{Uid2, T2}, {Uid3, T3}, {Uid4, T4}, {Uid5, T5}, {Uid6, T6}]),
    [
        ?_assertMatch({[Uid6, Uid5, Uid4], _}, model_follow:get_following(Uid1, <<>>, ?USERS_PER_PAGE)),
        ?_assertNotEqual(<<>>, get_cursor(model_follow:get_following(Uid1, <<>>, ?USERS_PER_PAGE))),
        ?_assertEqual({[Uid3, Uid2], <<>>}, model_follow:get_following(Uid1,
            get_cursor(model_follow:get_following(Uid1, <<>>, ?USERS_PER_PAGE)), ?USERS_PER_PAGE)),
        ?_assertEqual([Uid6, Uid5, Uid4, Uid3, Uid2],
            model_follow:get_all_following(Uid1))
    ].


block_unblock_testparallel() ->
    %% model doesn't control the ability to add when blocked, so it isn't tested here
    %% just testing that blocking/unblocking modify data as required
    Uid1 = tutil:generate_uid(?KATCHUP),
    Uid2 = tutil:generate_uid(?KATCHUP),
    Uid3 = tutil:generate_uid(?KATCHUP),
    [%% UID1 follows UID2; UID3 follows UID1; no one is blocked
        ?_assertOk(model_follow:follow(Uid1, Uid2)),
        ?_assertOk(model_follow:follow(Uid3, Uid1)),
        ?_assertNot(model_follow:is_blocked(Uid2, Uid1)),
        ?_assertNot(model_follow:is_blocked(Uid3, Uid1)),
        ?_assertNot(model_follow:is_blocked_by(Uid2, Uid1)),
        ?_assertNot(model_follow:is_blocked_by(Uid3, Uid1)),
        ?_assertNot(model_follow:is_blocked_any(Uid2, Uid1)),
        ?_assertNot(model_follow:is_blocked_any(Uid3, Uid1)),
        ?_assertEqual([], model_follow:get_blocked_uids(Uid1)),
        ?_assertEqual([], model_follow:get_blocked_uids(Uid2)),
        ?_assertEqual([], model_follow:get_blocked_uids(Uid3)),
        %% UID 1 should have: UID2 following, UID3 follower
        ?_assertEqual([Uid2], model_follow:get_all_following(Uid1)),
        ?_assertEqual([Uid3], model_follow:get_all_followers(Uid1)),
        %% UID2, UID3 block UID1 :(
        ?_assertOk(model_follow:block(Uid2, Uid1)),
        ?_assert(model_follow:is_blocked(Uid2, Uid1)),
        ?_assert(model_follow:is_blocked_by(Uid1, Uid2)),
        ?_assertNot(model_follow:is_blocked(Uid1, Uid2)),
        ?_assertNot(model_follow:is_blocked_by(Uid2, Uid1)),
        ?_assert(model_follow:is_blocked_any(Uid2, Uid1)),
        ?_assertOk(model_follow:block(Uid3, Uid1)),
        ?_assert(model_follow:is_blocked(Uid3, Uid1)),
        ?_assert(model_follow:is_blocked_by(Uid1, Uid3)),
        ?_assertNot(model_follow:is_blocked(Uid1, Uid3)),
        ?_assertNot(model_follow:is_blocked_by(Uid3, Uid1)),
        ?_assert(model_follow:is_blocked_any(Uid3, Uid1)),
        ?_assertEqual([], model_follow:get_blocked_uids(Uid1)),
        ?_assertEqual([Uid1], model_follow:get_blocked_uids(Uid2)),
        ?_assertEqual([Uid1], model_follow:get_blocked_uids(Uid3)),
        %% UID1 should have no following or followers
        ?_assertEqual([], model_follow:get_all_following(Uid1)),
        ?_assertEqual([], model_follow:get_all_followers(Uid1)),
        %% UID2, UID3 unblock UID1 :)
        ?_assertOk(model_follow:unblock(Uid2, Uid1)),
        ?_assertNot(model_follow:is_blocked(Uid2, Uid1)),
        ?_assertNot(model_follow:is_blocked_by(Uid1, Uid2)),
        ?_assertNot(model_follow:is_blocked_any(Uid1, Uid2)),
        ?_assertOk(model_follow:unblock(Uid3, Uid1)),
        ?_assertNot(model_follow:is_blocked(Uid3, Uid1)),
        ?_assertNot(model_follow:is_blocked_by(Uid1, Uid3)),
        ?_assertNot(model_follow:is_blocked_any(Uid1, Uid3)),
        ?_assertEqual([], model_follow:get_blocked_uids(Uid1)),
        ?_assertEqual([], model_follow:get_blocked_uids(Uid2)),
        ?_assertEqual([], model_follow:get_blocked_uids(Uid3)),
        %% UID1 should have no following or followers
        ?_assertEqual([], model_follow:get_all_following(Uid1)),
        ?_assertEqual([], model_follow:get_all_followers(Uid1))
    ].

%%====================================================================
%% Remove all * tests
%%====================================================================


remove_all_blocked_testset() ->
    Uid1 = tutil:generate_uid(?KATCHUP),
    Uid2 = tutil:generate_uid(?KATCHUP),
    Uid3 = tutil:generate_uid(?KATCHUP),
    Uid4 = tutil:generate_uid(?KATCHUP),
    [
        %% Uid1 blocks everyone, Uid2 blocks Uid1
        ?_assertOk(model_follow:block(Uid1, Uid2)),
        ?_assertOk(model_follow:block(Uid1, Uid3)),
        ?_assertOk(model_follow:block(Uid1, Uid4)),
        ?_assertOk(model_follow:block(Uid2, Uid1)),
        ?_assert(model_follow:is_blocked(Uid1, Uid2)),
        ?_assert(model_follow:is_blocked(Uid1, Uid3)),
        ?_assert(model_follow:is_blocked(Uid1, Uid4)),
        ?_assert(model_follow:is_blocked(Uid2, Uid1)),
        ?_assert(model_follow:is_blocked_by(Uid2, Uid1)),
        ?_assert(model_follow:is_blocked_by(Uid3, Uid1)),
        ?_assert(model_follow:is_blocked_by(Uid4, Uid1)),
        ?_assert(model_follow:is_blocked_by(Uid1, Uid2)),
        %% Remove all of Uid1's blocks
        ?_assertOk(model_follow:remove_all_blocked_uids(Uid1)),
        %% Uid1 should be blocking no one and no one should be blocked by Uid1
        %% Uid2 should still have Uid3 blocked
        ?_assertNot(model_follow:is_blocked(Uid1, Uid2)),
        ?_assertNot(model_follow:is_blocked(Uid1, Uid3)),
        ?_assertNot(model_follow:is_blocked(Uid1, Uid4)),
        ?_assert(model_follow:is_blocked(Uid2, Uid1)),
        ?_assertNot(model_follow:is_blocked_by(Uid2, Uid1)),
        ?_assertNot(model_follow:is_blocked_by(Uid3, Uid1)),
        ?_assertNot(model_follow:is_blocked_by(Uid4, Uid1)),
        ?_assert(model_follow:is_blocked_by(Uid1, Uid2))
    ].


remove_all_blocked_by_testset() ->
    Uid1 = tutil:generate_uid(?KATCHUP),
    Uid2 = tutil:generate_uid(?KATCHUP),
    Uid3 = tutil:generate_uid(?KATCHUP),
    Uid4 = tutil:generate_uid(?KATCHUP),
    [
        %% Everyone blocks Uid1, Uid1 blocks Uid2
        ?_assertOk(model_follow:block(Uid2, Uid1)),
        ?_assertOk(model_follow:block(Uid3, Uid1)),
        ?_assertOk(model_follow:block(Uid4, Uid1)),
        ?_assertOk(model_follow:block(Uid1, Uid2)),
        ?_assert(model_follow:is_blocked(Uid2, Uid1)),
        ?_assert(model_follow:is_blocked(Uid3, Uid1)),
        ?_assert(model_follow:is_blocked(Uid4, Uid1)),
        ?_assert(model_follow:is_blocked(Uid1, Uid2)),
        ?_assert(model_follow:is_blocked_by(Uid1, Uid2)),
        ?_assert(model_follow:is_blocked_by(Uid1, Uid3)),
        ?_assert(model_follow:is_blocked_by(Uid1, Uid4)),
        ?_assert(model_follow:is_blocked_by(Uid2, Uid1)),
        %% Remove all of Uid1's blocks
        ?_assertOk(model_follow:remove_all_blocked_by_uids(Uid1)),
        %% Uid1 should be blocking no one and no one should be blocked by Uid1
        %% Uid2 should still have Uid3 blocked
        ?_assertNot(model_follow:is_blocked(Uid2, Uid1)),
        ?_assertNot(model_follow:is_blocked(Uid3, Uid1)),
        ?_assertNot(model_follow:is_blocked(Uid4, Uid1)),
        ?_assert(model_follow:is_blocked(Uid1, Uid2)),
        ?_assertNot(model_follow:is_blocked_by(Uid1, Uid2)),
        ?_assertNot(model_follow:is_blocked_by(Uid1, Uid3)),
        ?_assertNot(model_follow:is_blocked_by(Uid1, Uid4)),
        ?_assert(model_follow:is_blocked_by(Uid2, Uid1))
    ].


remove_all_following_testset() ->
    Uid1 = tutil:generate_uid(?KATCHUP),
    Uid2 = tutil:generate_uid(?KATCHUP),
    Uid3 = tutil:generate_uid(?KATCHUP),
    Uid4 = tutil:generate_uid(?KATCHUP),
    [
        %% Uid1 follows everyone, Uid2 follows Uid1
        ?_assertOk(model_follow:follow(Uid1, Uid2)),
        ?_assertOk(model_follow:follow(Uid1, Uid3)),
        ?_assertOk(model_follow:follow(Uid1, Uid4)),
        ?_assertOk(model_follow:follow(Uid2, Uid1)),
        ?_assert(model_follow:is_following(Uid1, Uid2)),
        ?_assert(model_follow:is_following(Uid1, Uid3)),
        ?_assert(model_follow:is_following(Uid1, Uid4)),
        ?_assert(model_follow:is_following(Uid2, Uid1)),
        %% Remove all of Uid1's following
        ?_assertMatch({ok, _}, model_follow:remove_all_following(Uid1)),
        %% Uid1 should be following no one; Uid2 should still follow Uid1
        ?_assertNot(model_follow:is_following(Uid1, Uid2)),
        ?_assertNot(model_follow:is_following(Uid1, Uid3)),
        ?_assertNot(model_follow:is_following(Uid1, Uid4)),
        ?_assert(model_follow:is_following(Uid2, Uid1))
    ].


remove_all_followers_testset() ->
    Uid1 = tutil:generate_uid(?KATCHUP),
    Uid2 = tutil:generate_uid(?KATCHUP),
    Uid3 = tutil:generate_uid(?KATCHUP),
    Uid4 = tutil:generate_uid(?KATCHUP),
    [
        %% Everyone follows Uid1, Uid1 follows Uid2
        ?_assertOk(model_follow:follow(Uid2, Uid1)),
        ?_assertOk(model_follow:follow(Uid3, Uid1)),
        ?_assertOk(model_follow:follow(Uid4, Uid1)),
        ?_assertOk(model_follow:follow(Uid1, Uid2)),
        ?_assert(model_follow:is_follower(Uid1, Uid2)),
        ?_assert(model_follow:is_follower(Uid1, Uid3)),
        ?_assert(model_follow:is_follower(Uid1, Uid4)),
        ?_assert(model_follow:is_follower(Uid2, Uid1)),
        %% Remove all of Uid1's following
        ?_assertMatch({ok, _}, model_follow:remove_all_followers(Uid1)),
        %% Uid1 should be following no one; Uid2 should still follow Uid1
        ?_assertNot(model_follow:is_follower(Uid1, Uid2)),
        ?_assertNot(model_follow:is_follower(Uid1, Uid3)),
        ?_assertNot(model_follow:is_follower(Uid1, Uid4)),
        ?_assert(model_follow:is_follower(Uid2, Uid1))
    ].

%%====================================================================
%% Helper functions
%%====================================================================

get_cursor({_Uids, Cursor}) -> Cursor.

