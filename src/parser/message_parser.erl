-module(message_parser).

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


xmpp_to_proto(XmppMSG) ->
    ToJid = XmppMSG#message.to,
    FromJid = XmppMSG#message.from,
    SubEls = XmppMSG#message.sub_els,
    Content = case XmppMSG#message.sub_els of
        [] ->
            undefined;
        _ ->
            [SubEl] = SubEls,
            msg_payload_mapping(SubEl)
    end,
    Protomessage = #pb_ha_message{
        id = XmppMSG#message.id,
        type = XmppMSG#message.type,
        to_uid = ToJid#jid.user,
        from_uid = FromJid#jid.user,
        payload = #pb_msg_payload{
            content = Content
        }
    },
    Protomessage.


msg_payload_mapping(SubEl) ->
    Payload = case element(1, SubEl) of
        contact_list ->
            {contact_list, contact_parser:xmpp_to_proto(SubEl)};
        avatar ->
            {avatar, avatar_parser:xmpp_to_proto(SubEl)};
        whisper_keys ->
            {whisper_keys, whisper_keys_parser:xmpp_to_proto(SubEl)};
        receipt_seen ->
            {seen, receipts_parser:xmpp_to_proto(SubEl)};
        receipt_response ->
            {delivery, receipts_parser:xmpp_to_proto(SubEl)};
        chat ->
            {chat, chat_parser:xmpp_to_proto(SubEl)}
    end,
    Payload.


%% -------------------------------------------- %%
%% Protobuf to XMPP
%% -------------------------------------------- %%


proto_to_xmpp(ProtoMSG) ->
    PbToJid = #jid{
        user = ProtoMSG#pb_ha_message.to_uid,
        server = <<"s.halloapp.net">>
    },
    PbFromJid = #jid{
        user = ProtoMSG#pb_ha_message.from_uid,
        server = <<"s.halloapp.net">>
    },
    ProtoPayload = ProtoMSG#pb_ha_message.payload,
    Content = ProtoPayload#pb_msg_payload.content,
    SubEl = xmpp_msg_subel_mapping(Content),

    XmppMSG = #message{
        id = ProtoMSG#pb_ha_message.id,
        type = ProtoMSG#pb_ha_message.type,
        to = PbToJid,
        from = PbFromJid,
        sub_els = [SubEl]
    },
    XmppMSG.


xmpp_msg_subel_mapping(ProtoPayload) ->
    SubEl = case ProtoPayload of
        {contact_list, ContactListRecord} ->
            contact_parser:proto_to_xmpp(ContactListRecord);
        {avatar, AvatarRecord} ->
            avatar_parser:proto_to_xmpp(AvatarRecord);
        {whisper_keys, WhisperKeysRecord} ->
            whisper_keys_parser:proto_to_xmpp(WhisperKeysRecord);
        {seen, SeenRecord} ->
            receipts_parser:proto_to_xmpp(SeenRecord);
        {delivery, ReceivedRecord} ->
            receipts_parser:proto_to_xmpp(ReceivedRecord);
        {chat, ChatRecord} ->
            chat_parser:proto_to_xmpp(ChatRecord)
    end,
    SubEl.

