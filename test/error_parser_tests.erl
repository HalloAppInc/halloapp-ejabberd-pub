%%%-------------------------------------------------------------------
%%% File: error_parser_tests.erl
%%% Copyright (C) 2020, Halloapp Inc.
%%%
%%%-------------------------------------------------------------------
-module(error_parser_tests).
-author('murali').

-include_lib("eunit/include/eunit.hrl").
-include("packets.hrl").
-include("xmpp.hrl").
-include("parser_test_data.hrl").

setup() ->
    stringprep:start(),
    ok.

%% -------------------------------------------- %%
%% Tests
%% -------------------------------------------- %%


xmpp_to_proto_message_error_test() ->
    setup(),

    PbError = struct_util:create_pb_error(<<"invalid_uid">>),
    PbMessage = struct_util:create_pb_message(?ID1, ?UID2_INT, ?UID1_INT, normal, PbError),

    ErrorSt = struct_util:create_error_st(invalid_uid, <<>>),
    ToJid = struct_util:create_jid(?UID2, ?SERVER),
    FromJid = struct_util:create_jid(?UID1, ?SERVER),
    MessageSt = struct_util:create_message_stanza(?ID1, ToJid, FromJid, normal, ErrorSt),

    ProtoMsg = message_parser:xmpp_to_proto(MessageSt),
    ?assertEqual(true, is_record(ProtoMsg, pb_msg)),
    ?assertEqual(PbMessage, ProtoMsg).



xmpp_to_proto_message_stanza_error_test() ->
    setup(),

    PbError = struct_util:create_pb_error(<<"item-not-found">>),
    PbMessage = struct_util:create_pb_message(?ID1, ?UID2_INT, ?UID1_INT, normal, PbError),

    ErrorSt = struct_util:create_error_st('item-not-found', <<>>),
    ToJid = struct_util:create_jid(?UID2, ?SERVER),
    FromJid = struct_util:create_jid(?UID1, ?SERVER),
    MessageSt = struct_util:create_message_stanza(?ID1, ToJid, FromJid, normal, ErrorSt),

    ProtoMsg = message_parser:xmpp_to_proto(MessageSt),
    ?assertEqual(true, is_record(ProtoMsg, pb_msg)),
    ?assertEqual(PbMessage, ProtoMsg).


xmpp_to_proto_iq_error_test() ->
    setup(),

    PbError = struct_util:create_pb_error(<<"invalid_id">>),
    PbIq = struct_util:create_pb_iq(?ID1, error, PbError),

    ErrorSt = struct_util:create_error_st(invalid_id),
    IqSt = struct_util:create_iq_stanza(?ID1, undefined, undefined, error, ErrorSt),

    ProtoIq = iq_parser:xmpp_to_proto(IqSt),
    ?assertEqual(true, is_record(ProtoIq, pb_iq)),
    ?assertEqual(PbIq, ProtoIq).


xmpp_to_proto_iq_error_stanza_test() ->
    setup(),

    PbError = struct_util:create_pb_error(<<"internal-server-error">>),
    PbIq = struct_util:create_pb_iq(?ID1, error, PbError),

    ErrorSt = struct_util:create_stanza_error('internal-server-error'),
    IqSt = struct_util:create_iq_stanza(?ID1, undefined, undefined, error, ErrorSt),

    ProtoIq = iq_parser:xmpp_to_proto(IqSt),
    ?assertEqual(true, is_record(ProtoIq, pb_iq)),
    ?assertEqual(PbIq, ProtoIq).

