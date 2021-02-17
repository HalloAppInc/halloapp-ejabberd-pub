%%%-------------------------------------------------------------------
%%% @author yexin
%%% @copyright (C) 2020, HalloApp, Inc.
%%% @doc
%%%
%%% @end
%%% Created : 20. Jul 2020 11:00 AM
%%%-------------------------------------------------------------------
-module(message_receipts_parser_tests).
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


xmpp_to_proto_seen_test() ->
    setup(),

    SeenReceipt = struct_util:create_seen_receipt(?ID1, ?UID2, ?TIMESTAMP1),
    ToJid = struct_util:create_jid(?UID1, ?SERVER),
    FromJid = struct_util:create_jid(?UID2, ?SERVER),
    XmppMsg = struct_util:create_message_stanza(?ID1, ToJid, FromJid, normal, SeenReceipt),

    PbSeenReceipt = struct_util:create_pb_seen_receipt(?ID1, ?UID2, ?TIMESTAMP1_INT),
    PbMsg = struct_util:create_pb_message(?ID1, ?UID1, ?UID2, normal, PbSeenReceipt),

    ProtoMSG = message_parser:xmpp_to_proto(XmppMsg),
    ?assertEqual(true, is_record(ProtoMSG, pb_msg)),
    ?assertEqual(PbMsg, ProtoMSG).


proto_to_xmpp_seen_test() ->
    setup(),

    SeenReceipt = struct_util:create_seen_receipt(?ID1, ?UID2, ?TIMESTAMP1),
    ToJid = struct_util:create_jid(?UID1, ?SERVER),
    FromJid = struct_util:create_jid(?UID2, ?SERVER),
    XmppMsg = struct_util:create_message_stanza(?ID1, ToJid, FromJid, normal, SeenReceipt),

    PbSeenReceipt = struct_util:create_pb_seen_receipt(?ID1, ?UID2, ?TIMESTAMP1_INT),
    PbMsg = struct_util:create_pb_message(?ID1, ?UID1, ?UID2, normal, PbSeenReceipt),

    ActualXmppMsg = message_parser:proto_to_xmpp(PbMsg),
    ?assertEqual(true, is_record(ActualXmppMsg, message)),
    ?assertEqual(XmppMsg, ActualXmppMsg).


xmpp_to_proto_response_test() ->
    setup(),

    DeliveryReceipt = struct_util:create_delivery_receipt(?ID1, ?UID2, ?TIMESTAMP1),
    ToJid = struct_util:create_jid(?UID1, ?SERVER),
    FromJid = struct_util:create_jid(?UID2, ?SERVER),
    XmppMsg = struct_util:create_message_stanza(?ID1, ToJid, FromJid, normal, DeliveryReceipt),

    PbDeliveryReceipt = struct_util:create_pb_delivery_receipt(?ID1, ?UID2, ?TIMESTAMP1_INT),
    PbMsg = struct_util:create_pb_message(?ID1, ?UID1, ?UID2, normal, PbDeliveryReceipt),

    ProtoMSG = message_parser:xmpp_to_proto(XmppMsg),
    ?assertEqual(true, is_record(ProtoMSG, pb_msg)),
    ?assertEqual(PbMsg, ProtoMSG).


proto_to_xmpp_response_test() ->
    setup(),
    
    DeliveryReceipt = struct_util:create_delivery_receipt(?ID1, ?UID2, ?TIMESTAMP1),
    ToJid = struct_util:create_jid(?UID1, ?SERVER),
    FromJid = struct_util:create_jid(?UID2, ?SERVER),
    XmppMsg = struct_util:create_message_stanza(?ID1, ToJid, FromJid, normal, DeliveryReceipt),

    PbDeliveryReceipt = struct_util:create_pb_delivery_receipt(?ID1, ?UID2, ?TIMESTAMP1_INT),
    PbMsg = struct_util:create_pb_message(?ID1, ?UID1, ?UID2, normal, PbDeliveryReceipt),

    ActualXmppMsg = message_parser:proto_to_xmpp(PbMsg),
    ?assertEqual(true, is_record(ActualXmppMsg, message)),
    ?assertEqual(XmppMsg, ActualXmppMsg).


retry_count_test() ->
    setup(),
    
    DeliveryReceipt = struct_util:create_delivery_receipt(?ID1, ?UID2, ?TIMESTAMP1),
    ToJid = struct_util:create_jid(?UID1, ?SERVER),
    FromJid = struct_util:create_jid(?UID2, ?SERVER),
    XmppMsg = struct_util:create_message_stanza(?ID1, ToJid, FromJid, normal, DeliveryReceipt),
    XmppMsg1 = XmppMsg#message{retry_count = 1},

    PbDeliveryReceipt = struct_util:create_pb_delivery_receipt(?ID1, ?UID2, ?TIMESTAMP1_INT),
    PbMsg = struct_util:create_pb_message(?ID1, ?UID1, ?UID2, normal, PbDeliveryReceipt),
    PbMsg1 = PbMsg#pb_msg{retry_count = 1},

    ?assertEqual(XmppMsg1, message_parser:proto_to_xmpp(PbMsg1)),
    ?assertEqual(PbMsg1, message_parser:xmpp_to_proto(XmppMsg1)).

