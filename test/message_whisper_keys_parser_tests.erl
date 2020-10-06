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

    PbWhisperKeys = struct_util:create_pb_whisper_keys(?UID1_INT, add, ?KEY1, ?KEY2, 5, [?KEY3, ?KEY4]),
    PbMsg = struct_util:create_pb_message(?ID1, ?UID1_INT, ?UID2_INT, normal, PbWhisperKeys),

    ProtoMsg = message_parser:xmpp_to_proto(XmppMsg),
    ?assertEqual(true, is_record(ProtoMsg, pb_msg)),
    ?assertEqual(PbMsg, ProtoMsg).

