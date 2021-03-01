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
            ack_parser:xmpp_to_proto(XmppStanza);
        iq ->
            iq_parser:xmpp_to_proto(XmppStanza);
        presence ->
            presence_parser:xmpp_to_proto(XmppStanza);
        message ->
            message_parser:xmpp_to_proto(XmppStanza);
        chat_state ->
            chat_state_parser:xmpp_to_proto(XmppStanza);
        %% TODO: add error parser
        _ -> undefined
    end,
    #pb_packet{stanza = PbStanza}.


%% -------------------------------------------- %%
%% Protobuf to XMPP
%% -------------------------------------------- %%


proto_to_xmpp(PbPacket) ->
    XmppStanza = case PbPacket#pb_packet.stanza of
        #pb_ack{} = AckRecord ->
            AckRecord;
        #pb_iq{} = IqRecord ->
            IqRecord;
        #pb_presence{} = PresenceRecord ->
            PresenceRecord;
        #pb_msg{} = MsgRecord ->
            message_parser:proto_to_xmpp(MsgRecord);
        #pb_chat_state{} = ChatStateRecord ->
            ChatStateRecord;
        %% TODO: add error parser
        _ -> undefined
    end,
    XmppStanza.

