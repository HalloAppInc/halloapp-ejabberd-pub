%%%-------------------------------------------------------------------
%%% File: model_phone_tests.erl
%%% Copyright (C) 2020, Halloapp Inc.
%%%
%%%-------------------------------------------------------------------
-module(mod_groups_api_tests).
-author("nikola").

-include("xmpp.hrl").
-include("groups.hrl").
-include("feed.hrl").
-include("groups_test_data.hrl").

-include_lib("eunit/include/eunit.hrl").


setup() ->
    tutil:setup(),
    stringprep:start(),
    gen_iq_handler:start(ejabberd_local),
    ejabberd_hooks:start_link(),
    mod_redis:start(undefined, []),
    clear(),
    setup_accounts(),
    ok.


setup_accounts() ->
    model_accounts:create_account(?UID1, ?PHONE1, ?NAME1, ?UA),
    model_accounts:create_account(?UID2, ?PHONE2, ?NAME2, ?UA),
    model_accounts:create_account(?UID3, ?PHONE3, ?NAME3, ?UA),
    model_accounts:create_account(?UID4, ?PHONE4, ?NAME4, ?UA),
    ok.


clear() ->
    tutil:cleardb(redis_groups),
    tutil:cleardb(redis_accounts).


create_group_IQ(Uid, Name) ->
    create_group_IQ(Uid, Name, []).


create_group_IQ(Uid, Name, Uids) ->
    MemberSt = [#member_st{uid = Ouid} || Ouid <- Uids],
    #iq{
        from = #jid{luser = Uid},
        type = set,
        sub_els = [
            #group_st{
                action = create,
                name = Name,
                members = MemberSt
            }
        ]
    }.


delete_group_IQ(Uid, Gid) ->
    make_group_IQ(Uid, Gid, set, delete, []).


modify_members_IQ(Uid, Gid, Changes) ->
    make_group_IQ(Uid, Gid, set, modify_members, Changes).


modify_admins_IQ(Uid, Gid, Changes) ->
    make_group_IQ(Uid, Gid, set, modify_admins, Changes).


get_group_IQ(Uid, Gid) ->
    make_group_IQ(Uid, Gid, get, get, []).


leave_group_IQ(Uid, Gid) ->
    make_group_IQ(Uid, Gid, set, leave, []).


set_avatar_IQ(Uid, Gid) ->
    avatar_IQ(Uid, Gid, ?IMAGE1).


delete_avatar_IQ(Uid, Gid) ->
    avatar_IQ(Uid, Gid, <<>>).


avatar_IQ(Uid, Gid, Cdata) ->
    #iq{
        from = #jid{luser = Uid},
        type = set,
        sub_els = [
            #group_avatar{
                gid =  Gid,
                cdata = Cdata
            }]
    }.


set_name_IQ(Uid, Gid, Name) ->
    #iq{
        from = #jid{luser = Uid},
        type = set,
        sub_els = [
            #group_st{
                gid = Gid,
                action = set_name,
                name = Name
            }
        ]
    }.


make_group_IQ(Uid, Gid, Type, Action, Changes) ->
    MemberSt = [#member_st{uid = Ouid, action = MAction} || {Ouid, MAction} <- Changes],
    #iq{
        from = #jid{luser = Uid},
        type = Type,
        sub_els = [
            #group_st{
                gid = Gid,
                action = Action,
                members = MemberSt
            }
        ]
    }.


get_groups_IQ(Uid) ->
    #iq{
        from = #jid{luser = Uid},
        type = get,
        sub_els = [
            #groups{action = get}
        ]
    }.


make_group_post_st(PostId, PublisherUid, PublisherName, Payload, Timestamp) ->
    #group_post_st{
        id = PostId,
        publisher_uid = PublisherUid,
        publisher_name = PublisherName,
        payload = Payload,
        timestamp = Timestamp
    }.

make_group_comment_st(CommentId, PostId, PublisherUid,
        PublisherName, ParentCommentId, Payload, Timestamp) ->
    #group_comment_st{
        id = CommentId,
        post_id = PostId,
        publisher_uid = PublisherUid,
        publisher_name = PublisherName,
        parent_comment_id = ParentCommentId,
        payload = Payload,
        timestamp = Timestamp
    }.

make_group_feed_st(Gid, Name, AvatarId, Action, Post, Comment) ->
    #group_feed_st{
        gid = Gid,
        name = Name,
        avatar_id = AvatarId,
        action = Action,
        post = Post,
        comment = Comment
    }.

make_group_feed_iq(Uid, GroupFeedSt) ->
    #iq{
        from = #jid{luser = Uid},
        type = set,
        sub_els = [GroupFeedSt]
    }.


mod_groups_api_test() ->
    setup(),
    Host = <<"s.halloapp.net">>,
    ?assertEqual(ok, mod_groups_api:start(Host, [])),
    ?assertEqual(ok, mod_groups_api:stop(Host)),
    ?assertEqual([{mod_groups, hard}], mod_groups_api:depends(Host, [])),
    ?assertEqual([], mod_groups_api:mod_options(Host)),
    ok.


create_empty_group_test() ->
    setup(),
    IQ = create_group_IQ(?UID1, ?GROUP_NAME1),
    IQRes = mod_groups_api:process_local_iq(IQ),
    GroupSt = tutil:get_result_iq_sub_el(IQRes),
    #group_st{
        gid = Gid,
        name = ?GROUP_NAME1,
        members = []
    } = GroupSt,
    ?assertEqual(true, model_groups:group_exists(Gid)),
    ?assertEqual(
        {ok, #group_info{gid = Gid, name = ?GROUP_NAME1}},
        mod_groups:get_group_info(Gid, ?UID1)),
%%    ?debugVal(IQRes),
    ok.


create_group_with_members_test() ->
    setup(),
    IQ = create_group_IQ(?UID1, ?GROUP_NAME1, [?UID2, ?UID3, ?UID5]),
    IQRes = mod_groups_api:process_local_iq(IQ),
    GroupSt = tutil:get_result_iq_sub_el(IQRes),
    #group_st{
        gid = _Gid,
        name = ?GROUP_NAME1,
        members = Members
    } = GroupSt,
%%    ?debugVal(Members),
    M2 = #member_st{uid = ?UID2, type = member, result = ok},
    M3 = #member_st{uid = ?UID3, type = member, result = ok},
    M5 = #member_st{uid = ?UID5, type = member, result = failed, reason = no_account},
    ?assertEqual([M2, M3, M5], Members),
    ok.


create_group_with_creator_as_member_test() ->
    setup(),
    IQ = create_group_IQ(?UID1, ?GROUP_NAME1, [?UID1, ?UID2]),
    IQRes = mod_groups_api:process_local_iq(IQ),
    GroupSt = tutil:get_result_iq_sub_el(IQRes),
    #group_st{
        gid = _Gid,
        name = ?GROUP_NAME1,
        members = Members
    } = GroupSt,
%%    ?debugVal(Members),
    M1 = #member_st{uid = ?UID1, type = admin, result = ok},
    M2 = #member_st{uid = ?UID2, type = member, result = ok},
    ?assertEqual([M1, M2], Members),
    ok.


delete_group_test() ->
    setup(),
    CreateIQ = create_group_IQ(?UID1, ?GROUP_NAME1, [?UID1, ?UID2]),
    CreateIQRes = mod_groups_api:process_local_iq(CreateIQ),
    CreateGroupSt = tutil:get_result_iq_sub_el(CreateIQRes),
    Gid = CreateGroupSt#group_st.gid,

    DeleteIQ = delete_group_IQ(?UID1, Gid),
    DeleteIQRes = mod_groups_api:process_local_iq(DeleteIQ),
    ok = tutil:assert_empty_result_iq(DeleteIQRes),
    ok.


delete_group_error_test() ->
    setup(),
    CreateIQ = create_group_IQ(?UID1, ?GROUP_NAME1, [?UID1, ?UID2]),
    CreateIQRes = mod_groups_api:process_local_iq(CreateIQ),
    CreateGroupSt = tutil:get_result_iq_sub_el(CreateIQRes),
    Gid = CreateGroupSt#group_st.gid,

    DeleteIQ1 = delete_group_IQ(?UID2, Gid),
    DeleteIQRes1 = mod_groups_api:process_local_iq(DeleteIQ1),
    Error1 = tutil:get_error_iq_sub_el(DeleteIQRes1),

    DeleteIQ2 = delete_group_IQ(?UID3, Gid),
    DeleteIQRes2 = mod_groups_api:process_local_iq(DeleteIQ2),
    Error2 = tutil:get_error_iq_sub_el(DeleteIQRes2),

    ?assertEqual(util:err(not_admin), Error1),
    ?assertEqual(util:err(not_admin), Error2),
    ok.


create_group(Uid, Name, Members) ->
    IQ = create_group_IQ(Uid, Name, Members),
    IQRes = mod_groups_api:process_local_iq(IQ),
    GroupSt = tutil:get_result_iq_sub_el(IQRes),
    #group_st{gid = Gid} = GroupSt,
    Gid.


modify_members_test() ->
    setup(),
    Gid = create_group(?UID1, ?GROUP_NAME1, [?UID2, ?UID3]),
%%    ?debugVal(Gid, 1000),
    IQ = modify_members_IQ(?UID1, Gid, [{?UID2, remove}, {?UID4, add}, {?UID5, add}]),
    IQRes = mod_groups_api:process_local_iq(IQ),
    GroupSt = tutil:get_result_iq_sub_el(IQRes),
%%    ?debugVal(GroupSt, 1000),
    ?assertMatch(
        #group_st{
            gid = Gid,
            action = modify_members,
            members = [
                #member_st{uid = ?UID2, action = remove, result = ok},
                #member_st{uid = ?UID4, action = add, type = member, result = ok},
                #member_st{uid = ?UID5, action = add, type = member,
                    result = failed, reason = no_account}]
        },
        GroupSt),
    ok.


modify_members_not_admin_test() ->
    setup(),
    Gid = create_group(?UID1, ?GROUP_NAME1, [?UID2, ?UID3]),
%%    ?debugVal(Gid, 1000),
    IQ = modify_members_IQ(?UID2, Gid, [{?UID4, add}, {?UID5, add}]),
    IQRes = mod_groups_api:process_local_iq(IQ),
    Error = tutil:get_error_iq_sub_el(IQRes),
%%    ?debugVal(Error, 1000),
    ?assertEqual(util:err(not_admin), Error),
    ok.


modify_admins_test() ->
    setup(),
    Gid = create_group(?UID1, ?GROUP_NAME1, [?UID2, ?UID3]),
%%    ?debugVal(Gid, 1000),
    IQ = modify_admins_IQ(?UID1, Gid, [{?UID2, promote}, {?UID3, demote}, {?UID5, promote}]),
    IQRes = mod_groups_api:process_local_iq(IQ),
    GroupSt = tutil:get_result_iq_sub_el(IQRes),
%%    ?debugVal(GroupSt, 1000),
    ExpectedGroupSt = #group_st{
        gid = Gid,
        action = modify_admins,
        members = [
            #member_st{uid = ?UID3, action = demote, type = member, result = ok},
            #member_st{uid = ?UID2, action = promote, type = admin, result = ok},
            #member_st{uid = ?UID5, action = promote, type = admin,
                result = failed, reason = not_member}]
    },
%%    ?debugVal(ExpectedGroupSt, 1000),
    ?assertEqual(ExpectedGroupSt, GroupSt),
    ok.


modify_admins_not_admin_test() ->
    setup(),
    Gid = create_group(?UID1, ?GROUP_NAME1, [?UID2, ?UID3]),
    IQ = modify_admins_IQ(?UID2, Gid, [{?UID4, promote}, {?UID3, demote}]),
    IQRes = mod_groups_api:process_local_iq(IQ),
    Error = tutil:get_error_iq_sub_el(IQRes),
    ?assertEqual(util:err(not_admin), Error),
    ok.


get_group_test() ->
    setup(),
    Gid = create_group(?UID1, ?GROUP_NAME1, [?UID2, ?UID3]),
%%    ?debugVal(Gid, 1000),
    IQ = get_group_IQ(?UID1, Gid),
    IQRes = mod_groups_api:process_local_iq(IQ),
    GroupSt = tutil:get_result_iq_sub_el(IQRes),
%%    ?debugVal(GroupSt, 1000),
    ExpectedGroupSt = #group_st{
        gid = Gid,
        name = ?GROUP_NAME1,
        members = [
            #member_st{uid = ?UID1, type = admin},
            #member_st{uid = ?UID2, type = member},
            #member_st{uid = ?UID3, type = member}]
    },
%%    ?debugVal(ExpectedGroupSt, 1000),
    ?assertEqual(ExpectedGroupSt, GroupSt),
    ok.


get_group_error_not_member_test() ->
    setup(),
    Gid = create_group(?UID1, ?GROUP_NAME1, [?UID2, ?UID3]),
    IQ = get_group_IQ(?UID4, Gid),
    IQRes = mod_groups_api:process_local_iq(IQ),
    Error = tutil:get_error_iq_sub_el(IQRes),
    ?assertEqual(util:err(not_member), Error),

    IQ2 = get_group_IQ(?UID1, <<"gdasdkjaskd">>),
    IQRes2 = mod_groups_api:process_local_iq(IQ2),
    Error2 = tutil:get_error_iq_sub_el(IQRes2),
    ?assertEqual(util:err(not_member), Error2),
    ok.


get_groups_test() ->
    setup(),
    Gid1 = create_group(?UID1, ?GROUP_NAME1, [?UID2, ?UID3]),
    Gid2 = create_group(?UID2, ?GROUP_NAME2, [?UID1, ?UID4]),
    IQ = get_groups_IQ(?UID1),
    IQRes = mod_groups_api:process_local_iq(IQ),
    GroupsSt = tutil:get_result_iq_sub_el(IQRes),
%%    ?debugVal(GroupsSt, 1000),
    GroupsSet = lists:sort(GroupsSt#groups.groups),
    ExpectedGroupsSet = lists:sort([
        #group_st{gid = Gid1, name = ?GROUP_NAME1},
        #group_st{gid = Gid2, name = ?GROUP_NAME2}
    ]),
%%    ?debugVal(ExpectedGroupsSet, 1000),
    ?assertEqual(ExpectedGroupsSet, GroupsSet),
    ok.


set_name_test() ->
    setup(),
    Gid = create_group(?UID1, ?GROUP_NAME1, [?UID2, ?UID3]),
    IQ = set_name_IQ(?UID1, Gid, ?GROUP_NAME3),
    IQRes = mod_groups_api:process_local_iq(IQ),
    GroupSt = tutil:get_result_iq_sub_el(IQRes),
%%    ?debugVal(GroupSt, 1000),
    ExpectedGroupSt = #group_st{
        gid = Gid,
        name = ?GROUP_NAME3
    },
%%    ?debugVal(ExpectedGroupSt, 1000),
    ?assertEqual(ExpectedGroupSt, GroupSt),
    ok.


set_name_error_test() ->
    setup(),
    Gid = create_group(?UID1, ?GROUP_NAME1, []),
    IQ = set_name_IQ(?UID1, Gid, <<>>),
    IQRes = mod_groups_api:process_local_iq(IQ),
    Error = tutil:get_error_iq_sub_el(IQRes),
    ?assertEqual(util:err(invalid_name), Error),

    IQ2 = set_name_IQ(?UID2, Gid, ?GROUP_NAME2),
    IQRes2 = mod_groups_api:process_local_iq(IQ2),
    Error2 = tutil:get_error_iq_sub_el(IQRes2),
    ?assertEqual(util:err(not_member), Error2),
    ok.


leave_group_test() ->
    setup(),
    Gid = create_group(?UID1, ?GROUP_NAME1, [?UID2, ?UID3]),
    IQ = leave_group_IQ(?UID2, Gid),
    IQRes = mod_groups_api:process_local_iq(IQ),
%%    ?debugVal(IQRes, 1000),
    ?assertEqual(result, IQRes#iq.type),
    ?assertEqual([], IQRes#iq.sub_els),
    ok.


set_avatar_test() ->
    setup(),
    meck:new(mod_user_avatar, [passthrough]),
    meck:expect(mod_user_avatar, check_and_upload_avatar, fun (_) -> {ok, ?AVATAR1} end),

    Gid = create_group(?UID1, ?GROUP_NAME1, [?UID2, ?UID3]),
    IQ = set_avatar_IQ(?UID2, Gid),
    IQRes = mod_groups_api:process_local_iq(IQ),
    ?assertEqual(result, IQRes#iq.type),
    ?assertEqual([#group_st{
        gid = Gid,
        name = ?GROUP_NAME1,
        avatar = ?AVATAR1
    }], IQRes#iq.sub_els),

    GroupInfo = model_groups:get_group_info(Gid),
    ?assertEqual(?AVATAR1, GroupInfo#group_info.avatar),

    ?assert(meck:validate(mod_user_avatar)),
    meck:unload(mod_user_avatar),
    ok.


delete_avatar_test() ->
    setup(),
    meck:new(mod_user_avatar, [passthrough]),
    meck:expect(mod_user_avatar, check_and_upload_avatar, fun (_) -> {ok, ?AVATAR1} end),
    meck:expect(mod_user_avatar, delete_avatar_s3, fun (_) -> ok end),

    % First create the group and set the avatar
    Gid = create_group(?UID1, ?GROUP_NAME1, [?UID2, ?UID3]),
    IQ = set_avatar_IQ(?UID2, Gid),
    IQRes = mod_groups_api:process_local_iq(IQ),
    ?assertEqual(result, IQRes#iq.type),
    ?assertEqual([#group_st{
        gid = Gid,
        name = ?GROUP_NAME1,
        avatar = ?AVATAR1
    }], IQRes#iq.sub_els),

    GroupInfo = model_groups:get_group_info(Gid),
    ?assertEqual(?AVATAR1, GroupInfo#group_info.avatar),

    % Now try to delete it
    IQ2 = delete_avatar_IQ(?UID2, Gid),
    IQRes2 = mod_groups_api:process_local_iq(IQ2),
    ?assertEqual(result, IQRes2#iq.type),
    ?assertEqual([], IQRes2#iq.sub_els),

    GroupInfo2 = model_groups:get_group_info(Gid),
    ?assertEqual(undefined, GroupInfo2#group_info.avatar),

    ?assert(meck:validate(mod_user_avatar)),
    meck:unload(mod_user_avatar),
    ok.


publish_group_feed_test() ->
    setup(),

    % First create the group and set the avatar
    Gid = create_group(?UID1, ?GROUP_NAME1, [?UID2, ?UID3]),

    meck:new(ejabberd_router_multicast, [passthrough]),
    meck:expect(ejabberd_router_multicast, route_multicast,
        fun(_From, Server, BroadcastJids, Packet) ->
            [SubEl] = Packet#message.sub_els,
            ?assertEqual(?GROUP_NAME1, SubEl#group_feed_st.name),
            ?assertEqual(undefined, SubEl#group_feed_st.avatar_id),
            ?assertEqual(undefined, SubEl#group_feed_st.comment),
            ?assertEqual(?UID1, SubEl#group_feed_st.post#group_post_st.publisher_uid),
            ?assertNotEqual(undefined, SubEl#group_feed_st.post#group_post_st.timestamp),
            ReceiverJids = util:uids_to_jids([?UID2, ?UID3], Server),
            ?assertEqual(lists:sort(ReceiverJids), lists:sort(BroadcastJids)),
            ok
        end),

    PostSt = make_group_post_st(?ID1, <<>>, <<>>, ?PAYLOAD1, undefined),
    CommentSt = undefined,
    GroupFeedSt = make_group_feed_st(Gid, <<>>, undefined, publish, PostSt, CommentSt),
    GroupFeedIq = make_group_feed_iq(?UID1, GroupFeedSt),
    ResultIQ = mod_group_feed:process_local_iq(GroupFeedIq),

    [SubEl] = ResultIQ#iq.sub_els,
    ?assertEqual(result, ResultIQ#iq.type),
    ?assertEqual(Gid, SubEl#group_feed_st.gid),
    ?assertEqual(?UID1, SubEl#group_feed_st.post#group_post_st.publisher_uid),
    ?assertNotEqual(undefined, SubEl#group_feed_st.post#group_post_st.timestamp),
    ?assert(meck:validate(ejabberd_router_multicast)),
    meck:unload(ejabberd_router_multicast),

    {ok, Post} = model_feed:get_post(?ID1),
    ?assertEqual(?ID1, Post#post.id),
    ?assertEqual(?UID1, Post#post.uid),
    ?assertEqual(?PAYLOAD1, Post#post.payload),
    ?assertEqual(group, Post#post.audience_type),
    ?assertEqual(lists:sort([?UID1, ?UID2, ?UID3]), lists:sort(Post#post.audience_list)),
    ?assertEqual(Gid, Post#post.gid),
    ok.


retract_group_feed_test() ->
    setup(),

    % First create the group and set the avatar
    Gid = create_group(?UID1, ?GROUP_NAME1, [?UID2, ?UID3]),

    Timestamp = util:now_ms(),
    ok = model_feed:publish_post(?ID2, ?UID1, <<>>, all, [?UID1, ?UID2, ?UID3], Timestamp, Gid),
    ok = model_feed:publish_comment(?ID1, ?ID2, ?UID2, <<>>, [?UID1, ?UID2], <<>>, Timestamp),

    meck:new(ejabberd_router_multicast, [passthrough]),
    meck:expect(ejabberd_router_multicast, route_multicast,
        fun(_From, Server, BroadcastJids, Packet) ->
            [SubEl] = Packet#message.sub_els,
            ?assertEqual(?GROUP_NAME1, SubEl#group_feed_st.name),
            ?assertEqual(undefined, SubEl#group_feed_st.avatar_id),
            ?assertEqual(undefined, SubEl#group_feed_st.post),
            ?assertEqual(?UID2, SubEl#group_feed_st.comment#group_comment_st.publisher_uid),
            ?assertNotEqual(undefined, SubEl#group_feed_st.comment#group_comment_st.timestamp),
            ReceiverJids = util:uids_to_jids([?UID1, ?UID3], Server),
            ?assertEqual(lists:sort(ReceiverJids), lists:sort(BroadcastJids)),
            ok
        end),

    PostSt = undefined,
    CommentSt = make_group_comment_st(?ID1, ?ID2, <<>>, <<>>, <<>>, <<>>, undefined),
    GroupFeedSt = make_group_feed_st(Gid, <<>>, undefined, retract, PostSt, CommentSt),
    GroupFeedIq = make_group_feed_iq(?UID2, GroupFeedSt),
    ResultIQ = mod_group_feed:process_local_iq(GroupFeedIq),

    [SubEl] = ResultIQ#iq.sub_els,
    ?assertEqual(result, ResultIQ#iq.type),
    ?assertEqual(Gid, SubEl#group_feed_st.gid),
    ?assertEqual(?UID2, SubEl#group_feed_st.comment#group_comment_st.publisher_uid),
    ?assertNotEqual(undefined, SubEl#group_feed_st.comment#group_comment_st.timestamp),
    ?assert(meck:validate(ejabberd_router_multicast)),
    meck:unload(ejabberd_router_multicast),

    ?assertEqual({error, missing}, model_feed:get_comment(?ID1, ?ID2)),
    ok.

%% TODO(murali@): add more unit tests here.

