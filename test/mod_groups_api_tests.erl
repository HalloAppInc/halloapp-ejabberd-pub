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
-include("packets.hrl").
-include("groups_test_data.hrl").
-include("packets.hrl").

-include_lib("eunit/include/eunit.hrl").


setup() ->
    tutil:setup(),
    stringprep:start(),
    gen_iq_handler:start(ejabberd_local),
    ejabberd_hooks:start_link(),
    ha_redis:start(),
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
    MemberSt = [#pb_group_member{uid = Ouid} || Ouid <- Uids],
    #pb_iq{
        from_uid = Uid,
        type = set,
        payload =
            #pb_group_stanza{
                action = create,
                name = Name,
                members = MemberSt
            }
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
    avatar_IQ(Uid, Gid, undefined).


avatar_IQ(Uid, Gid, Data) ->
    #pb_iq{
        from_uid = Uid,
        type = set,
        payload =
            #pb_upload_group_avatar{
                gid =  Gid,
                data = Data
            }
    }.


set_name_IQ(Uid, Gid, Name) ->
    #pb_iq{
        from_uid = Uid,
        type = set,
        payload =
            #pb_group_stanza{
                gid = Gid,
                action = set_name,
                name = Name
            }
    }.


make_group_IQ(Uid, Gid, Type, Action, Changes) ->
    MemberSt = [#pb_group_member{uid = Ouid, action = MAction} || {Ouid, MAction} <- Changes],
    #pb_iq{
        from_uid = Uid,
        type = Type,
        payload =
            #pb_group_stanza{
                gid = Gid,
                action = Action,
                members = MemberSt
            }
    }.


get_groups_IQ(Uid) ->
    #pb_iq{
        from_uid = Uid,
        type = get,
        payload =
            #pb_groups_stanza{action = get}
    }.


make_pb_post(PostId, PublisherUid, PublisherName, Payload, Timestamp) ->
    #pb_post{
        id = PostId,
        publisher_uid = PublisherUid,
        publisher_name = PublisherName,
        payload = Payload,
        timestamp = Timestamp
    }.


make_pb_comment(CommentId, PostId, PublisherUid,
        PublisherName, ParentCommentId, Payload, Timestamp) ->
    #pb_comment{
        id = CommentId,
        post_id = PostId,
        publisher_uid = PublisherUid,
        publisher_name = PublisherName,
        parent_comment_id = ParentCommentId,
        payload = Payload,
        timestamp = Timestamp
    }.

make_pb_group_feed_item(Gid, Name, AvatarId, Action, Item) ->
    #pb_group_feed_item{
        gid = Gid,
        name = Name,
        avatar_id = AvatarId,
        action = Action,
        item = Item
    }.

make_group_feed_iq(Uid, GroupFeedSt) ->
    #pb_iq{
        from_uid = Uid,
        type = set,
        payload = GroupFeedSt
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
    #pb_group_stanza{
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
    #pb_group_stanza{
        gid = _Gid,
        name = ?GROUP_NAME1,
        members = Members
    } = GroupSt,
%%    ?debugVal(Members),
    M2 = #pb_group_member{uid = ?UID2, type = member, result = <<"ok">>, reason = undefined},
    M3 = #pb_group_member{uid = ?UID3, type = member, result = <<"ok">>, reason = undefined},
    M5 = #pb_group_member{uid = ?UID5, type = member, result = <<"failed">>, reason = <<"no_account">>},
    ?assertEqual([M2, M3, M5], Members),
    ok.


create_group_with_creator_as_member_test() ->
    setup(),
    IQ = create_group_IQ(?UID1, ?GROUP_NAME1, [?UID1, ?UID2]),
    IQRes = mod_groups_api:process_local_iq(IQ),
    GroupSt = tutil:get_result_iq_sub_el(IQRes),
    #pb_group_stanza{
        gid = _Gid,
        name = ?GROUP_NAME1,
        members = Members
    } = GroupSt,
%%    ?debugVal(Members),
    M1 = #pb_group_member{uid = ?UID1, type = admin, result = <<"failed">>, reason = <<"already_member">>},
    M2 = #pb_group_member{uid = ?UID2, type = member, result = <<"ok">>, reason = undefined},
    ?assertEqual([M1, M2], Members),
    ok.


delete_group_test() ->
    setup(),
    CreateIQ = create_group_IQ(?UID1, ?GROUP_NAME1, [?UID1, ?UID2]),
    CreateIQRes = mod_groups_api:process_local_iq(CreateIQ),
    CreateGroupSt = tutil:get_result_iq_sub_el(CreateIQRes),
    Gid = CreateGroupSt#pb_group_stanza.gid,

    DeleteIQ = delete_group_IQ(?UID1, Gid),
    DeleteIQRes = mod_groups_api:process_local_iq(DeleteIQ),
    ok = tutil:assert_empty_result_iq(DeleteIQRes),
    ok.


delete_group_error_test() ->
    setup(),
    CreateIQ = create_group_IQ(?UID1, ?GROUP_NAME1, [?UID1, ?UID2]),
    CreateIQRes = mod_groups_api:process_local_iq(CreateIQ),
    CreateGroupSt = tutil:get_result_iq_sub_el(CreateIQRes),
    Gid = CreateGroupSt#pb_group_stanza.gid,

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
    #pb_group_stanza{gid = Gid} = GroupSt,
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
        #pb_group_stanza{
            gid = Gid,
            action = modify_members,
            members = [
                #pb_group_member{uid = ?UID2, action = remove, result = <<"ok">>},
                #pb_group_member{uid = ?UID4, action = add, type = member, result = <<"ok">>},
                #pb_group_member{uid = ?UID5, action = add, type = member,
                    result = <<"failed">>, reason = <<"no_account">>}]
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
    ExpectedGroupSt = #pb_group_stanza{
        gid = Gid,
        action = modify_admins,
        avatar_id = undefined,
        sender_name = undefined,
        members = [
            #pb_group_member{uid = ?UID3, action = demote, type = member,
                result = <<"ok">>, reason = undefined},
            #pb_group_member{uid = ?UID2, action = promote, type = admin,
                result = <<"ok">>, reason = undefined},
            #pb_group_member{uid = ?UID5, action = promote, type = admin,
                result = <<"failed">>, reason = <<"not_member">>}]
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
    ExpectedGroupSt = #pb_group_stanza{
        gid = Gid,
        name = ?GROUP_NAME1,
        avatar_id = undefined,
        members = [
            #pb_group_member{uid = ?UID1, name = ?NAME1, type = admin},
            #pb_group_member{uid = ?UID2, name = ?NAME2, type = member},
            #pb_group_member{uid = ?UID3, name = ?NAME3, type = member}]
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
    GroupsSet = lists:sort(GroupsSt#pb_groups_stanza.group_stanzas),
    ExpectedGroupsSet = lists:sort([
        #pb_group_stanza{gid = Gid1, name = ?GROUP_NAME1, avatar_id = undefined},
        #pb_group_stanza{gid = Gid2, name = ?GROUP_NAME2, avatar_id = undefined}
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
    ExpectedGroupSt = #pb_group_stanza{
        gid = Gid,
        name = ?GROUP_NAME3,
        avatar_id = undefined
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
    ?assertEqual(result, IQRes#pb_iq.type),
    ?assertEqual(undefined, IQRes#pb_iq.payload),
    ok.


set_avatar_test() ->
    setup(),
    meck:new(mod_user_avatar, [passthrough]),
    meck:expect(mod_user_avatar, check_and_upload_avatar, fun (_) -> {ok, ?AVATAR1} end),

    Gid = create_group(?UID1, ?GROUP_NAME1, [?UID2, ?UID3]),
    IQ = set_avatar_IQ(?UID2, Gid),
    IQRes = mod_groups_api:process_local_iq(IQ),
    ?assertEqual(result, IQRes#pb_iq.type),
    ?assertEqual(#pb_group_stanza{
        gid = Gid,
        name = ?GROUP_NAME1,
        avatar_id = ?AVATAR1
    }, IQRes#pb_iq.payload),

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
    ?assertEqual(result, IQRes#pb_iq.type),
    ?assertEqual(#pb_group_stanza{
        gid = Gid,
        name = ?GROUP_NAME1,
        avatar_id = ?AVATAR1
    }, IQRes#pb_iq.payload),

    GroupInfo = model_groups:get_group_info(Gid),
    ?assertEqual(?AVATAR1, GroupInfo#group_info.avatar),

    % Now try to delete it
    IQ2 = delete_avatar_IQ(?UID2, Gid),
    IQRes2 = mod_groups_api:process_local_iq(IQ2),
    ?assertEqual(result, IQRes2#pb_iq.type),
    ?assertEqual(undefined, IQRes2#pb_iq.payload),

    GroupInfo2 = model_groups:get_group_info(Gid),
    ?assertEqual(undefined, GroupInfo2#group_info.avatar),

    ?assert(meck:validate(mod_user_avatar)),
    meck:unload(mod_user_avatar),
    ok.


publish_group_feed_test() ->
    setup(),

    % First create the group and set the avatar
    Gid = create_group(?UID1, ?GROUP_NAME1, [?UID2, ?UID3]),
    Server = <<>>,
    meck:new(ejabberd_router, [passthrough]),
    meck:expect(ejabberd_router, route_multicast,
        fun(_FromUid, BroadcastUids, Packet) ->
            [SubEl] = Packet#message.sub_els,
            ?assertEqual(?GROUP_NAME1, SubEl#group_feed_st.name),
            ?assertEqual(undefined, SubEl#group_feed_st.avatar_id),
            ?assertEqual([], SubEl#group_feed_st.comments),
            [Post] = SubEl#group_feed_st.posts,
            ?assertEqual(?UID1, Post#group_post_st.publisher_uid),
            ?assertNotEqual(undefined, Post#group_post_st.timestamp),
            ?assertEqual(lists:sort([?UID2, ?UID3]), lists:sort(BroadcastUids)),
            ok
        end),

    PostSt = make_pb_post(?ID1, <<>>, <<>>, ?PAYLOAD1, undefined),
    GroupFeedSt = make_pb_group_feed_item(Gid, <<>>, undefined, publish, PostSt),
    GroupFeedIq = make_group_feed_iq(?UID1, GroupFeedSt),
    ResultIQ = mod_group_feed:process_local_iq(GroupFeedIq),

    SubEl = ResultIQ#pb_iq.payload,
    ?assertEqual(result, ResultIQ#pb_iq.type),

    ?assertEqual(Gid, SubEl#pb_group_feed_item.gid),
    GroupPostSt = SubEl#pb_group_feed_item.item,
    ?assertEqual(?UID1, GroupPostSt#pb_post.publisher_uid),
    ?assertNotEqual(undefined, GroupPostSt#pb_post.timestamp),
    ?assert(meck:validate(ejabberd_router)),
    meck:unload(ejabberd_router),

    {ok, Post} = model_feed:get_post(?ID1),
    ?assertEqual(?ID1, Post#post.id),
    ?assertEqual(?UID1, Post#post.uid),
    ?assertEqual(?PAYLOAD1, base64:decode(Post#post.payload)),
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
    Server = <<>>,
    meck:new(ejabberd_router, [passthrough]),
    meck:expect(ejabberd_router, route_multicast,
        fun(_FromUid, BroadcastUids, Packet) ->
            [SubEl] = Packet#message.sub_els,
            ?assertEqual(?GROUP_NAME1, SubEl#group_feed_st.name),
            ?assertEqual(undefined, SubEl#group_feed_st.avatar_id),
            ?assertEqual([], SubEl#group_feed_st.posts),
            [Comment] = SubEl#group_feed_st.comments,
            ?assertEqual(?UID2, Comment#group_comment_st.publisher_uid),
            ?assertNotEqual(undefined, Comment#group_comment_st.timestamp),
            ?assertEqual(lists:sort([?UID1, ?UID3]), lists:sort(BroadcastUids)),
            ok
        end),

    CommentSt = make_pb_comment(?ID1, ?ID2, <<>>, <<>>, <<>>, <<>>, undefined),
    GroupFeedSt = make_pb_group_feed_item(Gid, <<>>, undefined, retract, CommentSt),
    GroupFeedIq = make_group_feed_iq(?UID2, GroupFeedSt),
    ResultIQ = mod_group_feed:process_local_iq(GroupFeedIq),

    SubEl = ResultIQ#pb_iq.payload,
    ?assertEqual(result, ResultIQ#pb_iq.type),
    ?assertEqual(Gid, SubEl#pb_group_feed_item.gid),
    GroupCommentSt = SubEl#pb_group_feed_item.item,
    ?assertEqual(?UID2, GroupCommentSt#pb_comment.publisher_uid),
    ?assertNotEqual(undefined, GroupCommentSt#pb_comment.timestamp),
    ?assert(meck:validate(ejabberd_router)),
    meck:unload(ejabberd_router),

    ?assertEqual({error, missing}, model_feed:get_comment(?ID1, ?ID2)),
    ok.

%% TODO(murali@): add more unit tests here.

