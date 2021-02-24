%%%-------------------------------------------------------------------
%%% File: name_parser_tests.erl
%%% Copyright (C) 2020, Halloapp Inc.
%%%
%%%-------------------------------------------------------------------
-module(name_parser_tests).
-author('murali').

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


xmpp_to_proto_message_name_test() ->
    setup(),

    PbName = struct_util:create_pb_name(?UID1, ?NAME1),
    PbMessage = struct_util:create_pb_message(?ID1, ?UID2, <<>>, normal, PbName),

    NameSt = struct_util:create_name_st(?UID1, ?NAME1),
    ToJid = struct_util:create_jid(?UID2, ?SERVER),
    FromJid = struct_util:create_jid(<<>>, ?SERVER),
    MessageSt = struct_util:create_message_stanza(?ID1, ToJid, FromJid, normal, NameSt),

    ProtoMsg = message_parser:xmpp_to_proto(MessageSt),
    ?assertEqual(true, is_record(ProtoMsg, pb_msg)),
    ?assertEqual(PbMessage, ProtoMsg).


