-module(packet_parser).

-include("packets.hrl").
-include("logger.hrl").
-include("xmpp.hrl").

-export([
    xmpp_to_proto/1,
    proto_to_xmpp/1
]).


%% -------------------------------------------- %%
%% XMPP to Protobuf
%% -------------------------------------------- %%


xmpp_to_proto(XmppStanza) ->
    PbStanza = case element(1, XmppStanza) of
        ack ->
            {ack, ack_parser:xmpp_to_proto(XmppStanza)};
        iq ->
            {iq, iq_parser:xmpp_to_proto(XmppStanza)};
        presence ->
            {presence, presence_parser:xmpp_to_proto(XmppStanza)};
        message ->
            {msg, message_parser:xmpp_to_proto(XmppStanza)};
        chat_state ->
            {chat_state, chat_state_parser:xmpp_to_proto(XmppStanza)};
        %% TODO: add error parser
        _ -> undefined
    end,
    #pb_packet{stanza = PbStanza}.


%% -------------------------------------------- %%
%% Protobuf to XMPP
%% -------------------------------------------- %%


proto_to_xmpp(PbPacket) ->
    XmppStanza = case PbPacket#pb_packet.stanza of
        {ack, AckRecord} ->
            ack_parser:proto_to_xmpp(AckRecord);
        {iq, IqRecord} ->
            iq_parser:proto_to_xmpp(IqRecord);
        {presence, PresenceRecord} ->
            presence_parser:proto_to_xmpp(PresenceRecord);
        {msg, MsgRecord} ->
            message_parser:proto_to_xmpp(MsgRecord);
        {chat_state, ChatStateRecord} ->
            chat_state_parser:proto_to_xmpp(ChatStateRecord);
        %% TODO: add error parser
        _ -> undefined
    end,
    XmppStanza.

