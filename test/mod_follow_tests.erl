%%%-------------------------------------------------------------------
%%% @author josh
%%% @copyright (C) 2022, HalloApp, Inc.
%%% @doc
%%%
%%% @end
%%%-------------------------------------------------------------------
-module(mod_follow_tests).
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
%% Standalone tests
%%====================================================================

test_follow_self_testset(#{testdata := {Uid1, _Uid2}}) ->
    ClientIQ = #pb_iq{
        from_uid = Uid1,
        payload = #pb_relationship_request{
            action = follow,
            uid = Uid1
            }
        },
    ExpectedResultPayload = #pb_relationship_response{result = fail},
    [
        ?_assertMatch(ExpectedResultPayload, tutil:get_result_iq_sub_el(mod_follow:process_local_iq(ClientIQ)))
    ].

%%====================================================================
%% IQ tests – follow, unfollow, remove follower, block, unblock
%%====================================================================

test_follow_iq_(#{testdata := {Uid1, Uid2}} = _CleanupInfo) ->
    %% Example 1 from the followers doc
    %% Uid1 follows Uid2
    ClientIQ = #pb_iq{
        from_uid = Uid1,
        payload = #pb_relationship_request{
            action = follow,
            uid = Uid2
        }
    },
    ExpectedResultPayload = #pb_relationship_response{
        result = ok,
        profile = (model_accounts:get_basic_user_profiles(Uid1, Uid2))#pb_basic_user_profile{following_status = following}
    },
    UserProfileUid1 = (model_accounts:get_basic_user_profiles(Uid2, Uid1))#pb_basic_user_profile{follower_status = following},
    ServerMsgToUid2 = pb_msg(profile_update(UserProfileUid1, normal)),
    [
        ?_assertMatch(ExpectedResultPayload, tutil:get_result_iq_sub_el(mod_follow:process_local_iq(ClientIQ))),
        ?_assert(meck:called(ejabberd_router, route, [ServerMsgToUid2])),
        ?_assertEqual(get_follower_status(ExpectedResultPayload), none),
        ?_assertEqual(get_following_status(ExpectedResultPayload), following),
        ?_assertEqual(get_follower_status(ServerMsgToUid2), following),
        ?_assertEqual(get_following_status(ServerMsgToUid2), none)
    ].


test_unfollow_iq_(#{testdata := {Uid1, Uid2}} = _CleanupInfo) ->
    %% Example 2 from the followers doc
    %% Uid1 unfollows Uid2
    ClientIQ = #pb_iq{
        from_uid = Uid1,
        payload = #pb_relationship_request{
            action = unfollow,
            uid = Uid2
        }
    },
    ExpectedResultPayload = #pb_relationship_response{
        result = ok,
        profile = (model_accounts:get_basic_user_profiles(Uid1, Uid2))#pb_basic_user_profile{following_status = none}
    },
    UserProfileUid1 = (model_accounts:get_basic_user_profiles(Uid2, Uid1))#pb_basic_user_profile{follower_status = none},
    ServerMsgToUid2 = pb_msg(profile_update(UserProfileUid1, normal)),
    [
        ?_assertMatch(ExpectedResultPayload, tutil:get_result_iq_sub_el(mod_follow:process_local_iq(ClientIQ))),
        ?_assert(meck:called(ejabberd_router, route, [ServerMsgToUid2])),
        ?_assertEqual(get_follower_status(ExpectedResultPayload), none),
        ?_assertEqual(get_following_status(ExpectedResultPayload), none),
        ?_assertEqual(get_follower_status(ServerMsgToUid2), none),
        ?_assertEqual(get_following_status(ServerMsgToUid2), none)
    ].


test_remove_follower_iq(#{testdata := {Uid1, Uid2}} = _CleanupInfo) ->
    %% Example 3 from the followers doc
    %% Uid2 is following Uid1, Uid1 removes them as a follower
    ClientIQ = #pb_iq{
        from_uid = Uid1,
        payload = #pb_relationship_request{
            action = remove_follower,
            uid = Uid2
        }
    },
    ExpectedResultPayload = #pb_relationship_response{
        result = ok,
        profile = (model_accounts:get_basic_user_profiles(Uid1, Uid2))#pb_basic_user_profile{following_status = none}
    },
    UserProfileUid1 = (model_accounts:get_basic_user_profiles(Uid2, Uid1))#pb_basic_user_profile{follower_status = none},
    ServerMsgToUid2 = pb_msg(profile_update(UserProfileUid1, normal)),
    [
        %% setup state
        ?_assertOk(model_follow:follow(Uid2, Uid1)),
        %% tests
        ?_assertMatch(ExpectedResultPayload, tutil:get_result_iq_sub_el(mod_follow:process_local_iq(ClientIQ))),
        ?_assert(meck:called(ejabberd_router, route, [ServerMsgToUid2])),
        ?_assertEqual(get_follower_status(ExpectedResultPayload), none),
        ?_assertEqual(get_following_status(ExpectedResultPayload), none),
        ?_assertEqual(get_follower_status(ServerMsgToUid2), none),
        ?_assertEqual(get_following_status(ServerMsgToUid2), none)
    ].


test_block_iq(#{testdata := {Uid1, Uid2}} = _CleanupInfo) ->
    %% Uid1 blocks Uid2
    %% since they have no relationship prior to the block, Uid2 should not be notified
    ClientIQ = #pb_iq{
        from_uid = Uid1,
        payload = #pb_relationship_request{
            action = block,
            uid = Uid2
        }
    },
    ExpectedResultPayload = #pb_relationship_response{
        result = ok,
        profile = blocked_user_profile(Uid2, true)
    },
    ServerMsgToUid2 = pb_msg(profile_update(blocked_user_profile(Uid1, false), delete)),
    [
        ?_assertMatch(ExpectedResultPayload, tutil:get_result_iq_sub_el(mod_follow:process_local_iq(ClientIQ))),
        ?_assertNot(meck:called(ejabberd_router, route, [ServerMsgToUid2]))
    ].


test_block_notify_iq(#{testdata := {Uid1, Uid2}} = _CleanupInfo) ->
    %% Example 4 from the followers doc
    %% Uid1 blocks Uid2
    %% Uid1 followed Uid2 before this, so Uid2 should be notified
    ClientIQ = #pb_iq{
        from_uid = Uid1,
        payload = #pb_relationship_request{
            action = block,
            uid = Uid2
        }
    },
    ExpectedResultPayload = #pb_relationship_response{
        result = ok,
        profile = blocked_user_profile(Uid2, true)
    },
    ServerMsgToUid2 = pb_msg(profile_update(blocked_user_profile(Uid1, false), delete)),
    [
        %% setup state
        ?_assertOk(model_follow:follow(Uid1, Uid2)),
        %% tests
        ?_assertMatch(ExpectedResultPayload, tutil:get_result_iq_sub_el(mod_follow:process_local_iq(ClientIQ))),
        ?_assert(meck:called(ejabberd_router, route, [ServerMsgToUid2])),
        ?_assertEqual(get_follower_status(ExpectedResultPayload), none),
        ?_assertEqual(get_following_status(ExpectedResultPayload), none),
        ?_assertEqual(get_follower_status(ServerMsgToUid2), none),
        ?_assertEqual(get_following_status(ServerMsgToUid2), none)
    ].


test_unblock_iq(#{testdata := {Uid1, Uid2}} = _CleanupInfo) ->
    %% Example 5 from the followers doc
    %% Uid1 unblocks Uid2
    %% Uid2 should not be notified
    ClientIQ = #pb_iq{
        from_uid = Uid1,
        payload = #pb_relationship_request{
            action = unblock,
            uid = Uid2
        }
    },
    ExpectedResultPayload = #pb_relationship_response{
        result = ok,
        profile = model_accounts:get_basic_user_profiles(Uid1, Uid2)
    },
    ServerMsgToUid2 = pb_msg(profile_update(model_accounts:get_basic_user_profiles(Uid2, Uid1), normal)),
    NumRouterCalls = 2,  %% from previous tests: test_block_iq, test_block_notify_iq
    [
        ?_assertMatch(ExpectedResultPayload, tutil:get_result_iq_sub_el(mod_follow:process_local_iq(ClientIQ))),
        ?_assertEqual(NumRouterCalls, meck:num_calls(ejabberd_router, route, [ServerMsgToUid2]))
    ].


iq_test_() ->
    tutil:setup_once(fun setup/0, [
        %% order matters here – some tests set up state for next tests
        fun test_follow_iq_/1,
        fun test_unfollow_iq_/1,
        fun test_remove_follower_iq/1,
        fun test_block_iq/1,
        fun test_block_notify_iq/1,
        fun test_unblock_iq/1
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
    %% Uid1 is following Uid2, Uid3
    model_follow:follow(Uid1, Uid2),
    model_follow:follow(Uid1, Uid3),
    %% Uid1 has followers Uid4 and Uid5
    model_follow:follow(Uid4, Uid1),
    model_follow:follow(Uid5, Uid1),
    %% Uid1 has blocked Uid6 and Uid7
    model_follow:block(Uid1, Uid6),
    model_follow:block(Uid1, Uid7),
    %% Uid1 is blocked by Uid8
    model_follow:block(Uid8, Uid1),
    CleanupInfo#{testdata => {Uid1, Uid2, Uid3, Uid4, Uid5, Uid6, Uid7}}.


test_get_following_iq(#{testdata := {Uid1, Uid2, Uid3, _Uid4, _Uid5, _Uid6, _Uid7}} = _CleanupInfo) ->
    %% Uid1 is following Uid2, Uid3
    Uid2UserInfo = model_accounts:get_basic_user_profiles(Uid1, Uid2),
    Uid3UserInfo = model_accounts:get_basic_user_profiles(Uid1, Uid3),
    Request = #pb_iq{
        type = get,
        from_uid = Uid1,
        payload = #pb_relationship_list{type = following}
    },
    ResponsePayload = convert_user_info_to_set(#pb_relationship_list{
        type = following,
        cursor = <<>>,
        users = [Uid2UserInfo, Uid3UserInfo]
    }),
    [
        ?_assertEqual(ResponsePayload, convert_user_info_to_set(mod_follow:process_local_iq(Request)))
    ].


test_get_followers_iq(#{testdata := {Uid1, _Uid2, _Uid3, Uid4, Uid5, _Uid6, _Uid7}} = _CleanupInfo) ->
    %% Uid1 has followers Uid4 and Uid5
    Uid4UserInfo = model_accounts:get_basic_user_profiles(Uid1, Uid4),
    Uid5UserInfo = model_accounts:get_basic_user_profiles(Uid1, Uid5),
    Request = #pb_iq{
        type = get,
        from_uid = Uid1,
        payload = #pb_relationship_list{type = follower}
    },
    ResponsePayload = convert_user_info_to_set(#pb_relationship_list{
        type = follower,
        cursor = <<>>,
        users = [Uid4UserInfo, Uid5UserInfo]
    }),
    [
        ?_assertEqual(ResponsePayload, convert_user_info_to_set(mod_follow:process_local_iq(Request)))
    ].


test_get_blocked_iq(#{testdata := {Uid1, _Uid2, _Uid3, _Uid4, _Uid5, Uid6, Uid7}} = _CleanupInfo) ->
    %% Uid1 has blocked Uid6 and Uid7
    Uid6Name = <<"uid6name">>,
    ok = model_accounts:set_name(Uid6, Uid6Name),
    Uid6UserInfo = (blocked_user_profile(Uid6, true))#pb_basic_user_profile{name = Uid6Name},
    Uid7UserInfo = (blocked_user_profile(Uid7, true))#pb_basic_user_profile{name = undefined},
    Request = #pb_iq{
        type = get,
        from_uid = Uid1,
        payload = #pb_relationship_list{type = blocked}
    },
    ResponsePayload = convert_user_info_to_set(#pb_relationship_list{
        type = blocked,
        cursor = <<>>,
        users = [Uid6UserInfo, Uid7UserInfo]
    }),
    [
        ?_assertEqual(ResponsePayload, convert_user_info_to_set(mod_follow:process_local_iq(Request)))
    ].


relationship_list_test_() ->
    tutil:setup_once(fun setup_relationships/0, [
        fun test_get_following_iq/1,
        fun test_get_followers_iq/1,
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


profile_update(UserProfile, Type) ->
    #pb_profile_update{type = Type, profile = UserProfile}.


convert_user_info_to_set(Iq) when is_record(Iq, pb_iq) ->
    RelationshipList = tutil:get_result_iq_sub_el(Iq),
    convert_user_info_to_set(RelationshipList);

convert_user_info_to_set(RelationshipList) when is_record(RelationshipList, pb_relationship_list) ->
    #pb_relationship_list{users = Users} = RelationshipList,
    RelationshipList#pb_relationship_list{users = sets:to_list(sets:from_list(Users))}.


get_follower_status(Iq) when is_record(Iq, pb_iq) ->
    get_follower_status(Iq#pb_iq.payload);

get_follower_status(Msg) when is_record(Msg, pb_msg) ->
    get_follower_status(Msg#pb_msg.payload);

get_follower_status(RelationshipResult) when is_record(RelationshipResult, pb_relationship_response) ->
    get_follower_status(RelationshipResult#pb_relationship_response.profile);

get_follower_status(ProfileUpdate) when is_record(ProfileUpdate, pb_profile_update) ->
    get_follower_status(ProfileUpdate#pb_profile_update.profile);

get_follower_status(UserProfile) ->
    UserProfile#pb_basic_user_profile.follower_status.


get_following_status(Iq) when is_record(Iq, pb_iq) ->
    get_following_status(Iq#pb_iq.payload);

get_following_status(Msg) when is_record(Msg, pb_msg) ->
    get_following_status(Msg#pb_msg.payload);

get_following_status(RelationshipResult) when is_record(RelationshipResult, pb_relationship_response) ->
    get_following_status(RelationshipResult#pb_relationship_response.profile);

get_following_status(ProfileUpdate) when is_record(ProfileUpdate, pb_profile_update) ->
    get_following_status(ProfileUpdate#pb_profile_update.profile);

get_following_status(UserProfile) ->
    UserProfile#pb_basic_user_profile.following_status.


blocked_user_profile(Uid, IsTheUserBlocking) ->
    #pb_basic_user_profile{
        uid = Uid,
        username = undefined,
        follower_status = none,
        following_status = none,
        blocked = IsTheUserBlocking
    }.

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
%%        fun(UserInfo) when is_record(UserInfo, pb_basic_user_profile) -> ?debugVal(UserInfo#pb_basic_user_profile.uid);
%%           (UserInfo) when is_record(UserInfo, pb_user_profile) -> ?debugVal(UserInfo#pb_user_profile.uid) end,
%%        List).
