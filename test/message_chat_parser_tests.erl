%%%-------------------------------------------------------------------
%%% @author yexin
%%% @copyright (C) 2020, HalloApp, Inc.
%%% @doc
%%%
%%% @end
%%% Created : 21. Jul 2020 1:00 PM
%%%-------------------------------------------------------------------
-module(message_chat_parser_tests).
-author("yexin").

-include_lib("eunit/include/eunit.hrl").
-include("packets.hrl").
-include("xmpp.hrl").
-include("parser_test_data.hrl").

%% -------------------------------------------- %%
%% internal tests
%% -------------------------------------------- %%

setup() ->
    stringprep:start(),
    ok.

xmpp_to_proto_chat1_test() ->
    setup(),

    S1 = struct_util:create_s1_xmlel(?PAYLOAD1_BASE64),
    Enc = struct_util:create_enc_xmlel(?PAYLOAD2_BASE64, ?PAYLOAD1_BASE64, <<"12">>),
    ChatSt = struct_util:create_chat_stanza(?TIMESTAMP1, ?NAME1, [S1, Enc]),
    ToJid = struct_util:create_jid(?UID1, ?SERVER),
    FromJid = struct_util:create_jid(?UID2, ?SERVER),
    XmppMsg = struct_util:create_message_stanza(?ID1, ToJid, FromJid, normal, ChatSt),

    PbChat = struct_util:create_pb_chat_stanza(?TIMESTAMP1_INT, ?NAME1, ?PAYLOAD1, ?PAYLOAD2, ?PAYLOAD1, 12),
    PbMsg = struct_util:create_pb_message(?ID1, ?UID1_INT, ?UID2_INT, normal, PbChat),

    ActualProtoMsg = message_parser:xmpp_to_proto(XmppMsg),
    ?assertEqual(true, is_record(ActualProtoMsg, pb_msg)),
    ?assertEqual(PbMsg, ActualProtoMsg),

    SilentChatSt = struct_util:create_silent_chat(ChatSt),
    XmppSilentMsg = struct_util:create_message_stanza(?ID1, ToJid, FromJid, normal, SilentChatSt),
    PbSilentChat = struct_util:create_pb_silent_chat_stanza(PbChat),
    PbSilentMsg = struct_util:create_pb_message(?ID1, ?UID1_INT, ?UID2_INT, normal, PbSilentChat),
    ActualProtoSilentMsg = message_parser:xmpp_to_proto(XmppSilentMsg),
    ?assertEqual(true, is_record(ActualProtoSilentMsg, pb_msg)),
    ?assertEqual(PbSilentMsg, ActualProtoSilentMsg),
    ok.


xmpp_to_proto_chat2_test() ->
    setup(),

    S1 = struct_util:create_s1_xmlel(?PAYLOAD1_BASE64),
    Enc = struct_util:create_enc_xmlel(?PAYLOAD2_BASE64, undefined, undefined),
    ChatSt = struct_util:create_chat_stanza(?TIMESTAMP1, ?NAME1, [S1, Enc]),
    ToJid = struct_util:create_jid(?UID1, ?SERVER),
    FromJid = struct_util:create_jid(?UID2, ?SERVER),
    XmppMsg = struct_util:create_message_stanza(?ID1, ToJid, FromJid, normal, ChatSt),

    PbChat = struct_util:create_pb_chat_stanza(?TIMESTAMP1_INT, ?NAME1, ?PAYLOAD1, ?PAYLOAD2, undefined, undefined),
    PbMsg = struct_util:create_pb_message(?ID1, ?UID1_INT, ?UID2_INT, normal, PbChat),

    ActualProtoMsg = message_parser:xmpp_to_proto(XmppMsg),
    ?assertEqual(true, is_record(ActualProtoMsg, pb_msg)),
    ?assertEqual(PbMsg, ActualProtoMsg),

    SilentChatSt = struct_util:create_silent_chat(ChatSt),
    XmppSilentMsg = struct_util:create_message_stanza(?ID1, ToJid, FromJid, normal, SilentChatSt),
    PbSilentChat = struct_util:create_pb_silent_chat_stanza(PbChat),
    PbSilentMsg = struct_util:create_pb_message(?ID1, ?UID1_INT, ?UID2_INT, normal, PbSilentChat),
    ActualProtoSilentMsg = message_parser:xmpp_to_proto(XmppSilentMsg),
    ?assertEqual(true, is_record(ActualProtoSilentMsg, pb_msg)),
    ?assertEqual(PbSilentMsg, ActualProtoSilentMsg),
    ok.


proto_to_xmpp_chat1_test() ->
    setup(),

    S1 = struct_util:create_s1_xmlel(?PAYLOAD1_BASE64),
    Enc = struct_util:create_enc_xmlel(?PAYLOAD2_BASE64, ?PAYLOAD1_BASE64, <<"12">>),
    ChatSt = struct_util:create_chat_stanza(?TIMESTAMP1, ?NAME1, [S1, Enc]),
    ToJid = struct_util:create_jid(?UID1, ?SERVER),
    FromJid = struct_util:create_jid(?UID2, ?SERVER),
    XmppMsg = struct_util:create_message_stanza(?ID1, ToJid, FromJid, normal, ChatSt),

    PbChat = struct_util:create_pb_chat_stanza(?TIMESTAMP1_INT, ?NAME1, ?PAYLOAD1, ?PAYLOAD2, ?PAYLOAD1, 12),
    PbMsg = struct_util:create_pb_message(?ID1, ?UID1_INT, ?UID2_INT, normal, PbChat),

    ActualXmppMsg = message_parser:proto_to_xmpp(PbMsg),
    ?assertEqual(true, is_record(ActualXmppMsg, message)),
    ?assertEqual(XmppMsg, ActualXmppMsg),

    SilentChatSt = struct_util:create_silent_chat(ChatSt),
    XmppSilentMsg = struct_util:create_message_stanza(?ID1, ToJid, FromJid, normal, SilentChatSt),
    PbSilentChat = struct_util:create_pb_silent_chat_stanza(PbChat),
    PbSilentMsg = struct_util:create_pb_message(?ID1, ?UID1_INT, ?UID2_INT, normal, PbSilentChat),
    ActualXmppSilentMsg = message_parser:proto_to_xmpp(PbSilentMsg),
    ?assertEqual(true, is_record(ActualXmppSilentMsg, message)),
    ?assertEqual(XmppSilentMsg, ActualXmppSilentMsg),
    ok.


proto_to_xmpp_chat2_test() ->
    setup(),

    S1 = struct_util:create_s1_xmlel(?PAYLOAD1_BASE64),
    Enc = struct_util:create_enc_xmlel(?PAYLOAD2_BASE64, ?PAYLOAD1_BASE64, <<"12">>),
    ChatSt = struct_util:create_chat_stanza(undefined, ?NAME1, [S1, Enc]),
    ToJid = struct_util:create_jid(?UID1, ?SERVER),
    FromJid = struct_util:create_jid(?UID2, ?SERVER),
    XmppMsg = struct_util:create_message_stanza(?ID1, ToJid, FromJid, normal, ChatSt),

    PbChat = struct_util:create_pb_chat_stanza(undefined, ?NAME1, ?PAYLOAD1, ?PAYLOAD2, ?PAYLOAD1, 12),
    PbMsg = struct_util:create_pb_message(?ID1, ?UID1_INT, ?UID2_INT, normal, PbChat),

    ActualXmppMsg = message_parser:proto_to_xmpp(PbMsg),
    ?assertEqual(true, is_record(ActualXmppMsg, message)),
    ?assertEqual(XmppMsg, ActualXmppMsg),

    SilentChatSt = struct_util:create_silent_chat(ChatSt),
    XmppSilentMsg = struct_util:create_message_stanza(?ID1, ToJid, FromJid, normal, SilentChatSt),
    PbSilentChat = struct_util:create_pb_silent_chat_stanza(PbChat),
    PbSilentMsg = struct_util:create_pb_message(?ID1, ?UID1_INT, ?UID2_INT, normal, PbSilentChat),
    ActualXmppSilentMsg = message_parser:proto_to_xmpp(PbSilentMsg),
    ?assertEqual(true, is_record(ActualXmppSilentMsg, message)),
    ?assertEqual(XmppSilentMsg, ActualXmppSilentMsg),
    ok.

