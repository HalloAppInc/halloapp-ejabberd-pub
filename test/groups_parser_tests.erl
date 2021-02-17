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
-include("parser_test_data.hrl").

setup() ->
    stringprep:start(),
    ok.

%% -------------------------------------------- %%
%% internal tests
%% -------------------------------------------- %%


xmpp_to_proto_iq_group_result_test() ->
    setup(),

    Member = struct_util:create_pb_member(add, ?UID2, member, ?NAME2, ?AVATAR_ID2, <<"ok">>, undefined),
    Group = struct_util:create_pb_group_stanza(modify_members, ?GID1, ?G_NAME1, ?G_AVATAR_ID1, ?UID1, ?NAME1, [Member]),
    ToJid = jid:make(?UID1, ?SERVER),
    FromJid = jid:make(?SERVER),
    XmppIq = struct_util:create_iq_stanza(?ID1, ToJid, FromJid, result, Group),

    PbMember = struct_util:create_pb_member(add, ?UID2, member, ?NAME2, ?AVATAR_ID2, <<"ok">>, undefined),
    PbGroup = struct_util:create_pb_group_stanza(modify_members, ?GID1, ?G_NAME1, ?G_AVATAR_ID1, ?UID1, ?NAME1, [PbMember]),
    ExpectedProtoIq = struct_util:create_pb_iq(?ID1, result, PbGroup),

    ActualProtoIq = iq_parser:xmpp_to_proto(XmppIq),
    ?assertEqual(true, is_record(ActualProtoIq, pb_iq)),
    ?assertEqual(ExpectedProtoIq, ActualProtoIq).


xmpp_to_proto_message_group_test() ->
    setup(),

    MemberSt1 = struct_util:create_member_st(demote, ?UID2, admin, ?NAME2, ?AVATAR_ID2, undefined, undefined),
    MemberSt2 = struct_util:create_member_st(demote, ?UID3, admin, ?NAME3, ?AVATAR_ID3, undefined, undefined),
    GroupSt = struct_util:create_group_st(modify_admins, ?GID1, ?G_NAME1, ?G_AVATAR_ID1, ?UID1, ?NAME1, [MemberSt1, MemberSt2]),
    ToJid = jid:make(?UID1, ?SERVER),
    FromJid = jid:make(?SERVER),
    XmppMsg = struct_util:create_message_stanza(?ID1, ToJid, FromJid, normal, GroupSt),

    PbMember1 = struct_util:create_pb_member(demote, ?UID2, admin, ?NAME2, ?AVATAR_ID2, undefined, undefined),
    PbMember2 = struct_util:create_pb_member(demote, ?UID3, admin, ?NAME3, ?AVATAR_ID3, undefined, undefined),
    PbGroup = struct_util:create_pb_group_stanza(modify_admins, ?GID1, ?G_NAME1, ?G_AVATAR_ID1, ?UID1, ?NAME1, [PbMember1, PbMember2]),
    ExpectedProtoMsg = struct_util:create_pb_message(?ID1, ?UID1, <<>>, normal, PbGroup),

    ActualProtoMsg = message_parser:xmpp_to_proto(XmppMsg),

    ?assertEqual(true, is_record(ActualProtoMsg, pb_msg)),
    ?assertEqual(ExpectedProtoMsg, ActualProtoMsg).


xmpp_to_proto_group_chat_test() ->
    setup(),

    GroupChatSt = struct_util:create_group_chat(?GID1, ?G_NAME1, ?G_AVATAR_ID1, ?UID2, ?NAME2, ?TIMESTAMP1, ?PAYLOAD1_BASE64),
    ToJid = jid:make(?UID1, ?SERVER),
    FromJid = jid:make(?SERVER),
    XmppMsg = struct_util:create_message_stanza(?ID1, ToJid, FromJid, groupchat, GroupChatSt),

    PbGroupChat = struct_util:create_pb_group_chat(?GID1, ?G_NAME1, ?G_AVATAR_ID1, ?UID2, ?NAME2, ?TIMESTAMP1_INT, ?PAYLOAD1),
    ExpectedProtoMsg = struct_util:create_pb_message(?ID1, ?UID1, <<>>, groupchat, PbGroupChat),

    ActualProtoMsg = message_parser:xmpp_to_proto(XmppMsg),
    ?assertEqual(true, is_record(ActualProtoMsg, pb_msg)),
    ?assertEqual(ExpectedProtoMsg, ActualProtoMsg).


proto_to_xmpp_group_chat_test() ->
    setup(),

    GroupChatSt = struct_util:create_group_chat(?GID1, ?G_NAME1, ?G_AVATAR_ID1, ?UID2, ?NAME2, ?TIMESTAMP1, ?PAYLOAD1_BASE64),
    ToJid = jid:make(?SERVER),
    FromJid = jid:make(?UID1, ?SERVER),
    ExpectedXmppMsg = struct_util:create_message_stanza(?ID1, ToJid, FromJid, normal, GroupChatSt),

    PbGroupChat = struct_util:create_pb_group_chat(?GID1, ?G_NAME1, ?G_AVATAR_ID1, ?UID2, ?NAME2, ?TIMESTAMP1_INT, ?PAYLOAD1),
    ProtoMsg = struct_util:create_pb_message(?ID1, <<>>, ?UID1, normal, PbGroupChat),

    ActualXmppMsg = message_parser:proto_to_xmpp(ProtoMsg),
    ?assertEqual(true, is_record(ExpectedXmppMsg, message)),
    ?assertEqual(ExpectedXmppMsg, ActualXmppMsg).


proto_to_xmpp_iq_group_test() ->
    setup(),

    Member = struct_util:create_pb_member(promote, ?UID2, admin, ?NAME2, ?AVATAR_ID2, <<>>, <<>>),
    Group = struct_util:create_pb_group_stanza(modify_admins, ?GID1, ?G_NAME1, ?G_AVATAR_ID1, ?UID1, ?NAME1, [Member]),
    ExpectedXmppIq = struct_util:create_iq_stanza(?ID1, undefined, undefined, set, Group),

    PbMember = struct_util:create_pb_member(promote, ?UID2, admin, ?NAME2, ?AVATAR_ID2, <<>>, <<>>),
    PbGroup = struct_util:create_pb_group_stanza(modify_admins, ?GID1, ?G_NAME1, ?G_AVATAR_ID1, ?UID1, ?NAME1, [PbMember]),
    ProtoIq = struct_util:create_pb_iq(?ID1, set, PbGroup),

    ActualXmppIq = iq_parser:proto_to_xmpp(ProtoIq),
    ?assertEqual(true, is_record(ActualXmppIq, iq)),
    ?assertEqual(ExpectedXmppIq, ActualXmppIq).


proto_to_xmpp_groups_test() ->
    setup(),

    Groups = struct_util:create_pb_groups_stanza(get, []),
    ExpectedXmppIq = struct_util:create_iq_stanza(?ID1, undefined, undefined, get, Groups),

    PbGroupsStanza = struct_util:create_pb_groups_stanza(get, []),
    ProtoIq = struct_util:create_pb_iq(?ID1, get, PbGroupsStanza),

    ActualXmppIq = iq_parser:proto_to_xmpp(ProtoIq),
    ?assertEqual(true, is_record(ActualXmppIq, iq)),
    ?assertEqual(ExpectedXmppIq, ActualXmppIq).


xmpp_to_proto_iq_groups_test() ->
    setup(),

    Group = struct_util:create_pb_group_stanza(undefined, ?GID1, ?G_NAME1, ?G_AVATAR_ID1, undefined, undefined, []),
    Groups = struct_util:create_pb_groups_stanza(get, [Group]),
    XmppIq = struct_util:create_iq_stanza(?ID1, undefined, undefined, result, Groups),

    PbGroup = struct_util:create_pb_group_stanza(undefined, ?GID1, ?G_NAME1, ?G_AVATAR_ID1, undefined, undefined, []),
    PbGroupsStanza = struct_util:create_pb_groups_stanza(get, [PbGroup]),
    ExpectedProtoIq = struct_util:create_pb_iq(?ID1, result, PbGroupsStanza),

    ActualProtoIq = iq_parser:xmpp_to_proto(XmppIq),
    ?assertEqual(true, is_record(ActualProtoIq, pb_iq)),
    ?assertEqual(ExpectedProtoIq, ActualProtoIq).


proto_to_xmpp_group_avatar_test() ->
    setup(),

    PbGroupAvatarStanza = struct_util:create_pb_upload_group_avatar(?GID1, ?PAYLOAD1),
    ProtoIq = struct_util:create_pb_iq(?ID1, set, PbGroupAvatarStanza),
    ExpectedXmppIq = struct_util:create_iq_stanza(?ID1, undefined, undefined, set, PbGroupAvatarStanza),

    ActualXmppIq = iq_parser:proto_to_xmpp(ProtoIq),
    ?assertEqual(true, is_record(ActualXmppIq, iq)),
    ?assertEqual(ExpectedXmppIq, ActualXmppIq).

