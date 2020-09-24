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
-define(UID1_INT, 1000000000045484920).

-define(UID2, <<"1000000000519345762">>).
-define(UID2_INT, 1000000000519345762).

-define(GID1, <<"gid1">>).
-define(ID1, <<"id1">>).
-define(SERVER, <<"s.halloapp.net">>).

%% -------------------------------------------- %%
%% define constants
%% -------------------------------------------- %%

create_chat_retract_st(Id) ->
    #chat_retract_st{
        id = Id
    }.


create_groupchat_retract_st(Id, Gid) ->
    #groupchat_retract_st{
        id = Id,
        gid = Gid
    }.


create_pb_chat_retract(Id) ->
    #pb_chat_retract{
        id = Id
    }.


create_pb_groupchat_retract(Id, Gid) ->
    #pb_groupchat_retract{
        id = Id,
        gid = Gid
    }.


create_message_stanza(Id, ToJid, FromJid, Type, SubEl) ->
    #message{
        id = Id,
        to = ToJid,
        from = FromJid,
        type = Type,
        sub_els = [SubEl]
    }.


create_pb_message(Id, ToUid, FromUid, Type, PayloadContent) ->
    #pb_ha_message{
        id = Id,
        to_uid = ToUid,
        from_uid = FromUid,
        type = Type,
        payload = PayloadContent
    }.


%% -------------------------------------------- %%
%% internal tests
%% -------------------------------------------- %%

setup() ->
    stringprep:start(),
    ok.


xmpp_to_proto_chat_test() ->
    setup(),
    RetractSt = create_chat_retract_st(?ID1),
    XmppMsg = create_message_stanza(?ID1, jid:make(?UID1, ?SERVER), jid:make(?UID2, ?SERVER), normal, RetractSt),

    PbRetract = create_pb_chat_retract(?ID1),
    ExpectedProtoMsg = create_pb_message(?ID1, ?UID1_INT, ?UID2_INT, normal, {chat_retract, PbRetract}),

    ActualProtoMsg = message_parser:xmpp_to_proto(XmppMsg),
    ?assertEqual(true, is_record(ActualProtoMsg, pb_ha_message)),
    ?assertEqual(ExpectedProtoMsg, ActualProtoMsg).


xmpp_to_proto_groupchat_test() ->
    setup(),
    RetractSt = create_groupchat_retract_st(?ID1, ?GID1),
    XmppMsg = create_message_stanza(?ID1, jid:make(?UID1, ?SERVER), jid:make(?UID2, ?SERVER), groupchat, RetractSt),

    PbRetract = create_pb_groupchat_retract(?ID1, ?GID1),
    ExpectedProtoMsg = create_pb_message(?ID1, ?UID1_INT, ?UID2_INT, groupchat, {groupchat_retract, PbRetract}),

    ActualProtoMsg = message_parser:xmpp_to_proto(XmppMsg),
    ?assertEqual(true, is_record(ActualProtoMsg, pb_ha_message)),
    ?assertEqual(ExpectedProtoMsg, ActualProtoMsg).


proto_to_xmpp_chat_test() ->
    setup(),
    RetractSt = create_chat_retract_st(?ID1),
    ExpectedXmppMsg = create_message_stanza(?ID1, jid:make(?UID2, ?SERVER), jid:make(?UID1, ?SERVER), normal, RetractSt),

    PbRetract = create_pb_chat_retract(?ID1),
    ProtoMsg = create_pb_message(?ID1, ?UID2_INT, ?UID1_INT, normal, {chat_retract, PbRetract}),

    ActualXmppMsg = message_parser:proto_to_xmpp(ProtoMsg),
    ?assertEqual(true, is_record(ActualXmppMsg, message)),
    ?assertEqual(ExpectedXmppMsg, ActualXmppMsg).


proto_to_xmpp_groupchat_test() ->
    setup(),
    RetractSt = create_groupchat_retract_st(?ID1, ?GID1),
    ExpectedXmppMsg = create_message_stanza(?ID1, jid:make(?UID1, ?SERVER), jid:make(?UID2, ?SERVER), groupchat, RetractSt),

    PbRetract = create_pb_groupchat_retract(?ID1, ?GID1),
    ProtoMsg = create_pb_message(?ID1, ?UID1_INT, ?UID2_INT, groupchat, {groupchat_retract, PbRetract}),

    ActualXmppMsg = message_parser:proto_to_xmpp(ProtoMsg),
    ?assertEqual(true, is_record(ActualXmppMsg, message)),
    ?assertEqual(ExpectedXmppMsg, ActualXmppMsg).


