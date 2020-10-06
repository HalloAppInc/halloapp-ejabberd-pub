%%%-------------------------------------------------------------------
%%% @author yexin
%%% @copyright (C) 2020, HalloApp, Inc.
%%% @doc
%%%
%%% @end
%%% Created : 17. Jul 2020 3:10 PM
%%%-------------------------------------------------------------------
-module(message_contact_parser_tests).
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


xmpp_to_proto_contact_list_test() ->
    setup(),

    Contact1 = struct_util:create_contact(add, ?RAW1, ?NORM1, ?UID1, ?ID1, ?NAME1, <<"friends">>),
    Contact2 = struct_util:create_contact(delete, ?RAW2, ?NORM2, ?UID2, ?ID2, ?NAME2, <<"none">>),
    ContactList = struct_util:create_contact_list(full, ?ID1, 0, true, [Contact1, Contact2], []),
    ToJid = struct_util:create_jid(?UID1, ?SERVER),
    FromJid = struct_util:create_jid(?UID2, ?SERVER),
    XmppMsg = struct_util:create_message_stanza(?ID1, ToJid, FromJid, normal, ContactList),

    PbContact1 = struct_util:create_pb_contact(add, ?RAW1, ?NORM1, ?UID1_INT, ?ID1, ?NAME1, friends),
    PbContact2 = struct_util:create_pb_contact(delete, ?RAW2, ?NORM2, ?UID2_INT, ?ID2, ?NAME2, none),
    PbContactList = struct_util:create_pb_contact_list(full, ?ID1, 0, true, [PbContact1, PbContact2]),
    PbMsg = struct_util:create_pb_message(?ID1, ?UID1_INT, ?UID2_INT, normal, PbContactList),

    ProtoMSG = message_parser:xmpp_to_proto(XmppMsg),
    ?assertEqual(true, is_record(ProtoMSG, pb_msg)),
    ?assertEqual(PbMsg, ProtoMSG).


xmpp_to_proto_contact_hash_test() ->
    setup(),
    ContactList = struct_util:create_contact_list(normal, <<>>, undefined, true, [], [?HASH1_BASE64]),
    ToJid = struct_util:create_jid(?UID1, ?SERVER),
    FromJid = struct_util:create_jid(?UID2, ?SERVER),
    XmppMsg = struct_util:create_message_stanza(?ID1, ToJid, FromJid, normal, ContactList),

    PbContactList = struct_util:create_pb_contact_hash(?HASH1),
    PbMsg = struct_util:create_pb_message(?ID1, ?UID1_INT, ?UID2_INT, normal, PbContactList),

    ProtoMSG = message_parser:xmpp_to_proto(XmppMsg),
    ?assertEqual(true, is_record(ProtoMSG, pb_msg)),
    ?assertEqual(PbMsg, ProtoMSG).

