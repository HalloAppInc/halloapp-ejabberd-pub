%%%-------------------------------------------------------------------
%%% File: groups_parser_tests.erl
%%% Copyright (C) 2020, Halloapp Inc.
%%%
%%%-------------------------------------------------------------------
-module(groups_parser_tests).
-author('murali').

-include_lib("eunit/include/eunit.hrl").
-include("packets.hrl").
-include("xmpp.hrl").

%% -------------------------------------------- %%
%% define chat constants
%% -------------------------------------------- %%

-define(UID1, <<"1000000000045484920">>).
-define(UID1_INT, 1000000000045484920).
-define(NAME1, <<"name1">>).
-define(AVATAR_ID1, <<"avatarid1">>).

-define(UID2, <<"1000000000519345762">>).
-define(UID2_INT, 1000000000519345762).
-define(NAME2, <<"name2">>).
-define(AVATAR_ID2, <<"avatarid2">>).

-define(UID3, <<"1000000000321423233">>).
-define(UID3_INT, 1000000000321423233).
-define(NAME3, <<"name3">>).
-define(AVATAR_ID3, <<"avatarid3">>).

-define(ID1, <<"id1">>).
-define(ID2, <<"id2">>).
-define(ID3, <<"id3">>).

-define(GID1, <<"gid1">>).
-define(GID2, <<"gid2">>).
-define(G_AVATAR_ID1, <<"g_avatar_id1">>).
-define(G_AVATAR_ID2, <<"g_avatar_id2">>).
-define(G_NAME1, <<"g_name1">>).
-define(G_NAME2, <<"g_name2">>).

-define(PAYLOAD1, <<"payload1">>).
-define(PAYLOAD2, <<"payload2">>).
-define(TIMESTAMP1, <<"2000090910">>).
-define(TIMESTAMP1_INT, 2000090910).
-define(TIMESTAMP2, <<"1850012340">>).
-define(TIMESTAMP2_INT, 1850012340).
-define(SERVER, <<"s.halloapp.net">>).


create_member_st(Action, Uid, Type, Name, AvatarId, Result, Reason) ->
    #member_st{
        action = Action,
        uid = Uid,
        type = Type,
        name = Name,
        avatar = AvatarId,
        result = Result,
        reason = Reason
    }.


create_pb_member(Action, Uid, Type, Name, AvatarId, Result, Reason) ->
    #pb_group_member{
        action = Action,
        uid = Uid,
        type = Type,
        name = Name,
        avatar_id = AvatarId,
        result = Result,
        reason = Reason
    }.


create_group_st(Action, Gid, Name, AvatarId, SenderUid, SenderName, Members) ->
    #group_st{
        action = Action,
        gid = Gid,
        name = Name,
        avatar = AvatarId,
        sender = SenderUid,
        sender_name = SenderName,
        members = Members
    }.


create_pb_group_stanza(Action, Gid, Name, AvatarId, SenderUid, SenderName, PbMembers) ->
    #pb_group_stanza{
        action = Action,
        gid = Gid,
        name = Name,
        avatar_id = AvatarId,
        sender_uid = SenderUid,
        sender_name = SenderName,
        members = PbMembers
    }.


create_message_stanza(Id, ToJid, FromJid, Type, SubEl) ->
    #message{
        id = Id,
        to = ToJid,
        from = FromJid,
        type = Type,
        sub_els = [SubEl]
    }.


create_pb_message(Id, ToUid, FromUid, Type, PayloadContent) ->
    #pb_ha_message{
        id = Id,
        to_uid = ToUid,
        from_uid = FromUid,
        type = Type,
        payload = #pb_msg_payload{
                content = PayloadContent
            }
    }.


create_iq_stanza(Id, ToJid, FromJid, Type, SubEl) ->
    #iq{
        id = Id,
        to = ToJid,
        from = FromJid,
        type = Type,
        sub_els = [SubEl]
    }.


create_pb_iq(Id, Type, PayloadContent) ->
    #pb_ha_iq{
        id = Id,
        type = Type,
        payload = #pb_iq_payload{
                content = PayloadContent
            }
    }.


create_group_chat(Gid, Name, AvatarId, SenderUid, SenderName, Timestamp, Payload) ->
    #group_chat{
        gid = Gid,
        name = Name,
        avatar = AvatarId,
        sender = SenderUid,
        sender_name = SenderName,
        timestamp = Timestamp,
        sub_els = [{xmlel,<<"s1">>,[],[{xmlcdata, Payload}]}]
    }.


create_pb_group_chat(Gid, Name, AvatarId, SenderUid, SenderName, Timestamp, Payload) ->
    #pb_group_chat{
        gid = Gid,
        name = Name,
        avatar_id = AvatarId,
        sender_uid = SenderUid,
        sender_name = SenderName,
        timestamp = Timestamp,
        payload = Payload
    }.


create_groups_st(Action, Groups) ->
    #groups{
        action = Action,
        groups = Groups
    }.


create_pb_groups_stanza(Action, GroupsStanza) ->
    #pb_groups_stanza{
        action = Action,
        group_stanzas = GroupsStanza
    }.


setup() ->
    stringprep:start(),
    ok.

%% -------------------------------------------- %%
%% internal tests
%% -------------------------------------------- %%


xmpp_to_proto_iq_group_result_test() ->
    setup(),

    MemberSt = create_member_st(add, ?UID2, member, ?NAME2, ?AVATAR_ID2, ok, undefined),
    GroupSt = create_group_st(modify_members, ?GID1, ?G_NAME1, ?G_AVATAR_ID1, ?UID1, ?NAME1, [MemberSt]),
    ToJid = jid:make(?UID1, ?SERVER),
    FromJid = jid:make(?SERVER),
    XmppIq = create_iq_stanza(?ID1, ToJid, FromJid, result, GroupSt),

    PbMember = create_pb_member(add, ?UID2_INT, member, ?NAME2, ?AVATAR_ID2, <<"ok">>, undefined),
    PbGroup = create_pb_group_stanza(modify_members, ?GID1, ?G_NAME1, ?G_AVATAR_ID1, ?UID1_INT, ?NAME1, [PbMember]),
    ExpectedProtoIq = create_pb_iq(?ID1, result, {group_stanza, PbGroup}),

    ActualProtoIq = iq_parser:xmpp_to_proto(XmppIq),
    ?assertEqual(true, is_record(ActualProtoIq, pb_ha_iq)),
    ?assertEqual(ExpectedProtoIq, ActualProtoIq).


xmpp_to_proto_message_group_test() ->
    setup(),

    MemberSt1 = create_member_st(demote, ?UID2, admin, ?NAME2, ?AVATAR_ID2, undefined, undefined),
    MemberSt2 = create_member_st(demote, ?UID3, admin, ?NAME3, ?AVATAR_ID3, undefined, undefined),
    GroupSt = create_group_st(modify_admins, ?GID1, ?G_NAME1, ?G_AVATAR_ID1, ?UID1, ?NAME1, [MemberSt1, MemberSt2]),
    ToJid = jid:make(?UID1, ?SERVER),
    FromJid = jid:make(?SERVER),
    XmppMsg = create_message_stanza(?ID1, ToJid, FromJid, normal, GroupSt),

    PbMember1 = create_pb_member(demote, ?UID2_INT, admin, ?NAME2, ?AVATAR_ID2, undefined, undefined),
    PbMember2 = create_pb_member(demote, ?UID3_INT, admin, ?NAME3, ?AVATAR_ID3, undefined, undefined),
    PbGroup = create_pb_group_stanza(modify_admins, ?GID1, ?G_NAME1, ?G_AVATAR_ID1, ?UID1_INT, ?NAME1, [PbMember1, PbMember2]),
    ExpectedProtoMsg = create_pb_message(?ID1, ?UID1_INT, 0, normal, {group_stanza, PbGroup}),

    ActualProtoMsg = message_parser:xmpp_to_proto(XmppMsg),

    ?assertEqual(true, is_record(ActualProtoMsg, pb_ha_message)),
    ?assertEqual(ExpectedProtoMsg, ActualProtoMsg).


xmpp_to_proto_group_chat_test() ->
    setup(),

    GroupChatSt = create_group_chat(?GID1, ?G_NAME1, ?G_AVATAR_ID1, ?UID2, ?NAME2, ?TIMESTAMP1, ?PAYLOAD1),
    ToJid = jid:make(?UID1, ?SERVER),
    FromJid = jid:make(?SERVER),
    XmppMsg = create_message_stanza(?ID1, ToJid, FromJid, groupchat, GroupChatSt),

    PbGroupChat = create_pb_group_chat(?GID1, ?G_NAME1, ?G_AVATAR_ID1, ?UID2_INT, ?NAME2, ?TIMESTAMP1_INT, ?PAYLOAD1),
    ExpectedProtoMsg = create_pb_message(?ID1, ?UID1_INT, 0, groupchat, {group_chat, PbGroupChat}),

    ActualProtoMsg = message_parser:xmpp_to_proto(XmppMsg),
    ?assertEqual(true, is_record(ActualProtoMsg, pb_ha_message)),
    ?assertEqual(ExpectedProtoMsg, ActualProtoMsg).


proto_to_xmpp_group_chat_test() ->
    setup(),

    GroupChatSt = create_group_chat(?GID1, ?G_NAME1, ?G_AVATAR_ID1, ?UID2, ?NAME2, ?TIMESTAMP1, ?PAYLOAD1),
    ToJid = jid:make(?SERVER),
    FromJid = jid:make(?UID1, ?SERVER),
    ExpectedXmppMsg = create_message_stanza(?ID1, ToJid, FromJid, normal, GroupChatSt),

    PbGroupChat = create_pb_group_chat(?GID1, ?G_NAME1, ?G_AVATAR_ID1, ?UID2_INT, ?NAME2, ?TIMESTAMP1_INT, ?PAYLOAD1),
    ProtoMsg = create_pb_message(?ID1, 0, ?UID1_INT, normal, {group_chat, PbGroupChat}),

    ActualXmppMsg = message_parser:proto_to_xmpp(ProtoMsg),
    ?assertEqual(true, is_record(ExpectedXmppMsg, message)),
    ?assertEqual(ExpectedXmppMsg, ActualXmppMsg).


proto_to_xmpp_iq_group_test() ->
    setup(),

    MemberSt = create_member_st(promote, ?UID2, admin, ?NAME2, ?AVATAR_ID2, undefined, undefined),
    GroupSt = create_group_st(modify_admins, ?GID1, ?G_NAME1, ?G_AVATAR_ID1, ?UID1, ?NAME1, [MemberSt]),
    ExpectedXmppIq = create_iq_stanza(?ID1, undefined, undefined, set, GroupSt),

    PbMember = create_pb_member(promote, ?UID2_INT, admin, ?NAME2, ?AVATAR_ID2, <<>>, <<>>),
    PbGroup = create_pb_group_stanza(modify_admins, ?GID1, ?G_NAME1, ?G_AVATAR_ID1, ?UID1_INT, ?NAME1, [PbMember]),
    ProtoIq = create_pb_iq(?ID1, set, {group_stanza, PbGroup}),

    ActualXmppIq = iq_parser:proto_to_xmpp(ProtoIq),
    ?assertEqual(true, is_record(ActualXmppIq, iq)),
    ?assertEqual(ExpectedXmppIq, ActualXmppIq).


proto_to_xmpp_groups_test() ->
    setup(),

    GroupsSt = create_groups_st(get, []),
    ExpectedXmppIq = create_iq_stanza(?ID1, undefined, undefined, get, GroupsSt),

    PbGroupsStanza = create_pb_groups_stanza(get, []),
    ProtoIq = create_pb_iq(?ID1, get, {groups_stanza, PbGroupsStanza}),

    ActualXmppIq = iq_parser:proto_to_xmpp(ProtoIq),
    ?assertEqual(true, is_record(ActualXmppIq, iq)),
    ?assertEqual(ExpectedXmppIq, ActualXmppIq).


xmpp_to_proto_iq_groups_test() ->
    setup(),

    GroupSt = create_group_st(undefined, ?GID1, ?G_NAME1, ?G_AVATAR_ID1, undefined, undefined, []),
    GroupsSt = create_groups_st(get, [GroupSt]),
    XmppIq = create_iq_stanza(?ID1, undefined, undefined, result, GroupsSt),

    PbGroup = create_pb_group_stanza(undefined, ?GID1, ?G_NAME1, ?G_AVATAR_ID1, undefined, undefined, []),
    PbGroupsStanza = create_pb_groups_stanza(get, [PbGroup]),
    ExpectedProtoIq = create_pb_iq(?ID1, result, {groups_stanza, PbGroupsStanza}),

    ActualProtoIq = iq_parser:xmpp_to_proto(XmppIq),
    ?assertEqual(true, is_record(ActualProtoIq, pb_ha_iq)),
    ?assertEqual(ExpectedProtoIq, ActualProtoIq).

