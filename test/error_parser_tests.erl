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

-define(UID1, <<"1000000000045484920">>).
-define(UID1_INT, 1000000000045484920).

-define(UID2, <<"1000000000519345762">>).
-define(UID2_INT, 1000000000519345762).

-define(ID1, <<"id1">>).
-define(SERVER, <<"s.halloapp.net">>).



create_error_st(Reason) ->
    util:err(Reason).


create_iq_stanza(Id, ToJid, FromJid, Type, SubEl) ->
    #iq{
        id = Id,
        to = ToJid,
        from = FromJid,
        type = Type,
        sub_els = [SubEl]
    }.


create_pb_error(Reason) ->
    #pb_error{
        reason = Reason
    }.


create_pb_iq(Id, Type, PayloadContent) ->
    #pb_ha_iq{
        id = Id,
        type = Type,
        payload = #pb_iq_payload{
                content = PayloadContent
            }
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
        payload = #pb_msg_payload{
                content = PayloadContent
            }
    }.


create_jid(Uid, Server) ->
    jid:make(Uid, Server).


setup() ->
    stringprep:start(),
    ok.

%% -------------------------------------------- %%
%% Tests
%% -------------------------------------------- %%


xmpp_to_proto_message_error_test() ->
    setup(),

    PbError = create_pb_error(<<"invalid_uid">>),
    PbMessage = create_pb_message(?ID1, ?UID2_INT, ?UID1_INT, normal, {error, PbError}),

    ErrorSt = create_error_st(invalid_uid),
    ToJid = create_jid(?UID2, ?SERVER),
    FromJid = create_jid(?UID1, ?SERVER),
    MessageSt = create_message_stanza(?ID1, ToJid, FromJid, normal, ErrorSt),

    ProtoMsg = message_parser:xmpp_to_proto(MessageSt),
    ?assertEqual(true, is_record(ProtoMsg, pb_ha_message)),
    ?assertEqual(PbMessage, ProtoMsg).


xmpp_to_proto_iq_error_test() ->
    setup(),

    PbError = create_pb_error(<<"invalid_id">>),
    PbIq = create_pb_iq(?ID1, error, {error, PbError}),

    ErrorSt = create_error_st(invalid_id),
    IqSt = create_iq_stanza(?ID1, undefined, undefined, error, ErrorSt),

    ProtoIq = iq_parser:xmpp_to_proto(IqSt),
    ?assertEqual(true, is_record(ProtoIq, pb_ha_iq)),
    ?assertEqual(PbIq, ProtoIq).


