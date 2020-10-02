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


xmpp_to_proto(XmppMsg) ->
    try
        Message = xmpp:decode_els(XmppMsg),
        ToJid = Message#message.to,
        FromJid = Message#message.from,
        SubEls = Message#message.sub_els,
        Content = case Message#message.sub_els of
            [] ->
                undefined;
            _ ->
                [SubEl] = SubEls,
                msg_payload_mapping(SubEl)
        end,
        PbFromUid = util_parser:xmpp_to_proto_uid(FromJid#jid.user),
        ProtoMessage = #pb_msg{
            id = Message#message.id,
            type = Message#message.type,
            to_uid = util_parser:xmpp_to_proto_uid(ToJid#jid.user),
            from_uid = PbFromUid,
            payload = Content
        },
        ProtoMessage
    catch
        error : Reason ->
            ?ERROR_MSG("Error decoding xmpp message: ~p, reason: ~p", [XmppMsg, Reason]),
            undefined
    end.


msg_payload_mapping(SubEl) ->
    Payload = case element(1, SubEl) of
        contact_list ->
            contact_parser:xmpp_to_proto(SubEl);
        avatar ->
            avatar_parser:xmpp_to_proto(SubEl);
        whisper_keys ->
            whisper_keys_parser:xmpp_to_proto(SubEl);
        receipt_seen ->
            receipts_parser:xmpp_to_proto(SubEl);
        receipt_response ->
            receipts_parser:xmpp_to_proto(SubEl);
        chat ->
            chat_parser:xmpp_to_proto(SubEl);
        feed_st ->
            feed_parser:xmpp_to_proto(SubEl);
        group_st ->
            groups_parser:xmpp_to_proto(SubEl);
        group_chat ->
            groups_parser:xmpp_to_proto(SubEl);
        name ->
            name_parser:xmpp_to_proto(SubEl);
        error_st ->
            #pb_error_stanza{reason = util:to_binary(SubEl#error_st.reason)};
        groupchat_retract_st ->
            retract_parser:xmpp_to_proto(SubEl);
        chat_retract_st ->
            retract_parser:xmpp_to_proto(SubEl);
        group_feed_st ->
            group_feed_parser:xmpp_to_proto(SubEl)
    end,
    Payload.


%% -------------------------------------------- %%
%% Protobuf to XMPP
%% -------------------------------------------- %%


proto_to_xmpp(ProtoMSG) ->
    ToUser = util_parser:proto_to_xmpp_uid(ProtoMSG#pb_msg.to_uid),
    FromUser = util_parser:proto_to_xmpp_uid(ProtoMSG#pb_msg.from_uid),
    Server = util:get_host(),
    PbToJid = jid:make(ToUser, Server),
    PbFromJid = jid:make(FromUser, Server),
    Content = ProtoMSG#pb_msg.payload,
    SubEl = xmpp_msg_subel_mapping(Content),

    XmppMSG = #message{
        id = ProtoMSG#pb_msg.id,
        type = ProtoMSG#pb_msg.type,
        to = PbToJid,
        from = PbFromJid,
        sub_els = [SubEl]
    },
    XmppMSG.


xmpp_msg_subel_mapping(ProtoPayload) ->
    SubEl = case ProtoPayload of
        #pb_contact_list{} = ContactListRecord ->
            contact_parser:proto_to_xmpp(ContactListRecord);
        #pb_contact_hash{} = ContactHashRecord ->
            contact_parser:proto_to_xmpp(ContactHashRecord);
        #pb_avatar{} = AvatarRecord ->
            avatar_parser:proto_to_xmpp(AvatarRecord);
        #pb_whisper_keys{} = WhisperKeysRecord ->
            whisper_keys_parser:proto_to_xmpp(WhisperKeysRecord);
        #pb_seen_receipt{} = SeenRecord ->
            receipts_parser:proto_to_xmpp(SeenRecord);
        #pb_delivery_receipt{} = ReceivedRecord ->
            receipts_parser:proto_to_xmpp(ReceivedRecord);
        #pb_chat_stanza{} = ChatRecord ->
            chat_parser:proto_to_xmpp(ChatRecord);
        #pb_feed_item{} = FeedItemRecord ->
            feed_parser:proto_to_xmpp(FeedItemRecord);
        #pb_feed_items{} = FeedItemsRecord ->
            feed_parser:proto_to_xmpp(FeedItemsRecord);
        #pb_group_stanza{} = GroupStanzaRecord ->
            groups_parser:proto_to_xmpp(GroupStanzaRecord);
        #pb_group_chat{} = GroupChatRecord ->
            groups_parser:proto_to_xmpp(GroupChatRecord);
        #pb_name{} = NameRecord ->
            name_parser:proto_to_xmpp(NameRecord);
        #pb_group_chat_retract{} = GroupChatRetractRecord ->
            retract_parser:proto_to_xmpp(GroupChatRetractRecord);
        #pb_chat_retract{} = ChatRetractRecord ->
            retract_parser:proto_to_xmpp(ChatRetractRecord);
        #pb_group_feed_item{} = GroupFeedItemRecord ->
            group_feed_parser:proto_to_xmpp(GroupFeedItemRecord)
    end,
    SubEl.
