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
    ProtoIQ = #pb_iq{
        id = XmppIQ#iq.id,
        type = XmppIQ#iq.type,
        payload = Content
    },
    ProtoIQ.


iq_payload_mapping(SubEl) ->
    Payload = case element(1, SubEl) of
        upload_media ->
            media_upload_parser:xmpp_to_proto(SubEl);
        contact_list ->
            contact_parser:xmpp_to_proto(SubEl);
        upload_avatar ->
            avatar_parser:xmpp_to_proto(SubEl);
        avatar ->
            avatar_parser:xmpp_to_proto(SubEl);
        avatars ->
            avatar_parser:xmpp_to_proto(SubEl);
        client_mode ->
            client_info_parser:xmpp_to_proto(SubEl);
        client_version ->
            client_info_parser:xmpp_to_proto(SubEl);
        whisper_keys ->
            whisper_keys_parser:xmpp_to_proto(SubEl);
        feed_st ->
            feed_parser:xmpp_to_proto(SubEl);
        user_privacy_list ->
            privacy_list_parser:xmpp_to_proto(SubEl);
        user_privacy_lists ->
            privacy_list_parser:xmpp_to_proto(SubEl);
        error_st ->
            Hash = SubEl#error_st.hash,
            case Hash =:= undefined orelse Hash =:= <<>> of
                true ->
                    #pb_error_stanza{reason = util:to_binary(SubEl#error_st.reason)};
                false ->
                    privacy_list_parser:xmpp_to_proto(SubEl)
            end;
        groups ->
            groups_parser:xmpp_to_proto(SubEl);
        group_st ->
            groups_parser:xmpp_to_proto(SubEl);
        client_log_st ->
            client_log_parser:xmpp_to_proto(SubEl);
        name ->
            name_parser:xmpp_to_proto(SubEl);
        group_feed_st ->
            group_feed_parser:xmpp_to_proto(SubEl);
        stanza_error ->
            #pb_error_stanza{reason = util:to_binary(SubEl#stanza_error.reason)};
        delete_account ->
            #pb_delete_account{phone = SubEl#delete_account.phone};
        _ ->
            SubEl
    end,
    Payload.


%% -------------------------------------------- %%
%% Protobuf to XMPP
%% -------------------------------------------- %%


proto_to_xmpp(ProtoIQ) ->
    Content = ProtoIQ#pb_iq.payload,
    SubEl = xmpp_iq_subel_mapping(Content),
    XmppIQ = #iq{
        id = ProtoIQ#pb_iq.id,
        type = ProtoIQ#pb_iq.type,
        sub_els = [SubEl]
    },
    XmppIQ.


xmpp_iq_subel_mapping(ProtoPayload) ->
    SubEl = case ProtoPayload of
        #pb_upload_media{} = UploadMediaRecord ->
            media_upload_parser:proto_to_xmpp(UploadMediaRecord);
        #pb_contact_list{} = ContactListRecord ->
            contact_parser:proto_to_xmpp(ContactListRecord);
        #pb_upload_avatar{} = UploadAvatarRecord ->
            avatar_parser:proto_to_xmpp(UploadAvatarRecord);
        #pb_avatar{} = AvatarRecord ->
            avatar_parser:proto_to_xmpp(AvatarRecord);
        #pb_avatars{} = AvatarsRecord ->
            avatar_parser:proto_to_xmpp(AvatarsRecord);
        #pb_client_mode{} = ClientModeRecord ->
            client_info_parser:proto_to_xmpp(ClientModeRecord);
        #pb_client_version{} = ClientVersionRecord ->
            client_info_parser:proto_to_xmpp(ClientVersionRecord);
        #pb_whisper_keys{} = WhisperKeysRecord ->
            whisper_keys_parser:proto_to_xmpp(WhisperKeysRecord);
        #pb_feed_item{} = FeedItemRecord ->
            feed_parser:proto_to_xmpp(FeedItemRecord);
        #pb_privacy_list{} = PrivacyListRecord ->
            privacy_list_parser:proto_to_xmpp(PrivacyListRecord);
        #pb_privacy_lists{} = PrivacyListsRecord ->
            privacy_list_parser:proto_to_xmpp(PrivacyListsRecord);
        #pb_groups_stanza{} = GroupsStanzaRecord ->
            groups_parser:proto_to_xmpp(GroupsStanzaRecord);
        #pb_group_stanza{} = GroupStanzaRecord ->
            groups_parser:proto_to_xmpp(GroupStanzaRecord);
        #pb_upload_group_avatar{} = GroupAvatarRecord ->
            groups_parser:proto_to_xmpp(GroupAvatarRecord);
        #pb_client_log{} = ClientLogRecord ->
            client_log_parser:proto_to_xmpp(ClientLogRecord);
        #pb_group_feed_item{} = GroupFeedItemRecord ->
            group_feed_parser:proto_to_xmpp(GroupFeedItemRecord);
        #pb_delete_account{phone = Phone} ->
            #delete_account{phone = Phone};
        _ ->
            uid_parser:translate_uid(ProtoPayload)
    end,
    SubEl.
