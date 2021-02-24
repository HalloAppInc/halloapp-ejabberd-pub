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

