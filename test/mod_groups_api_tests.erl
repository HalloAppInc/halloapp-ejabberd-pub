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
    tutil:load_protobuf(),
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
    create_group_IQ(Uid, Name, [], false).


create_group_IQ(Uid, Name, Uids) ->
    create_group_IQ(Uid, Name, Uids, false).


create_group_IQ(Uid, Name, Uids, IsShuffle) ->
    Uids2 = case IsShuffle of
        true -> util:random_shuffle(Uids);
        false -> Uids
    end,
    MemberSt = [#pb_group_member{uid = Ouid} || Ouid <- Uids2],
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

create_sender_state_bundles(SenderStateTuples) ->
    [#pb_sender_state_bundle{uid = Ouid, sender_state = create_sender_state(EncSenderState)}
        || {Ouid, EncSenderState} <- SenderStateTuples].

create_sender_state(EncSenderState) ->
    #pb_sender_state_with_key_info{enc_sender_state = EncSenderState}.


delete_group_IQ(Uid, Gid) ->
    make_group_IQ(Uid, Gid, set, delete, []).


modify_members_IQ(Uid, Gid, Changes) ->
    make_group_IQ(Uid, Gid, set, modify_members, Changes).


modify_members_IQ(Uid, Gid, Changes, PBHistoryResend) ->
    make_group_IQ(Uid, Gid, set, modify_members, Changes, PBHistoryResend).


share_history_IQ(Uid, Gid, Changes, PBHistoryResend) ->
    make_group_IQ(Uid, Gid, set, share_history, Changes, PBHistoryResend).


modify_admins_IQ(Uid, Gid, Changes) ->
    make_group_IQ(Uid, Gid, set, modify_admins, Changes).


get_group_IQ(Uid, Gid) ->
    make_group_IQ(Uid, Gid, get, get, []).


get_group_identity_keys(Uid, Gid) ->
    make_group_IQ(Uid, Gid, get, get_member_identity_keys, []).


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


set_description_IQ(Uid, Gid, Description) ->
    #pb_iq{
        from_uid = Uid,
        type = set,
        payload =
            #pb_group_stanza{
                gid = Gid,
                action = change_description,
                description = Description
            }
    }.

set_background_IQ(Uid, Gid, Background) ->
    #pb_iq{
        from_uid = Uid,
        type = set,
        payload =
        #pb_group_stanza{
            gid = Gid,
            action = set_background,
            background = Background
        }
    }.

make_group_IQ(Uid, Gid, Type, Action, Changes) ->
    make_group_IQ(Uid, Gid, Type, Action, Changes, undefined).


make_group_IQ(Uid, Gid, Type, Action, Changes, PBHistoryResend) ->
    MemberSt = [#pb_group_member{uid = Ouid, action = MAction} || {Ouid, MAction} <- Changes],
    #pb_iq{
        from_uid = Uid,
        type = Type,
        payload =
            #pb_group_stanza{
                gid = Gid,
                action = Action,
                members = MemberSt,
                history_resend = PBHistoryResend
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

make_pb_group_feed_item(Gid, Name, AvatarId, Action, Item, SenderStateBundles, AudienceHash) ->
    #pb_group_feed_item{
        gid = Gid,
        name = Name,
        avatar_id = AvatarId,
        action = Action,
        item = Item,
        sender_state_bundles = SenderStateBundles,
        audience_hash = AudienceHash
    }.

make_group_feed_iq(Uid, GroupFeedSt) ->
    #pb_iq{
        from_uid = Uid,
        type = set,
        payload = GroupFeedSt
    }.

make_pb_history_resend(Gid, Id, Payload, SenderStateBundles, AudienceHash) ->
    #pb_history_resend{
        gid = Gid,
        id = Id,
        payload = Payload,
        sender_state_bundles = SenderStateBundles,
        audience_hash = AudienceHash
    }.

make_history_resend_iq(Uid, HistoryResendSt) ->
    #pb_iq{
        from_uid = Uid,
        type = set,
        payload = HistoryResendSt
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
        members = [],
        expiry_info = #pb_expiry_info{
            expiry_type = expires_in_seconds,
            expires_in_seconds = 2592000
        }
    } = GroupSt,
    ?assertEqual(true, model_groups:group_exists(Gid)),
    ?assertEqual(
        {ok, #group_info{gid = Gid, name = ?GROUP_NAME1,
            expiry_info = #expiry_info{expiry_type = expires_in_seconds, expires_in_seconds = 2592000}}},
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


create_group_with_identity_keys(Uid, Name, Members) ->
    List = Members ++ [Uid],
    {FinalIKAcc, UidToIKMap, SizeIKBits2} = lists:foldl(
        fun(MemberUid, Acc) ->
            {IK, SK, OTKS} = tutil:gen_whisper_keys(16, 64),
            mod_whisper:set_keys_and_notify(MemberUid, IK, SK, OTKS),
            IKBin2 = decode_ik(IK),
            SizeIKBits = byte_size(IKBin2) * 8,
            <<IKInt:SizeIKBits>> = IKBin2,
            {XorIK, IKMap, _} = Acc,
            NewIKAcc = XorIK bxor IKInt,
            {NewIKAcc, maps:put(MemberUid, base64:decode(IK), IKMap), SizeIKBits}
        end, {0, #{}, 0}, List),
    AudienceHash = crypto:hash(?SHA256, <<FinalIKAcc:SizeIKBits2>>),
    <<TruncAudienceHash:?TRUNC_HASH_LENGTH/binary, _Rem/binary>> = AudienceHash,
    IQ = create_group_IQ(Uid, Name, Members, true),
    IQRes = mod_groups_api:process_local_iq(IQ),
    GroupSt = tutil:get_result_iq_sub_el(IQRes),
    #pb_group_stanza{gid = Gid} = GroupSt,
    {Gid, TruncAudienceHash, UidToIKMap}.


decode_ik(IK) ->
    _IKBin2 = try enif_protobuf:decode(base64:decode(IK), pb_identity_key) of
        #pb_identity_key{public_key = IKPublicKey} ->
            IKPublicKey
    catch Class : Reason : St ->
        ?debugFmt("failed to parse identity key: ~p", 
            [IK, lager:pr_stacktrace(St, {Class, Reason})]),
        ?assert(false)
    end.


create_group(Uid, Name, Members) ->
    create_group(Uid, Name, Members, false).


create_group(Uid, Name, Members, IsShuffle) ->
    IQ = create_group_IQ(Uid, Name, Members, IsShuffle),
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


share_history_test() ->
    setup(),
    Gid = create_group(?UID1, ?GROUP_NAME1, [?UID2, ?UID3]),
    IQ = share_history_IQ(?UID1, Gid, [{?UID2, add}, {?UID3, add}, {?UID4, add}, {?UID5, add}], undefined),
    IQRes = mod_groups_api:process_local_iq(IQ),
    GroupSt = tutil:get_result_iq_sub_el(IQRes),
    ?assertMatch(
        #pb_group_stanza{
            gid = Gid,
            action = share_history,
            members = [
                #pb_group_member{uid = ?UID2, action = add, result = <<"ok">>},
                #pb_group_member{uid = ?UID3, action = add, type = member, result = <<"ok">>},
                #pb_group_member{uid = ?UID4, action = add, type = member,
                    result = <<"failed">>, reason = <<"not_member">>},
                #pb_group_member{uid = ?UID5, action = add, type = member,
                    result = <<"failed">>, reason = <<"no_account">>}]
        },
        GroupSt),
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
        action = get,
        gid = Gid,
        name = ?GROUP_NAME1,
        description = undefined,
        avatar_id = undefined,
        background = undefined,
        members = [
            #pb_group_member{uid = ?UID1, name = ?NAME1, type = admin, identity_key = undefined},
            #pb_group_member{uid = ?UID2, name = ?NAME2, type = member, identity_key = undefined},
            #pb_group_member{uid = ?UID3, name = ?NAME3, type = member, identity_key = undefined}],
        audience_hash = undefined,
        expiry_info = #pb_expiry_info{
            expiry_type = expires_in_seconds,
            expires_in_seconds = 30 * 86400,
            expiry_timestamp = undefined
        }
    },
%%    ?debugVal(ExpectedGroupSt, 1000),
    ?assertEqual(ExpectedGroupSt, GroupSt),
    ok.


get_group_identity_keys_test() ->
    setup(),
    {Gid, LocalHash, IKMap} = create_group_with_identity_keys(?UID1, ?GROUP_NAME1, [?UID2, ?UID3]),
    IQ = get_group_identity_keys(?UID1, Gid),
    IQRes = mod_groups_api:process_local_iq(IQ),
    GroupSt = tutil:get_result_iq_sub_el(IQRes),
    IK1 = maps:get(?UID1, IKMap, undefined),
    IK2 = maps:get(?UID2, IKMap, undefined),
    IK3 = maps:get(?UID3, IKMap, undefined),
    #pb_group_stanza{
        action = get_member_identity_keys,
        gid = Gid,
        name = ?GROUP_NAME1,
        avatar_id = undefined,
        background = undefined,
        description = undefined,
        members = [
            #pb_group_member{uid = ?UID1, name = ?NAME1, type = admin, identity_key = IK1},
            #pb_group_member{uid = ?UID2, name = ?NAME2, type = member, identity_key = IK2},
            #pb_group_member{uid = ?UID3, name = ?NAME3, type = member, identity_key = IK3}
        ],
        audience_hash = AudienceHash,
        expiry_info = #pb_expiry_info{
            expiry_type = expires_in_seconds,
            expires_in_seconds = 30 * 86400
        }
    } = GroupSt,
    ?assertEqual(?TRUNC_HASH_LENGTH, byte_size(AudienceHash)),
    ?assertEqual(LocalHash, AudienceHash),
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
        #pb_group_stanza{gid = Gid1, name = ?GROUP_NAME1,
            description = undefined, avatar_id = undefined, background = undefined},
        #pb_group_stanza{gid = Gid2, name = ?GROUP_NAME2,
            description = undefined, avatar_id = undefined, background = undefined}
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
        avatar_id = undefined,
        background = undefined,
        description = undefined
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


set_description_test() ->
    setup(),
    Gid = create_group(?UID1, ?GROUP_NAME1, [?UID2, ?UID3]),
    IQ = set_description_IQ(?UID1, Gid, ?GROUP_DESCRIPTION1),
    IQRes = mod_groups_api:process_local_iq(IQ),
    GroupSt = tutil:get_result_iq_sub_el(IQRes),
    ExpectedGroupSt = #pb_group_stanza{
        gid = Gid,
        name = ?GROUP_NAME1,
        description = ?GROUP_DESCRIPTION1,
        avatar_id = undefined,
        background = undefined
    },
    ?assertEqual(ExpectedGroupSt, GroupSt),
    ok.


set_description_error_test() ->
    setup(),
    Gid = create_group(?UID1, ?GROUP_NAME1, []),
    IQ = set_description_IQ(?UID1, Gid, undefined),
    IQRes = mod_groups_api:process_local_iq(IQ),
    GroupSt = tutil:get_result_iq_sub_el(IQRes),
    ExpectedGroupSt = #pb_group_stanza{
        gid = Gid,
        name = ?GROUP_NAME1,
        description = <<>>,
        avatar_id = undefined,
        background = undefined
    },
    ?assertEqual(ExpectedGroupSt, GroupSt),

    IQ2 = set_name_IQ(?UID2, Gid, ?GROUP_DESCRIPTION1),
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
    meck:expect(mod_user_avatar, check_and_upload_avatar, fun (_, _) -> {ok, ?AVATAR1} end),

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
    meck:expect(mod_user_avatar, check_and_upload_avatar, fun (_, _) -> {ok, ?AVATAR1} end),
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
    ?assertEqual(#pb_group_stanza{
        gid = Gid,
        name = ?GROUP_NAME1,
        avatar_id = <<>>
    }, IQRes2#pb_iq.payload),

    GroupInfo2 = model_groups:get_group_info(Gid),
    ?assertEqual(undefined, GroupInfo2#group_info.avatar),

    ?assert(meck:validate(mod_user_avatar)),
    meck:unload(mod_user_avatar),
    ok.

set_background_test() ->
    setup(),
    Gid = create_group(?UID1, ?GROUP_NAME1, [?UID2, ?UID3]),
    IQ = set_background_IQ(?UID1, Gid, ?BACKGROUND1),
    IQRes = mod_groups_api:process_local_iq(IQ),
    GroupSt = tutil:get_result_iq_sub_el(IQRes),
    ExpectedGroupSt = #pb_group_stanza{
        gid = Gid,
        background = ?BACKGROUND1
    },
    ?assertEqual(ExpectedGroupSt, GroupSt),

    %% unset the background
    IQ2 = set_background_IQ(?UID1, Gid, undefined),
    IQ2Res = mod_groups_api:process_local_iq(IQ2),
    GroupSt2 = tutil:get_result_iq_sub_el(IQ2Res),
    ExpectedGroupSt2 = #pb_group_stanza{
        gid = Gid,
        background = undefined
    },
    ?assertEqual(ExpectedGroupSt2, GroupSt2),
    ok.

get_groups_background_test() ->
    setup(),
    Gid = create_group(?UID1, ?GROUP_NAME1, [?UID2, ?UID3]),
    IQ = set_background_IQ(?UID1, Gid, ?BACKGROUND1),
    IQRes = mod_groups_api:process_local_iq(IQ),
    GroupSt = tutil:get_result_iq_sub_el(IQRes),
    ExpectedGroupSt = #pb_group_stanza{
        gid = Gid,
        background = ?BACKGROUND1
    },
    ?assertEqual(ExpectedGroupSt, GroupSt),

    % Test get_group returns right background
    IQ2 = get_group_IQ(?UID2, Gid),
    IQRes2 = mod_groups_api:process_local_iq(IQ2),
    GroupSt2 = tutil:get_result_iq_sub_el(IQRes2),
    ?assertEqual(?BACKGROUND1, GroupSt2#pb_group_stanza.background),

    % Test get_groups returns right backgroud

    IQ3 = get_groups_IQ(?UID3),
    IQRes3 = mod_groups_api:process_local_iq(IQ3),
    GroupsSt3 = tutil:get_result_iq_sub_el(IQRes3),
    [GroupSt3] = GroupsSt3#pb_groups_stanza.group_stanzas,
    ?assertEqual(?BACKGROUND1, GroupSt3#pb_group_stanza.background),
    ok.

publish_group_feed_bad_audience_hash_test() ->
    setup(),
    % First create the group and set the avatar
    {Gid, _LocalHash, _IKMap} = create_group_with_identity_keys(?UID1, ?GROUP_NAME1, [?UID2, ?UID3]),
    meck:new(ejabberd_router, [passthrough]),
    meck:expect(ejabberd_router, route_multicast, fun (_, _, _) -> ok end),
    meck:expect(ejabberd_router, route, fun(_) -> ok end),

    PostSt = make_pb_post(?ID1, <<>>, <<>>, ?PAYLOAD1, undefined),
    SenderStateBundles = create_sender_state_bundles(
        [{?UID2, ?ENC_SENDER_STATE2}, {?UID3, ?ENC_SENDER_STATE3}]),
    GroupFeedSt = make_pb_group_feed_item(Gid, <<>>, undefined, publish, PostSt, SenderStateBundles, ?BAD_HASH),
    GroupFeedIq = make_group_feed_iq(?UID1, GroupFeedSt),
    ResultIQ = mod_group_feed:process_local_iq(GroupFeedIq),

    SubEl = ResultIQ#pb_iq.payload,
    ?assertEqual(error, ResultIQ#pb_iq.type),

    ?assertEqual(<<"audience_hash_mismatch">>, SubEl#pb_error_stanza.reason),
    ?assertEqual(0, meck:num_calls(ejabberd_router, route_multicast, '_')),
    ?assertEqual(0, meck:num_calls(ejabberd_router, route, '_')),
    ?assert(meck:validate(ejabberd_router)),
    meck:unload(ejabberd_router),

    {error, missing} = model_feed:get_post(?ID1),
    ok.

publish_group_feed_with_audience_hash_test() ->
    publish_group_feed_helper(true).

publish_group_feed_without_audience_hash_test() ->
    publish_group_feed_helper(false).

publish_group_feed_helper(WithAudienceHash) ->
    setup(),
    % First create the group and set the avatar
    {Gid, AudienceHash, _} = create_group_with_identity_keys(?UID1, ?GROUP_NAME1, [?UID2, ?UID3]),
    meck:new(ejabberd_router, [passthrough]),

    meck:expect(ejabberd_router, route,
        fun(Packet) ->
            ?assertEqual(?UID1, Packet#pb_msg.from_uid),
            ?assert(Packet#pb_msg.to_uid =:= ?UID2 orelse Packet#pb_msg.to_uid =:= ?UID3),
            SubEl = Packet#pb_msg.payload,
            ?assertEqual(?GROUP_NAME1, SubEl#pb_group_feed_item.name),
            ?assertEqual(undefined, SubEl#pb_group_feed_item.avatar_id),
            Post = SubEl#pb_group_feed_item.item,
            ?assertEqual(?UID1, Post#pb_post.publisher_uid),
            ?assertNotEqual(undefined, Post#pb_post.timestamp),
            ?assert(SubEl#pb_group_feed_item.sender_state =:= create_sender_state(?ENC_SENDER_STATE2) orelse
                SubEl#pb_group_feed_item.sender_state =:= create_sender_state(?ENC_SENDER_STATE3)),
            ok
        end),

    PostSt = make_pb_post(?ID1, <<>>, <<>>, ?PAYLOAD1, undefined),
    SenderStateBundles = create_sender_state_bundles(
        [{?UID2, ?ENC_SENDER_STATE2}, {?UID3, ?ENC_SENDER_STATE3}]),
    GroupFeedSt = case WithAudienceHash of
        true -> make_pb_group_feed_item(Gid, <<>>, undefined, publish, PostSt, SenderStateBundles, AudienceHash);
        false -> make_pb_group_feed_item(Gid, <<>>, undefined, publish, PostSt, SenderStateBundles, <<>>)
    end,
    GroupFeedIq = make_group_feed_iq(?UID1, GroupFeedSt),
    ResultIQ = mod_group_feed:process_local_iq(GroupFeedIq),

    SubEl = ResultIQ#pb_iq.payload,
    ?assertEqual(result, ResultIQ#pb_iq.type),

    ?assertEqual(Gid, SubEl#pb_group_feed_item.gid),
    GroupPostSt = SubEl#pb_group_feed_item.item,
    ?assertEqual(?UID1, GroupPostSt#pb_post.publisher_uid),
    ?assertNotEqual(undefined, GroupPostSt#pb_post.timestamp),
    ?assertEqual(2, meck:num_calls(ejabberd_router, route, '_')),
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

history_resend_bad_audience_hash_test() ->
    setup(),
    % First create the group and set the avatar
    {Gid, _LocalHash, _IKMap} = create_group_with_identity_keys(?UID1, ?GROUP_NAME1, [?UID2, ?UID3]),
    meck:new(ejabberd_router, [passthrough]),
    meck:expect(ejabberd_router, route_multicast, fun (_, _, _) -> ok end),
    meck:expect(ejabberd_router, route, fun(_) -> ok end),

    SenderStateBundles = create_sender_state_bundles(
        [{?UID2, ?ENC_SENDER_STATE2}, {?UID3, ?ENC_SENDER_STATE3}]),
    HistoryResendSt = make_pb_history_resend(Gid, ?ID1, ?PAYLOAD1, SenderStateBundles, ?BAD_HASH),
    HistoryResendIq = make_history_resend_iq(?UID1, HistoryResendSt),
    ResultIQ = mod_group_feed:process_local_iq(HistoryResendIq),

    SubEl = ResultIQ#pb_iq.payload,
    ?assertEqual(error, ResultIQ#pb_iq.type),

    ?assertEqual(<<"audience_hash_mismatch">>, SubEl#pb_error_stanza.reason),
    ?assertEqual(0, meck:num_calls(ejabberd_router, route_multicast, '_')),
    ?assertEqual(0, meck:num_calls(ejabberd_router, route, '_')),
    ?assert(meck:validate(ejabberd_router)),
    meck:unload(ejabberd_router),
    ok.

history_resend_non_admin_test() ->
    setup(),
    % First create the group and set the avatar
    {Gid, AudienceHash, _IKMap} = create_group_with_identity_keys(?UID1, ?GROUP_NAME1, [?UID2, ?UID3]),
    meck:new(ejabberd_router, [passthrough]),
    meck:expect(ejabberd_router, route_multicast, fun (_, _, _) -> ok end),
    meck:expect(ejabberd_router, route, fun(_) -> ok end),

    SenderStateBundles = create_sender_state_bundles(
        [{?UID2, ?ENC_SENDER_STATE2}, {?UID3, ?ENC_SENDER_STATE3}]),
    HistoryResendSt = make_pb_history_resend(Gid, ?ID1, ?PAYLOAD1, SenderStateBundles, AudienceHash),
    HistoryResendIq = make_history_resend_iq(?UID2, HistoryResendSt),
    ResultIQ = mod_group_feed:process_local_iq(HistoryResendIq),

    SubEl = ResultIQ#pb_iq.payload,
    ?assertEqual(error, ResultIQ#pb_iq.type),

    ?assertEqual(<<"not_admin">>, SubEl#pb_error_stanza.reason),
    ?assertEqual(0, meck:num_calls(ejabberd_router, route_multicast, '_')),
    ?assertEqual(0, meck:num_calls(ejabberd_router, route, '_')),
    ?assert(meck:validate(ejabberd_router)),
    meck:unload(ejabberd_router),
    ok.

history_resend_with_audience_hash_test() ->
    history_resend_helper(true).

history_resend_without_audience_hash_test() ->
    history_resend_helper(false).

history_resend_helper(WithAudienceHash) ->
    setup(),
    % First create the group and set the avatar
    {Gid, AudienceHash, _} = create_group_with_identity_keys(?UID1, ?GROUP_NAME1, [?UID2, ?UID3]),
    meck:new(ejabberd_router, [passthrough]),

    meck:expect(ejabberd_router, route,
        fun(Packet) ->
            ?assertEqual(?UID1, Packet#pb_msg.from_uid),
            ?assert(Packet#pb_msg.to_uid =:= ?UID2 orelse Packet#pb_msg.to_uid =:= ?UID3),
            SubEl = Packet#pb_msg.payload,
            ?assertEqual(SubEl#pb_history_resend.payload, ?PAYLOAD1),
            ?assert(SubEl#pb_history_resend.sender_state =:= create_sender_state(?ENC_SENDER_STATE2) orelse
                SubEl#pb_history_resend.sender_state =:= create_sender_state(?ENC_SENDER_STATE3)),
            ok
        end),

    SenderStateBundles = create_sender_state_bundles(
        [{?UID2, ?ENC_SENDER_STATE2}, {?UID3, ?ENC_SENDER_STATE3}]),
    St = case WithAudienceHash of
        true -> make_pb_history_resend(Gid, ?ID1, ?PAYLOAD1, SenderStateBundles, AudienceHash);
        false -> make_pb_history_resend(Gid, ?ID1, ?PAYLOAD1, SenderStateBundles, <<>>)
    end,
    Iq = make_history_resend_iq(?UID1, St),
    ResultIQ = mod_group_feed:process_local_iq(Iq),

    SubEl = ResultIQ#pb_iq.payload,
    ?assertEqual(result, ResultIQ#pb_iq.type),

    ?assertEqual(Gid, SubEl#pb_history_resend.gid),
    ?assertEqual(SubEl#pb_history_resend.payload, ?PAYLOAD1),
    ?assertEqual(2, meck:num_calls(ejabberd_router, route, '_')),
    ?assert(meck:validate(ejabberd_router)),
    meck:unload(ejabberd_router),
    ok.


add_member_with_history_bad_audience_hash_test() ->
    setup(),
    % First create the group and set the avatar
    {Gid, _LocalHash, _IKMap} = create_group_with_identity_keys(?UID1, ?GROUP_NAME1, [?UID2]),
    meck:new(ejabberd_router, [passthrough]),
    meck:expect(ejabberd_router, route_multicast, fun (_, _, _) -> ok end),
    meck:expect(ejabberd_router, route, fun(_) -> ok end),

    SenderStateBundles = create_sender_state_bundles(
        [{?UID2, ?ENC_SENDER_STATE2}, {?UID3, ?ENC_SENDER_STATE3}]),
    PBHistoryResend = make_pb_history_resend(Gid, ?ID1, ?PAYLOAD1, SenderStateBundles, ?BAD_HASH),
    IQ = modify_members_IQ(?UID1, Gid, [{?UID3, add}], PBHistoryResend),
    ResultIQ = mod_groups_api:process_local_iq(IQ),

    SubEl = ResultIQ#pb_iq.payload,
    ?assertEqual(error, ResultIQ#pb_iq.type),

    ?assertEqual(<<"audience_hash_mismatch">>, SubEl#pb_error_stanza.reason),
    ?assertEqual(0, meck:num_calls(ejabberd_router, route_multicast, '_')),
    ?assertEqual(0, meck:num_calls(ejabberd_router, route, '_')),
    ?assert(meck:validate(ejabberd_router)),
    meck:unload(ejabberd_router),
    ok.

add_member_with_history_non_admin_test() ->
    setup(),
    % First create the group and set the avatar
    {Gid, AudienceHash, _IKMap} = create_group_with_identity_keys(?UID1, ?GROUP_NAME1, [?UID2]),
    meck:new(ejabberd_router, [passthrough]),
    meck:expect(ejabberd_router, route_multicast, fun (_, _, _) -> ok end),
    meck:expect(ejabberd_router, route, fun(_) -> ok end),

    SenderStateBundles = create_sender_state_bundles(
        [{?UID1, ?ENC_SENDER_STATE2}, {?UID3, ?ENC_SENDER_STATE3}]),
    PBHistoryResend = make_pb_history_resend(Gid, ?ID1, ?PAYLOAD1, SenderStateBundles, AudienceHash),
    IQ = modify_members_IQ(?UID2, Gid, [{?UID3, add}], PBHistoryResend),
    ResultIQ = mod_groups_api:process_local_iq(IQ),

    SubEl = ResultIQ#pb_iq.payload,
    ?assertEqual(error, ResultIQ#pb_iq.type),

    ?assertEqual(<<"not_admin">>, SubEl#pb_error_stanza.reason),
    ?assertEqual(0, meck:num_calls(ejabberd_router, route_multicast, '_')),
    ?assertEqual(0, meck:num_calls(ejabberd_router, route, '_')),
    ?assert(meck:validate(ejabberd_router)),
    meck:unload(ejabberd_router),
    ok.


add_member_with_history_resend_test() ->
    setup(),
    % First create the group and set the avatar
    {Gid, AudienceHash, _} = create_group_with_identity_keys(?UID1, ?GROUP_NAME1, [?UID2]),
    meck:new(ejabberd_router, [passthrough]),

    meck:expect(ejabberd_router, route,
        %% Ignore new group-info updates.
        fun(#pb_msg{payload = #pb_group_stanza{history_resend = undefined}}) -> ok;
           (Packet) ->
            ?assertEqual(?UID1, Packet#pb_msg.from_uid),
            ?assert(Packet#pb_msg.to_uid =:= ?UID1 orelse
                Packet#pb_msg.to_uid =:= ?UID2 orelse
                Packet#pb_msg.to_uid =:= ?UID3),
            SubEl = Packet#pb_msg.payload,
            ?assertEqual(SubEl#pb_group_stanza.history_resend#pb_history_resend.payload, ?PAYLOAD1),
            HistoryResend = SubEl#pb_group_stanza.history_resend,
            ?assert(HistoryResend#pb_history_resend.sender_state =:= undefined orelse
                HistoryResend#pb_history_resend.sender_state =:= create_sender_state(?ENC_SENDER_STATE2) orelse
                HistoryResend#pb_history_resend.sender_state =:= create_sender_state(?ENC_SENDER_STATE3)),
            ok
        end),

    SenderStateBundles = create_sender_state_bundles(
        [{?UID2, ?ENC_SENDER_STATE2}, {?UID3, ?ENC_SENDER_STATE3}]),
    PBHistoryResend = make_pb_history_resend(Gid, ?ID1, ?PAYLOAD1, SenderStateBundles, AudienceHash),
    IQ = modify_members_IQ(?UID1, Gid, [{?UID3, add}], PBHistoryResend),
    ResultIQ = mod_groups_api:process_local_iq(IQ),

    ?assertEqual(result, ResultIQ#pb_iq.type),
    ?assertEqual(4, meck:num_calls(ejabberd_router, route, '_')),
    ?assert(meck:validate(ejabberd_router)),
    meck:unload(ejabberd_router),
    ok.


retract_group_feed_test() ->
    setup(),

    % First create the group and set the avatar
    Gid = create_group(?UID1, ?GROUP_NAME1, [?UID2, ?UID3]),

    Timestamp = util:now_ms(),
    ok = model_feed:publish_post(?ID2, ?UID1, <<>>, empty, all, [?UID1, ?UID2, ?UID3], Timestamp, Gid),
    ok = model_feed:publish_comment(?ID1, ?ID2, ?UID2, <<>>, <<>>, Timestamp),
    meck:new(ejabberd_router, [passthrough]),

    meck:expect(ejabberd_router, route,
        fun(Packet) ->
            ?assertEqual(?UID2, Packet#pb_msg.from_uid),
            ?assert(Packet#pb_msg.to_uid =:= ?UID1 orelse Packet#pb_msg.to_uid =:= ?UID3),
            SubEl = Packet#pb_msg.payload,
            ?assertEqual(?GROUP_NAME1, SubEl#pb_group_feed_item.name),
            ?assertEqual(undefined, SubEl#pb_group_feed_item.avatar_id),
            Comment = SubEl#pb_group_feed_item.item,
            ?assertEqual(?UID2, Comment#pb_comment.publisher_uid),
            ?assertNotEqual(undefined, Comment#pb_comment.timestamp),
            ?assertEqual(SubEl#pb_group_feed_item.sender_state, undefined),
            ok
        end),

    CommentSt = make_pb_comment(?ID1, ?ID2, <<>>, <<>>, <<>>, <<>>, undefined),
    SenderStateBundles = create_sender_state_bundles([]),
    GroupFeedSt = make_pb_group_feed_item(Gid, <<>>, undefined, retract, CommentSt, SenderStateBundles, <<>>),
    GroupFeedIq = make_group_feed_iq(?UID2, GroupFeedSt),
    ResultIQ = mod_group_feed:process_local_iq(GroupFeedIq),

    SubEl = ResultIQ#pb_iq.payload,
    ?assertEqual(result, ResultIQ#pb_iq.type),
    ?assertEqual(Gid, SubEl#pb_group_feed_item.gid),
    GroupCommentSt = SubEl#pb_group_feed_item.item,
    ?assertEqual(?UID2, GroupCommentSt#pb_comment.publisher_uid),
    ?assertNotEqual(undefined, GroupCommentSt#pb_comment.timestamp),
    ?assertEqual(2, meck:num_calls(ejabberd_router, route, '_')),
    ?assert(meck:validate(ejabberd_router)),
    meck:unload(ejabberd_router),

    ?assertEqual({error, missing}, model_feed:get_comment(?ID1, ?ID2)),
    ok.

%% TODO(murali@): add more unit tests here.

