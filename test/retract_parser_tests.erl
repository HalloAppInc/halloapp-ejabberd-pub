%%%-------------------------------------------------------------------
%%% File: retract_parser_tests.erl
%%% Copyright (C) 2020, Halloapp Inc.
%%%
%%%-------------------------------------------------------------------

-module(retract_parser_tests).
-author('murali').

-include_lib("eunit/include/eunit.hrl").
-include("packets.hrl").
-include("xmpp.hrl").

-define(UID1, <<"1000000000045484920">>).

-define(UID2, <<"1000000000519345762">>).

-define(GID1, <<"gid1">>).
-define(ID1, <<"id1">>).
-define(SERVER, <<"s.halloapp.net">>).


%% -------------------------------------------- %%
%% internal tests
%% -------------------------------------------- %%

setup() ->
    stringprep:start(),
    ok.


xmpp_to_proto_chat_test() ->
    setup(),
    RetractSt = struct_util:create_chat_retract_st(?ID1),
    XmppMsg = struct_util:create_message_stanza(?ID1, jid:make(?UID1, ?SERVER), jid:make(?UID2, ?SERVER), normal, RetractSt),

    PbRetract = struct_util:create_pb_chat_retract(?ID1),
    ExpectedProtoMsg = struct_util:create_pb_message(?ID1, ?UID1, ?UID2, normal, PbRetract),

    ActualProtoMsg = message_parser:xmpp_to_proto(XmppMsg),
    ?assertEqual(true, is_record(ActualProtoMsg, pb_msg)),
    ?assertEqual(ExpectedProtoMsg, ActualProtoMsg).


xmpp_to_proto_groupchat_test() ->
    setup(),
    RetractSt = struct_util:create_groupchat_retract_st(?ID1, ?GID1),
    XmppMsg = struct_util:create_message_stanza(?ID1, jid:make(?UID1, ?SERVER), jid:make(?UID2, ?SERVER), groupchat, RetractSt),

    PbRetract = struct_util:create_pb_groupchat_retract(?ID1, ?GID1),
    ExpectedProtoMsg = struct_util:create_pb_message(?ID1, ?UID1, ?UID2, groupchat, PbRetract),

    ActualProtoMsg = message_parser:xmpp_to_proto(XmppMsg),
    ?assertEqual(true, is_record(ActualProtoMsg, pb_msg)),
    ?assertEqual(ExpectedProtoMsg, ActualProtoMsg).


proto_to_xmpp_chat_test() ->
    setup(),
    RetractSt = struct_util:create_chat_retract_st(?ID1),
    ExpectedXmppMsg = struct_util:create_message_stanza(?ID1, jid:make(?UID2, ?SERVER), jid:make(?UID1, ?SERVER), normal, RetractSt),

    PbRetract = struct_util:create_pb_chat_retract(?ID1),
    ProtoMsg = struct_util:create_pb_message(?ID1, ?UID2, ?UID1, normal, PbRetract),

    ActualXmppMsg = message_parser:proto_to_xmpp(ProtoMsg),
    ?assertEqual(true, is_record(ActualXmppMsg, message)),
    ?assertEqual(ExpectedXmppMsg, ActualXmppMsg).


proto_to_xmpp_groupchat_test() ->
    setup(),
    RetractSt = struct_util:create_groupchat_retract_st(?ID1, ?GID1),
    ExpectedXmppMsg = struct_util:create_message_stanza(?ID1, jid:make(?UID1, ?SERVER), jid:make(?UID2, ?SERVER), groupchat, RetractSt),

    PbRetract = struct_util:create_pb_groupchat_retract(?ID1, ?GID1),
    ProtoMsg = struct_util:create_pb_message(?ID1, ?UID1, ?UID2, groupchat, PbRetract),

    ActualXmppMsg = message_parser:proto_to_xmpp(ProtoMsg),
    ?assertEqual(true, is_record(ActualXmppMsg, message)),
    ?assertEqual(ExpectedXmppMsg, ActualXmppMsg).


