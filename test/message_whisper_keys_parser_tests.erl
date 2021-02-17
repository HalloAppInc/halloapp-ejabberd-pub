%%%-------------------------------------------------------------------
%%% @author yexin
%%% @copyright (C) 2020, HalloApp, Inc.
%%% @doc
%%%
%%% @end
%%% Created : 20. Jul 2020 10:30 PM
%%%-------------------------------------------------------------------
-module(message_whisper_keys_parser_tests).
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


xmpp_to_proto_whisper_keys_test() ->
    setup(),
    WhisperKeys = struct_util:create_whisper_keys(?UID1, add, ?KEY1_BASE64, ?KEY2_BASE64, <<"5">>, [?KEY3_BASE64, ?KEY4_BASE64]),
    ToJid = struct_util:create_jid(?UID1, ?SERVER),
    FromJid = struct_util:create_jid(?UID2, ?SERVER),
    XmppMsg = struct_util:create_message_stanza(?ID1, ToJid, FromJid, normal, WhisperKeys),

    PbWhisperKeys = struct_util:create_pb_whisper_keys(?UID1, add, ?KEY1, ?KEY2, 5, [?KEY3, ?KEY4]),
    PbMsg = struct_util:create_pb_message(?ID1, ?UID1, ?UID2, normal, PbWhisperKeys),

    ProtoMsg = message_parser:xmpp_to_proto(XmppMsg),
    ?assertEqual(true, is_record(ProtoMsg, pb_msg)),
    ?assertEqual(PbMsg, ProtoMsg).


xmpp_to_proto_rerequest_test() ->
    setup(),
    RerequestSt = struct_util:create_rerequest_st(?ID1, ?KEY1_BASE64),
    ToJid = struct_util:create_jid(?UID1, ?SERVER),
    FromJid = struct_util:create_jid(?UID2, ?SERVER),
    XmppMsg = struct_util:create_message_stanza(?ID1, ToJid, FromJid, normal, RerequestSt),

    PbRerequest = struct_util:create_pb_rerequest(?ID1, ?KEY1),
    PbMsg = struct_util:create_pb_message(?ID1, ?UID1, ?UID2, normal, PbRerequest),

    ProtoMsg = message_parser:xmpp_to_proto(XmppMsg),
    ?assertEqual(true, is_record(ProtoMsg, pb_msg)),
    ?assertEqual(PbMsg, ProtoMsg).


proto_to_xmpp_rerequest_test() ->
    setup(),
    RerequestSt = struct_util:create_rerequest_st(?ID1, ?KEY1_BASE64),
    ToJid = struct_util:create_jid(?UID1, ?SERVER),
    FromJid = struct_util:create_jid(?UID2, ?SERVER),
    XmppMsg = struct_util:create_message_stanza(?ID1, ToJid, FromJid, normal, RerequestSt),

    PbRerequest = struct_util:create_pb_rerequest(?ID1, ?KEY1),
    PbMsg = struct_util:create_pb_message(?ID1, ?UID1, ?UID2, normal, PbRerequest),

    ActualXmppMsg = message_parser:proto_to_xmpp(PbMsg),
    ?assertEqual(true, is_record(ActualXmppMsg, message)),
    ?assertEqual(XmppMsg, ActualXmppMsg).

