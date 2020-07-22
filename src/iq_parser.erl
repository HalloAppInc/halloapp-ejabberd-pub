-module(iq_parser).

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


xmpp_to_proto(XmppIQ) -> 
    SubEls = XmppIQ#iq.sub_els,
    Content = case XmppIQ#iq.sub_els of 
        [] -> 
            undefined;
        _ -> 
            [SubEl] = SubEls,
            iq_payload_mapping(SubEl)
    end, 
    ProtoIQ = #pb_ha_iq{
        id = XmppIQ#iq.id,
        type = XmppIQ#iq.type,
        payload = #pb_iq_payload{
            content = Content
        }
    },
    ProtoIQ.


iq_payload_mapping(SubEl) ->
    Payload = case element(1, SubEl) of 
        upload_media ->
            {um, media_upload_parser:xmpp_to_proto(SubEl)};
        contact_list ->
            {cl, contact_parser:xmpp_to_proto(SubEl)};
        avatar ->
            {a, avatar_parser:xmpp_to_proto(SubEl)}; 
        avatars ->
            {as, avatar_parser:xmpp_to_proto(SubEl)}; 
        client_mode ->
            {cm, client_info_parser:xmpp_to_proto(SubEl)};
        client_version ->
            {cv, client_info_parser:xmpp_to_proto(SubEl)};
        push_register ->
            {pr, push_parser:xmpp_to_proto(SubEl)};
        whisper_keys ->
            {wk, whisper_keys_parser:xmpp_to_proto(SubEl)};
        ping ->
            {p, #pb_ping{}}
        %% TODO: not include feed_item and feed_node_items yet 
    end,
    Payload.
        

%% -------------------------------------------- %%
%% Protobuf to XMPP
%% -------------------------------------------- %%


proto_to_xmpp(ProtoIQ) -> 
    ProtoPayload = ProtoIQ#pb_ha_iq.payload,
    Content = ProtoPayload#pb_iq_payload.content,
    SubEl = xmpp_iq_subel_mapping(Content),
    XmppIQ = #iq{
        id = ProtoIQ#pb_ha_iq.id,
        type = ProtoIQ#pb_ha_iq.type,
        sub_els = [SubEl]
    },
    XmppIQ.


xmpp_iq_subel_mapping(ProtoPayload) -> 
    SubEl = case ProtoPayload of
        {um, UploadMediaRecord} -> 
            media_upload_parser:proto_to_xmpp(UploadMediaRecord);
        {cl, ContactListRecord} -> 
            contact_parser:proto_to_xmpp(ContactListRecord);
        {a, AvatarRecord} ->
            avatar_parser:proto_to_xmpp(AvatarRecord);
        {as, AvatarsRecord} ->
            avatar_parser:proto_to_xmpp(AvatarsRecord);
        {cm, ClientModeRecord} ->
            client_info_parser:proto_to_xmpp(ClientModeRecord);
        {cv, ClientVersionRecord} ->
            client_info_parser:proto_to_xmpp(ClientVersionRecord);
        {pr, PushRegisterRecord} ->
            push_parser:proto_to_xmpp(PushRegisterRecord);
        {wk, WhisperKeysRecord} ->
            whisper_keys_parser:proto_to_xmpp(WhisperKeysRecord);
        {p, _} ->
            #ping{}
    end,
    SubEl.
    
