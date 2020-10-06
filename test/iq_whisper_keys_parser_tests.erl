%%%-------------------------------------------------------------------
%%% @author yexin
%%% @copyright (C) 2020, HalloApp, Inc.
%%% @doc
%%%
%%% @end
%%% Created : 17. Jul 2020 3:25 PM
%%%-------------------------------------------------------------------
-module(iq_whisper_keys_parser_tests).
-author("yexin").

-include_lib("eunit/include/eunit.hrl").
-include("packets.hrl").
-include("xmpp.hrl").
-include("parser_test_data.hrl").

%% -------------------------------------------- %%
%% internal tests
%% -------------------------------------------- %%


xmpp_to_proto_whisper_keys_test() ->
    WhisperKeys = struct_util:create_whisper_keys(?UID1, add, ?KEY1_BASE64, ?KEY2_BASE64, <<"5">>, [?KEY3_BASE64, ?KEY4_BASE64]),
    XmppIq = struct_util:create_iq_stanza(?ID2, undefined, undefined, result, WhisperKeys),

    PbWhisperKeys = struct_util:create_pb_whisper_keys(?UID1_INT, add, ?KEY1, ?KEY2, 5, [?KEY3, ?KEY4]),
    PbIq = struct_util:create_pb_iq(?ID2, result, PbWhisperKeys),

    ProtoIQ = iq_parser:xmpp_to_proto(XmppIq),
    ?assertEqual(true, is_record(ProtoIQ, pb_iq)),
    ?assertEqual(PbIq, ProtoIQ).


proto_to_xmpp_whisper_keys_test() ->
    WhisperKeys = struct_util:create_whisper_keys(?UID1, count, undefined, undefined, undefined, []),
    XmppIq = struct_util:create_iq_stanza(?ID2, undefined, undefined, get, WhisperKeys),

    PbWhisperKeys = struct_util:create_pb_whisper_keys(?UID1_INT, count, undefined, undefined, undefined, []),
    PbIq = struct_util:create_pb_iq(?ID2, get, PbWhisperKeys),

    ActualXmppIQ = iq_parser:proto_to_xmpp(PbIq),
    ?assertEqual(true, is_record(ActualXmppIQ, iq)),
    ?assertEqual(XmppIq, ActualXmppIQ).

