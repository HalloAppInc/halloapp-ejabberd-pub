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

%% -------------------------------------------- %%
%% define chat constants
%% -------------------------------------------- %%

-define(UID1, <<"1000000000045484920">>).
-define(UID1_INT, 1000000000045484920).
-define(NAME1, <<"name1">>).

-define(UID2, <<"1000000000519345762">>).
-define(UID2_INT, 1000000000519345762).
-define(NAME2, <<"name2">>).

-define(ID1, <<"id1">>).

-define(SERVER, <<"s.halloapp.net">>).


%% -------------------------------------------- %%
%% internal tests
%% -------------------------------------------- %%

setup() ->
    stringprep:start(),
    ok.


xmpp_to_proto_message_name_test() ->
    setup(),

    PbName = struct_util:create_pb_name(?UID1_INT, ?NAME1),
    PbMessage = struct_util:create_pb_message(?ID1, ?UID2_INT, 0, normal, PbName),

    NameSt = struct_util:create_name_st(?UID1, ?NAME1),
    ToJid = struct_util:create_jid(?UID2, ?SERVER),
    FromJid = struct_util:create_jid(<<>>, ?SERVER),
    MessageSt = struct_util:create_message_stanza(?ID1, ToJid, FromJid, normal, NameSt),

    ProtoMsg = message_parser:xmpp_to_proto(MessageSt),
    ?assertEqual(true, is_record(ProtoMsg, pb_msg)),
    ?assertEqual(PbMessage, ProtoMsg).


proto_to_xmpp_iq_name_test() ->
    setup(),

    PbName = struct_util:create_pb_name(?UID1_INT, ?NAME1),
    PbIq = struct_util:create_pb_iq(?ID1, set, PbName),

    NameSt = struct_util:create_name_st(?UID1, ?NAME1),
    IqSt = struct_util:create_iq_stanza(?ID1, undefined, undefined, set, NameSt),

    XmppIq = iq_parser:proto_to_xmpp(PbIq),
    ?assertEqual(true, is_record(XmppIq, iq)),
    ?assertEqual(IqSt, XmppIq).


proto_to_xmpp_iq_name_empty_uid_test() ->
    setup(),

    PbName = struct_util:create_pb_name(0, ?NAME1),
    PbIq = struct_util:create_pb_iq(?ID1, set, PbName),

    NameSt = struct_util:create_name_st(<<>>, ?NAME1),
    IqSt = struct_util:create_iq_stanza(?ID1, undefined, undefined, set, NameSt),

    XmppIq = iq_parser:proto_to_xmpp(PbIq),
    ?assertEqual(true, is_record(XmppIq, iq)),
    ?assertEqual(IqSt, XmppIq).


