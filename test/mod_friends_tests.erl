%%%-------------------------------------------------------------------
%%% @author josh
%%% @copyright (C) 2022, HalloApp, Inc.
%%% @doc
%%%
%%% @end
%%%-------------------------------------------------------------------
-module(mod_friends_tests).
-author("josh").

-include("packets.hrl").

-include_lib("tutil.hrl").

setup() ->
    CleanupInfo = tutil:setup([
        proto,
        {redis, [redis_friends, redis_accounts]},
        {meck, ejabberd_router, route, fun(_) -> ok end}
    ]),
    Uid1 = tutil:generate_uid(?KATCHUP),
    Uid2 = tutil:generate_uid(?KATCHUP),
    CleanupInfo#{testdata => {Uid1, Uid2}}.

%%====================================================================
%% IQ tests – add and remove
%%====================================================================

test_friend_request_iq_(#{testdata := {Uid1, Uid2}} = _CleanupInfo) ->
    %% Example 1 from the contacts_and_friends doc
    %% Uid1 requests Uid2 as a friend by adding them
    ClientIQ = #pb_iq{
        from_uid = Uid1,
        payload = #pb_relationship_action{
            action = add,
            uid = Uid2
        }
    },
    ExpectedResultPayload = #pb_relationship_action{
        action = add,
        uid = Uid2,
        status = outgoing
    },
    ServerMsgToUid1 = pb_msg(#pb_relationship_action{
        action = add,
        uid = Uid1,
        status = incoming,
        user_info = mod_friends:get_user_info_from_uid(Uid1, incoming)
    }),
    [
        ?_assertMatch(ExpectedResultPayload, tutil:get_result_iq_sub_el(mod_friends:process_local_iq(ClientIQ))),
        ?_assert(meck:called(ejabberd_router, route, [ServerMsgToUid1]))
    ].


test_becoming_friends_iq(#{testdata := {Uid1, Uid2}} = _CleanupInfo) ->
    %% Example 2 from the contacts_and_friends doc
    %% Uid2 accepts Uid1's add request by adding them back; Uid1 and Uid2 are friends
    Uid2AddIq = #pb_iq{
        from_uid = Uid2,
        payload = #pb_relationship_action{
            action = add,
            uid = Uid1
        }
    },
    Uid2AddResponseIq = #pb_relationship_action{
        action = add,
        uid = Uid1,
        status = friends,
        user_info = mod_friends:get_user_info_from_uid(Uid1, friends)
    },
    Uid1NotifMsg = pb_msg(#pb_relationship_action{
        action = add,
        uid = Uid2,
        status = friends,
        user_info = mod_friends:get_user_info_from_uid(Uid2, friends)
    }),
    [
        ?_assertMatch(Uid2AddResponseIq, tutil:get_result_iq_sub_el(mod_friends:process_local_iq(Uid2AddIq))),
        ?_assert(meck:called(ejabberd_router, route, [Uid1NotifMsg]))
    ].


test_remove_friend_iq(#{testdata := {Uid1, Uid2}} = _CleanupInfo) ->
    %% Example 3 from the contacts_and_friends doc
    %% Uid2 removes Uid1 as their friend; Uid1 and Uid2 are no longer friends
    Uid2RemoveIq = #pb_iq{
        from_uid = Uid2,
        payload = #pb_relationship_action{
            action = remove,
            uid = Uid1
        }
    },
    Uid2RemoveResponseIq = #pb_relationship_action{
        action = remove,
        uid = Uid1,
        status = none
    },
    Uid1NotifMsg = pb_msg(#pb_relationship_action{
        action = remove,
        uid = Uid2,
        status = none
    }),
    [
        ?_assertMatch(Uid2RemoveResponseIq, tutil:get_result_iq_sub_el(mod_friends:process_local_iq(Uid2RemoveIq))),
        ?_assert(meck:called(ejabberd_router, route, [Uid1NotifMsg]))
    ].


test_rescind_friend_request_iq(#{testdata := {Uid1, Uid2}} = _CleanupInfo) ->
    %% Uid1 removes Uid2 as their friend, rescinding their add request
    %% Uid1 and Uid2 are not friends
    Uid1RemoveIq = #pb_iq{
        from_uid = Uid1,
        payload = #pb_relationship_action{
            action = remove,
            uid = Uid2
        }
    },
    Uid1RemoveResponseIq = #pb_relationship_action{
        action = remove,
        uid = Uid2,
        status = none
    },
    Uid2NotifMsg = pb_msg(#pb_relationship_action{
        action = remove,
        uid = Uid1,
        status = none
    }),
    [
        %% prepare state for tests
        ?_assertOk(model_friends:add_outgoing_friend(Uid1, Uid2)),
        %% tests
        ?_assertMatch(Uid1RemoveResponseIq, tutil:get_result_iq_sub_el(mod_friends:process_local_iq(Uid1RemoveIq))),
        ?_assert(meck:called(ejabberd_router, route, [Uid2NotifMsg]))
    ].


test_reject_friend_request_iq(#{testdata := {Uid1, Uid2}} = _CleanupInfo) ->
    %% Uid2 removes Uid1 as their friend, rejecting their friend request
    %% Uid1 and Uid2 are not friends
    Uid2RemoveIq = #pb_iq{
        from_uid = Uid2,
        payload = #pb_relationship_action{
            action = remove,
            uid = Uid1
        }
    },
    Uid2RemoveResponseIq = #pb_relationship_action{
        action = remove,
        uid = Uid1,
        status = none
    },
    Uid1NotifMsg = pb_msg(#pb_relationship_action{
        action = remove,
        uid = Uid2,
        status = none
    }),
    [
        %% prepare state for tests
        ?_assertOk(model_friends:add_outgoing_friend(Uid1, Uid2)),
        %% tests
        ?_assertMatch(Uid2RemoveResponseIq, tutil:get_result_iq_sub_el(mod_friends:process_local_iq(Uid2RemoveIq))),
        %% this test should not send an additional notification msg to other user
        %% num_calls should be equal to msgs sent from prev tests
        ?_assertEqual(1, meck:num_calls(ejabberd_router, route, [Uid1NotifMsg]))
    ].


add_remove_iq_test_() ->
    tutil:setup_once(fun setup/0, [
        %% order matters here – some tests set up state for next tests
        fun test_friend_request_iq_/1,
        fun test_becoming_friends_iq/1,
        fun test_remove_friend_iq/1,
        fun test_rescind_friend_request_iq/1,
        fun test_reject_friend_request_iq/1
    ]).

%%====================================================================
%% IQ tests – block and unblock
%%====================================================================

test_block_iq(#{testdata := {Uid1, Uid2}} = _CleanupInfo) ->
    %% Example 5 from the contacts_and_friends doc
    %% Uid1 blocks Uid2
    Uid1BlockIq = #pb_iq{
        from_uid = Uid1,
        payload = #pb_relationship_action{
            action = block,
            uid = Uid2
        }
    },
    Uid1ResponsePayload = #pb_relationship_action{
        action = block,
        uid = Uid2,
        status = none
    },
    Uid2ServerMsg = pb_msg(#pb_relationship_action{
        action = '_',
        uid = Uid1,
        status = '_',
        user_info = '_'
    }),
    [
        ?_assertMatch(Uid1ResponsePayload, tutil:get_result_iq_sub_el(mod_friends:process_local_iq(Uid1BlockIq))),
        %% Uid2 should not be notified
        ?_assertNot(meck:called(ejabberd_router, route, [Uid2ServerMsg]))
    ].


test_add_blocked_iq(#{testdata := {Uid1, Uid2}} = _CleanupInfo) ->
    %% Example 6 from the contacts_and_friends doc
    %% Uid2 tries to add Uid1, but Uid2 blocked Uid1
    Uid2AddIq = #pb_iq{
        from_uid = Uid2,
        payload = #pb_relationship_action{
            action = add,
            uid = Uid1
        }
    },
    Uid2AddResponsePayload = #pb_relationship_action{
        action = add,
        uid = Uid1,
        status = outgoing
    },
    Uid1NotifMsg = pb_msg(#pb_relationship_action{
        action = '_',
        uid = Uid2,
        status = '_',
        user_info = '_'
    }),
    [
        ?_assertMatch(Uid2AddResponsePayload, tutil:get_result_iq_sub_el(mod_friends:process_local_iq(Uid2AddIq))),
        %% Uid1 should not be notified
        ?_assertNot(meck:called(ejabberd_router, route, [Uid1NotifMsg]))
    ].


block_unblock_iq_test_() ->
    tutil:setup_once(fun setup/0, [
        %% order matters here – some tests set up state for next tests
        fun test_block_iq/1,
        fun test_add_blocked_iq/1
    ]).

%%====================================================================
%% IQ tests – RelationshipList
%%====================================================================

setup_relationships() ->
    CleanupInfo = setup(),
    Uid1 = tutil:generate_uid(?KATCHUP),
    Uid2 = tutil:generate_uid(?KATCHUP),
    Uid3 = tutil:generate_uid(?KATCHUP),
    Uid4 = tutil:generate_uid(?KATCHUP),
    Uid5 = tutil:generate_uid(?KATCHUP),
    Uid6 = tutil:generate_uid(?KATCHUP),
    Uid7 = tutil:generate_uid(?KATCHUP),
    Uid8 = tutil:generate_uid(?KATCHUP),
    Uid9 = tutil:generate_uid(?KATCHUP),
    Uid10 = tutil:generate_uid(?KATCHUP),
    %% Uid1 is friends with Uid2, Uid3
    model_friends:add_friends(Uid1, [Uid2, Uid3]),
    %% Uid1 has outgoing requests to Uid4 and Uid5
    model_friends:add_outgoing_friend(Uid1, Uid4),
    model_friends:add_outgoing_friend(Uid1, Uid5),
    %% Uid1 has incoming requests from Uid6and Uid7
    model_friends:add_outgoing_friend(Uid6, Uid1),
    model_friends:add_outgoing_friend(Uid7, Uid1),
    %% Uid1 has blocked Uid8 and Uid9
    model_friends:block(Uid1, Uid8),
    model_friends:block(Uid1, Uid9),
    %% Uid1 is blocked by Uid10
    model_friends:block(Uid10, Uid1),
    CleanupInfo#{testdata => {Uid1, Uid2, Uid3, Uid4, Uid5, Uid6, Uid7, Uid8, Uid9}}.


test_get_friends_iq(#{testdata := {Uid1, Uid2, Uid3, _Uid4, _Uid5, _Uid6, _Uid7, _Uid8, _Uid9}} = _CleanupInfo) ->
    %% Uid1 is friends with Uid2 and Uid3
    Uid2UserInfo = mod_friends:get_user_info_from_uid(Uid2, friends),
    Uid3UserInfo = mod_friends:get_user_info_from_uid(Uid3, friends),
    Request = #pb_iq{
        type = get,
        from_uid = Uid1,
        payload = #pb_relationship_list{type = normal}
    },
    ResponsePayload = convert_user_info_to_set(#pb_relationship_list{
        type = normal,
        users = [Uid2UserInfo, Uid3UserInfo]
    }),
    [
        ?_assertEqual(ResponsePayload, convert_user_info_to_set(mod_friends:process_local_iq(Request)))
    ].


test_get_outgoing_iq(#{testdata := {Uid1, _Uid2, _Uid3, Uid4, Uid5, _Uid6, _Uid7, _Uid8, _Uid9}} = _CleanupInfo) ->
    %% Uid1 has outgoing requests to Uid4 and Uid5
    Uid4UserInfo = mod_friends:get_user_info_from_uid(Uid4, outgoing),
    Uid5UserInfo = mod_friends:get_user_info_from_uid(Uid5, outgoing),
    Request = #pb_iq{
        type = get,
        from_uid = Uid1,
        payload = #pb_relationship_list{type = outgoing}
    },
    ResponsePayload = convert_user_info_to_set(#pb_relationship_list{
        type = outgoing,
        users = [Uid4UserInfo, Uid5UserInfo]
    }),
    [
        ?_assertEqual(ResponsePayload, convert_user_info_to_set(mod_friends:process_local_iq(Request)))
    ].


test_get_incoming_iq(#{testdata := {Uid1, _Uid2, _Uid3, _Uid4, _Uid5, Uid6, Uid7, _Uid8, _Uid9}} = _CleanupInfo) ->
    %% Uid1 has incoming requests from Uid6 and Uid7
    Uid6UserInfo = mod_friends:get_user_info_from_uid(Uid6, incoming),
    Uid7UserInfo = mod_friends:get_user_info_from_uid(Uid7, incoming),
    Request = #pb_iq{
        type = get,
        from_uid = Uid1,
        payload = #pb_relationship_list{type = incoming}
    },
    ResponsePayload = convert_user_info_to_set(#pb_relationship_list{
        type = incoming,
        users = [Uid6UserInfo, Uid7UserInfo]
    }),
    [
        ?_assertEqual(ResponsePayload, convert_user_info_to_set(mod_friends:process_local_iq(Request)))
    ].


test_get_blocked_iq(#{testdata := {Uid1, _Uid2, _Uid3, _Uid4, _Uid5, _Uid6, _Uid7, Uid8, Uid9}} = _CleanupInfo) ->
    %% Uid1 has blocked Uid8 and Uid9
    Uid8UserInfo = mod_friends:get_user_info_from_uid(Uid8, blocked),
    Uid9UserInfo = mod_friends:get_user_info_from_uid(Uid9, blocked),
    Request = #pb_iq{
        type = get,
        from_uid = Uid1,
        payload = #pb_relationship_list{type = blocked}
    },
    ResponsePayload = convert_user_info_to_set(#pb_relationship_list{
        type = blocked,
        users = [Uid8UserInfo, Uid9UserInfo]
    }),
    [
        ?_assertEqual(ResponsePayload, convert_user_info_to_set(mod_friends:process_local_iq(Request)))
    ].


relationship_list_test_() ->
    tutil:in_parallel(fun setup_relationships/0, [
        fun test_get_friends_iq/1,
        fun test_get_outgoing_iq/1,
        fun test_get_incoming_iq/1,
        fun test_get_blocked_iq/1
    ]).

%%====================================================================
%% Internal functions
%%====================================================================

pb_msg(Payload) ->
    #pb_msg{
        id = '_',
        type = '_',
        to_uid = '_',
        from_uid = '_',
        payload = Payload,
        retry_count = '_',
        rerequest_count = '_'
    }.

convert_user_info_to_set(Iq) when is_record(Iq, pb_iq) ->
    RelationshipList = tutil:get_result_iq_sub_el(Iq),
    convert_user_info_to_set(RelationshipList);

convert_user_info_to_set(RelationshipList) when is_record(RelationshipList, pb_relationship_list) ->
    #pb_relationship_list{users = Users} = RelationshipList,
    RelationshipList#pb_relationship_list{users = sets:from_list(Users)}.


%% for debugging – not used in tests
%%print_user_info_uids(Iq) when is_record(Iq, pb_iq) ->
%%    RelationshipList = tutil:get_result_iq_sub_el(Iq),
%%    print_user_info_uids(RelationshipList);
%%
%%print_user_info_uids(RelationshipList) when is_record(RelationshipList, pb_relationship_list) ->
%%    List = case sets:is_set(RelationshipList#pb_relationship_list.users) of
%%        true -> sets:to_list(RelationshipList#pb_relationship_list.users);
%%        _ -> RelationshipList#pb_relationship_list.users
%%    end,
%%    lists:foreach(
%%        fun(UserInfo) -> ?debugVal(UserInfo#pb_user_info.uid) end,
%%        List).
