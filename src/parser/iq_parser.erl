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
            {upload_media, media_upload_parser:xmpp_to_proto(SubEl)};
        contact_list ->
            {contact_list, contact_parser:xmpp_to_proto(SubEl)};
        upload_avatar ->
            {upload_avatar, avatar_parser:xmpp_to_proto(SubEl)};
        avatar ->
            {avatar, avatar_parser:xmpp_to_proto(SubEl)};
        avatars ->
            {avatars, avatar_parser:xmpp_to_proto(SubEl)};
        client_mode ->
            {client_mode, client_info_parser:xmpp_to_proto(SubEl)};
        client_version ->
            {client_version, client_info_parser:xmpp_to_proto(SubEl)};
        push_register ->
            {push_register, push_parser:xmpp_to_proto(SubEl)};
        whisper_keys ->
            {whisper_keys, whisper_keys_parser:xmpp_to_proto(SubEl)};
        ping ->
            {ping, #pb_ping{}};
        feed_st ->
            {feed_item, feed_parser:xmpp_to_proto(SubEl)};
        user_privacy_list ->
            {privacy_list, privacy_list_parser:xmpp_to_proto(SubEl)};
        user_privacy_lists ->
            {privacy_lists, privacy_list_parser:xmpp_to_proto(SubEl)};
        error_st ->
            case SubEl#error_st.hash =:= undefined of
                true ->
                    %% TODO(murali@): add error_parser separately.
                    ok;
                false ->
                    {privacy_list_result, privacy_list_parser:xmpp_to_proto(SubEl)}
            end
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
        {upload_media, UploadMediaRecord} ->
            media_upload_parser:proto_to_xmpp(UploadMediaRecord);
        {contact_list, ContactListRecord} ->
            contact_parser:proto_to_xmpp(ContactListRecord);
        {upload_avatar, UploadAvatarRecord} ->
            avatar_parser:proto_to_xmpp(UploadAvatarRecord);
        {avatar, AvatarRecord} ->
            avatar_parser:proto_to_xmpp(AvatarRecord);
        {avatars, AvatarsRecord} ->
            avatar_parser:proto_to_xmpp(AvatarsRecord);
        {client_mode, ClientModeRecord} ->
            client_info_parser:proto_to_xmpp(ClientModeRecord);
        {client_version, ClientVersionRecord} ->
            client_info_parser:proto_to_xmpp(ClientVersionRecord);
        {push_register, PushRegisterRecord} ->
            push_parser:proto_to_xmpp(PushRegisterRecord);
        {whisper_keys, WhisperKeysRecord} ->
            whisper_keys_parser:proto_to_xmpp(WhisperKeysRecord);
        {ping, _} ->
            #ping{};
        {feed_item, FeedItemRecord} ->
            feed_parser:proto_to_xmpp(FeedItemRecord);
        {privacy_list, PrivacyListRecord} ->
            privacy_list_parser:proto_to_xmpp(PrivacyListRecord);
        {privacy_lists, PrivacyListsRecord} ->
            privacy_list_parser:proto_to_xmpp(PrivacyListsRecord)
    end,
    SubEl.

