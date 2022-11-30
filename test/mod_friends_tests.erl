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

%%====================================================================
%% IQ tests
%%====================================================================

setup() ->
    CleanupInfo = tutil:setup([
        proto,
        {redis, [redis_friends, redis_accounts]},
        {meck, ejabberd_router, route, fun(_) -> ok end}
    ]),
    Uid1 = tutil:generate_uid(?KATCHUP),
    Uid2 = tutil:generate_uid(?KATCHUP),
    CleanupInfo#{testdata => {Uid1, Uid2}}.


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
        user_info = unwrap_user_info(mod_friends:get_user_info_from_uid(Uid1, incoming))
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
        user_info = unwrap_user_info(mod_friends:get_user_info_from_uid(Uid1, friends))
    },
    Uid1NotifMsg = pb_msg(#pb_relationship_action{
        action = add,
        uid = Uid2,
        status = friends,
        user_info = unwrap_user_info(mod_friends:get_user_info_from_uid(Uid2, friends))
    }),
    [
        ?_assertMatch(Uid2AddResponseIq, tutil:get_result_iq_sub_el(mod_friends:process_local_iq(Uid2AddIq))),
        ?_assert(meck:called(ejabberd_router, route, [Uid1NotifMsg]))
    ].


test_remove_friend_iq(#{testdata := {Uid1, Uid2}} = _CleanupInfo) ->
    %% Example 3 from the contacts_and_friends doc
    %% Uid1 removes Uid2 as their friend; Uid1 and Uid2 are no longer friends
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


iq_test_() ->
    tutil:setup_once(fun setup/0, [
        %% order matters here – each test sets up state for next test
        fun test_friend_request_iq_/1,
        fun test_becoming_friends_iq/1,
        fun test_remove_friend_iq/1
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

unwrap_user_info({UserInfo, _Status}) -> UserInfo;
unwrap_user_info(Other) -> Other.
