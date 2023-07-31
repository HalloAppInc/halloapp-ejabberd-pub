%%%-------------------------------------------------------------------
%%% @copyright (C) 2023, HalloApp, Inc.
%%% @doc
%%%
%%% @end
%%%-------------------------------------------------------------------
-module(model_halloapp_friends_tests).
-author('murali').

-include("tutil.hrl").


setup() ->
    tutil:setup([
        {redis, [redis_accounts]}
    ]).

%%====================================================================
%% Tests
%%====================================================================

friend_unfriend_testparallel() ->
    Uid1 = tutil:generate_uid(?HALLOAPP),
    Uid2 = tutil:generate_uid(?HALLOAPP),
    [
        %% No one is following each other
        ?_assertNot(model_halloapp_friends:is_friend(Uid1, Uid2)),
        ?_assertNot(model_halloapp_friends:is_friend_pending(Uid1, Uid2)),
        ?_assertNot(model_halloapp_friends:is_friend(Uid1, Uid2)),
        ?_assertNot(model_halloapp_friends:is_friend_pending(Uid2, Uid1)),
        ?_assertEqual(none_status, model_halloapp_friends:get_friend_status(Uid1, Uid2)),
        ?_assertEqual(none_status, model_halloapp_friends:get_friend_status(Uid2, Uid1)),
        %% Uid1 sends a friend request to Uid2
        ?_assertOk(model_halloapp_friends:add_friend_request(Uid1, Uid2)),
        ?_assert(model_halloapp_friends:is_friend_pending(Uid1, Uid2)),
        ?_assertNot(model_halloapp_friends:is_friend(Uid2, Uid1)),
        ?_assertEqual([Uid2], model_halloapp_friends:get_all_outgoing_friends(Uid1)),
        ?_assertEqual([Uid1], model_halloapp_friends:get_all_incoming_friends(Uid2)),
        ?_assert(model_halloapp_friends:is_friend_pending(Uid2, Uid1)),
        ?_assertEqual(outgoing_pending, model_halloapp_friends:get_friend_status(Uid1, Uid2)),
        ?_assertEqual(incoming_pending, model_halloapp_friends:get_friend_status(Uid2, Uid1)),
        %% Uid2 accepts friend request Uid1
        ?_assertOk(model_halloapp_friends:accept_friend_request(Uid2, Uid1)),
        ?_assertNot(model_halloapp_friends:is_friend_pending(Uid1, Uid2)),
        ?_assertNot(model_halloapp_friends:is_friend_pending(Uid2, Uid1)),
        ?_assertEqual([], model_halloapp_friends:get_all_outgoing_friends(Uid1)),
        ?_assertEqual([], model_halloapp_friends:get_all_incoming_friends(Uid2)),
        ?_assert(model_halloapp_friends:is_friend(Uid2, Uid1)),
        ?_assert(model_halloapp_friends:is_friend(Uid1, Uid2)),
        ?_assertEqual([Uid2], model_halloapp_friends:get_all_friends(Uid1)),
        ?_assertEqual(friends, model_halloapp_friends:get_friend_status(Uid1, Uid2)),
        ?_assertEqual(friends, model_halloapp_friends:get_friend_status(Uid2, Uid1)),
        %% Uid1 removes Uid2 as friend
        ?_assertOk(model_halloapp_friends:remove_friend(Uid1, Uid2)),
        ?_assertNot(model_halloapp_friends:is_friend(Uid1, Uid2)),
        ?_assertNot(model_halloapp_friends:is_friend_pending(Uid2, Uid1)),
        ?_assertNot(model_halloapp_friends:is_friend_pending(Uid1, Uid2)),
        ?_assertEqual([], model_halloapp_friends:get_all_outgoing_friends(Uid1)),
        ?_assertEqual([], model_halloapp_friends:get_all_incoming_friends(Uid1)),
        ?_assertEqual([], model_halloapp_friends:get_all_friends(Uid1)),
        ?_assertEqual(none_status, model_halloapp_friends:get_friend_status(Uid1, Uid2)),
        ?_assertEqual(none_status, model_halloapp_friends:get_friend_status(Uid2, Uid1))
    ].


friend_block_testparallel() ->
    Uid1 = tutil:generate_uid(?HALLOAPP),
    Uid2 = tutil:generate_uid(?HALLOAPP),
    [
        %% No one is following each other
        ?_assertNot(model_halloapp_friends:is_blocked_any(Uid1, Uid2)),
        ?_assertEqual([], model_halloapp_friends:get_blocked_uids(Uid1)),
        ?_assertEqual([], model_halloapp_friends:get_blocked_by_uids(Uid1)),
        ?_assertEqual([], model_halloapp_friends:get_blocked_uids(Uid2)),
        ?_assertEqual([], model_halloapp_friends:get_blocked_by_uids(Uid2)),
        ?_assertEqual([], model_halloapp_friends:get_all_outgoing_friends(Uid1)),
        ?_assertEqual([], model_halloapp_friends:get_all_incoming_friends(Uid1)),
        ?_assertEqual([], model_halloapp_friends:get_all_friends(Uid1)),
        ?_assertEqual([], model_halloapp_friends:get_all_outgoing_friends(Uid2)),
        ?_assertEqual([], model_halloapp_friends:get_all_incoming_friends(Uid2)),
        ?_assertEqual([], model_halloapp_friends:get_all_friends(Uid2)),
        %% Uid1 and Uid2 become friends
        ?_assertOk(model_halloapp_friends:add_friend_request(Uid1, Uid2)),
        ?_assertOk(model_halloapp_friends:accept_friend_request(Uid2, Uid1)),
        ?_assertEqual([Uid2], model_halloapp_friends:get_all_friends(Uid1)),
        ?_assertEqual([Uid1], model_halloapp_friends:get_all_friends(Uid2)),
        %% Uid2 blocks Uid1
        ?_assertOk(model_halloapp_friends:block(Uid2, Uid1)),
        ?_assertNot(model_halloapp_friends:is_friend(Uid1, Uid2)),
        ?_assertNot(model_halloapp_friends:is_friend_pending(Uid2, Uid1)),
        ?_assertNot(model_halloapp_friends:is_friend_pending(Uid1, Uid2)),
        ?_assertEqual([], model_halloapp_friends:get_all_outgoing_friends(Uid1)),
        ?_assertEqual([], model_halloapp_friends:get_all_incoming_friends(Uid1)),
        ?_assertEqual([], model_halloapp_friends:get_all_friends(Uid1)),
        ?_assertEqual([], model_halloapp_friends:get_all_outgoing_friends(Uid2)),
        ?_assertEqual([], model_halloapp_friends:get_all_incoming_friends(Uid2)),
        ?_assertEqual([], model_halloapp_friends:get_all_friends(Uid2)),
        ?_assertEqual([], model_halloapp_friends:get_blocked_uids(Uid1)),
        ?_assertEqual([Uid2], model_halloapp_friends:get_blocked_by_uids(Uid1)),
        ?_assertEqual([Uid1], model_halloapp_friends:get_blocked_uids(Uid2)),
        ?_assertEqual([], model_halloapp_friends:get_blocked_by_uids(Uid2))
    ].

