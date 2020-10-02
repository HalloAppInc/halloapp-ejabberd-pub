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

-define(PAYLOAD1, <<"123">>).
-define(PAYLOAD2, <<"456">>).
-define(PAYLOAD1_BASE64, <<"MTIz">>).
-define(PAYLOAD2_BASE64, <<"NDU2">>).
-define(TIMESTAMP1, <<"2000090910">>).
-define(TIMESTAMP1_INT, 2000090910).
-define(TIMESTAMP2, <<"1850012340">>).
-define(TIMESTAMP2_INT, 1850012340).
-define(SERVER, <<"s.halloapp.net">>).


setup() ->
    stringprep:start(),
    ok.

%% -------------------------------------------- %%
%% internal tests
%% -------------------------------------------- %%


xmpp_to_proto_iq_group_result_test() ->
    setup(),

    MemberSt = struct_util:create_member_st(add, ?UID2, member, ?NAME2, ?AVATAR_ID2, ok, undefined),
    GroupSt = struct_util:create_group_st(modify_members, ?GID1, ?G_NAME1, ?G_AVATAR_ID1, ?UID1, ?NAME1, [MemberSt]),
    ToJid = jid:make(?UID1, ?SERVER),
    FromJid = jid:make(?SERVER),
    XmppIq = struct_util:create_iq_stanza(?ID1, ToJid, FromJid, result, GroupSt),

    PbMember = struct_util:create_pb_member(add, ?UID2_INT, member, ?NAME2, ?AVATAR_ID2, <<"ok">>, undefined),
    PbGroup = struct_util:create_pb_group_stanza(modify_members, ?GID1, ?G_NAME1, ?G_AVATAR_ID1, ?UID1_INT, ?NAME1, [PbMember]),
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

    PbMember1 = struct_util:create_pb_member(demote, ?UID2_INT, admin, ?NAME2, ?AVATAR_ID2, undefined, undefined),
    PbMember2 = struct_util:create_pb_member(demote, ?UID3_INT, admin, ?NAME3, ?AVATAR_ID3, undefined, undefined),
    PbGroup = struct_util:create_pb_group_stanza(modify_admins, ?GID1, ?G_NAME1, ?G_AVATAR_ID1, ?UID1_INT, ?NAME1, [PbMember1, PbMember2]),
    ExpectedProtoMsg = struct_util:create_pb_message(?ID1, ?UID1_INT, 0, normal, PbGroup),

    ActualProtoMsg = message_parser:xmpp_to_proto(XmppMsg),

    ?assertEqual(true, is_record(ActualProtoMsg, pb_msg)),
    ?assertEqual(ExpectedProtoMsg, ActualProtoMsg).


xmpp_to_proto_group_chat_test() ->
    setup(),

    GroupChatSt = struct_util:create_group_chat(?GID1, ?G_NAME1, ?G_AVATAR_ID1, ?UID2, ?NAME2, ?TIMESTAMP1, ?PAYLOAD1_BASE64),
    ToJid = jid:make(?UID1, ?SERVER),
    FromJid = jid:make(?SERVER),
    XmppMsg = struct_util:create_message_stanza(?ID1, ToJid, FromJid, groupchat, GroupChatSt),

    PbGroupChat = struct_util:create_pb_group_chat(?GID1, ?G_NAME1, ?G_AVATAR_ID1, ?UID2_INT, ?NAME2, ?TIMESTAMP1_INT, ?PAYLOAD1),
    ExpectedProtoMsg = struct_util:create_pb_message(?ID1, ?UID1_INT, 0, groupchat, PbGroupChat),

    ActualProtoMsg = message_parser:xmpp_to_proto(XmppMsg),
    ?assertEqual(true, is_record(ActualProtoMsg, pb_msg)),
    ?assertEqual(ExpectedProtoMsg, ActualProtoMsg).


proto_to_xmpp_group_chat_test() ->
    setup(),

    GroupChatSt = struct_util:create_group_chat(?GID1, ?G_NAME1, ?G_AVATAR_ID1, ?UID2, ?NAME2, ?TIMESTAMP1, ?PAYLOAD1_BASE64),
    ToJid = jid:make(?SERVER),
    FromJid = jid:make(?UID1, ?SERVER),
    ExpectedXmppMsg = struct_util:create_message_stanza(?ID1, ToJid, FromJid, normal, GroupChatSt),

    PbGroupChat = struct_util:create_pb_group_chat(?GID1, ?G_NAME1, ?G_AVATAR_ID1, ?UID2_INT, ?NAME2, ?TIMESTAMP1_INT, ?PAYLOAD1),
    ProtoMsg = struct_util:create_pb_message(?ID1, 0, ?UID1_INT, normal, PbGroupChat),

    ActualXmppMsg = message_parser:proto_to_xmpp(ProtoMsg),
    ?assertEqual(true, is_record(ExpectedXmppMsg, message)),
    ?assertEqual(ExpectedXmppMsg, ActualXmppMsg).


proto_to_xmpp_iq_group_test() ->
    setup(),

    MemberSt = struct_util:create_member_st(promote, ?UID2, admin, ?NAME2, ?AVATAR_ID2, undefined, undefined),
    GroupSt = struct_util:create_group_st(modify_admins, ?GID1, ?G_NAME1, ?G_AVATAR_ID1, ?UID1, ?NAME1, [MemberSt]),
    ExpectedXmppIq = struct_util:create_iq_stanza(?ID1, undefined, undefined, set, GroupSt),

    PbMember = struct_util:create_pb_member(promote, ?UID2_INT, admin, ?NAME2, ?AVATAR_ID2, <<>>, <<>>),
    PbGroup = struct_util:create_pb_group_stanza(modify_admins, ?GID1, ?G_NAME1, ?G_AVATAR_ID1, ?UID1_INT, ?NAME1, [PbMember]),
    ProtoIq = struct_util:create_pb_iq(?ID1, set, PbGroup),

    ActualXmppIq = iq_parser:proto_to_xmpp(ProtoIq),
    ?assertEqual(true, is_record(ActualXmppIq, iq)),
    ?assertEqual(ExpectedXmppIq, ActualXmppIq).


proto_to_xmpp_groups_test() ->
    setup(),

    GroupsSt = struct_util:create_groups_st(get, []),
    ExpectedXmppIq = struct_util:create_iq_stanza(?ID1, undefined, undefined, get, GroupsSt),

    PbGroupsStanza = struct_util:create_pb_groups_stanza(get, []),
    ProtoIq = struct_util:create_pb_iq(?ID1, get, PbGroupsStanza),

    ActualXmppIq = iq_parser:proto_to_xmpp(ProtoIq),
    ?assertEqual(true, is_record(ActualXmppIq, iq)),
    ?assertEqual(ExpectedXmppIq, ActualXmppIq).


xmpp_to_proto_iq_groups_test() ->
    setup(),

    GroupSt = struct_util:create_group_st(undefined, ?GID1, ?G_NAME1, ?G_AVATAR_ID1, undefined, undefined, []),
    GroupsSt = struct_util:create_groups_st(get, [GroupSt]),
    XmppIq = struct_util:create_iq_stanza(?ID1, undefined, undefined, result, GroupsSt),

    PbGroup = struct_util:create_pb_group_stanza(undefined, ?GID1, ?G_NAME1, ?G_AVATAR_ID1, undefined, undefined, []),
    PbGroupsStanza = struct_util:create_pb_groups_stanza(get, [PbGroup]),
    ExpectedProtoIq = struct_util:create_pb_iq(?ID1, result, PbGroupsStanza),

    ActualProtoIq = iq_parser:xmpp_to_proto(XmppIq),
    ?assertEqual(true, is_record(ActualProtoIq, pb_iq)),
    ?assertEqual(ExpectedProtoIq, ActualProtoIq).


proto_to_xmpp_group_avatar_test() ->
    setup(),

    GroupAvatarSt = struct_util:create_group_avatar(?GID1, ?PAYLOAD1_BASE64),
    ExpectedXmppIq = struct_util:create_iq_stanza(?ID1, undefined, undefined, set, GroupAvatarSt),

    PbGroupAvatarStanza = struct_util:create_pb_upload_group_avatar(?GID1, ?PAYLOAD1),
    ProtoIq = struct_util:create_pb_iq(?ID1, set, PbGroupAvatarStanza),

    ActualXmppIq = iq_parser:proto_to_xmpp(ProtoIq),
    ?assertEqual(true, is_record(ActualXmppIq, iq)),
    ?assertEqual(ExpectedXmppIq, ActualXmppIq).

