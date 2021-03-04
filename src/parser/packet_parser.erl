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
            case MsgRecord#pb_msg.payload of
                #pb_chat_stanza{} -> MsgRecord;
                #pb_seen_receipt{} -> MsgRecord;
                #pb_delivery_receipt{} -> MsgRecord;
                #pb_silent_chat_stanza{} -> MsgRecord;
                #pb_rerequest{} -> MsgRecord;
                #pb_chat_retract{} -> MsgRecord;
                _ -> message_parser:proto_to_xmpp(MsgRecord)
            end;
        #pb_chat_state{} = ChatStateRecord ->
            ChatStateRecord;
        %% TODO: add error parser
        _ -> undefined
    end,
    XmppStanza.

