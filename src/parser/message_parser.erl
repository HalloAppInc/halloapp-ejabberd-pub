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
        ProtoMessage = #pb_message{
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
            case SubEl#contact_list.contact_hash of
                [] -> {contact_list, contact_parser:xmpp_to_proto(SubEl)};
                [_] -> {contact_hash, contact_parser:xmpp_to_proto(SubEl)}
            end;
        avatar ->
            {avatar, avatar_parser:xmpp_to_proto(SubEl)};
        whisper_keys ->
            {whisper_keys, whisper_keys_parser:xmpp_to_proto(SubEl)};
        receipt_seen ->
            {seen, receipts_parser:xmpp_to_proto(SubEl)};
        receipt_response ->
            {delivery, receipts_parser:xmpp_to_proto(SubEl)};
        chat ->
            {chat, chat_parser:xmpp_to_proto(SubEl)};
        feed_st ->
            case {SubEl#feed_st.posts, SubEl#feed_st.comments} of
                {[_], []} -> {feed_item, feed_parser:xmpp_to_proto(SubEl)};
                {[], [_]} -> {feed_item, feed_parser:xmpp_to_proto(SubEl)};
                _ -> {feed_items, feed_parser:xmpp_to_proto(SubEl)}
            end;
        group_st ->
            {group_stanza, groups_parser:xmpp_to_proto(SubEl)};
        group_chat ->
            {group_chat, groups_parser:xmpp_to_proto(SubEl)};
        name ->
            {name, name_parser:xmpp_to_proto(SubEl)};
        error_st ->
            {error, #pb_error{reason = util:to_binary(SubEl#error_st.reason)}};
        groupchat_retract_st ->
            {groupchat_retract, retract_parser:xmpp_to_proto(SubEl)};
        chat_retract_st ->
            {chat_retract, retract_parser:xmpp_to_proto(SubEl)};
        group_feed_st ->
            {group_feed_item, group_feed_parser:xmpp_to_proto(SubEl)}
    end,
    Payload.


%% -------------------------------------------- %%
%% Protobuf to XMPP
%% -------------------------------------------- %%


proto_to_xmpp(ProtoMSG) ->
    ToUser = util_parser:proto_to_xmpp_uid(ProtoMSG#pb_message.to_uid),
    FromUser = util_parser:proto_to_xmpp_uid(ProtoMSG#pb_message.from_uid),
    Server = util:get_host(),
    PbToJid = jid:make(ToUser, Server),
    PbFromJid = jid:make(FromUser, Server),
    Content = ProtoMSG#pb_message.payload,
    SubEl = xmpp_msg_subel_mapping(Content),

    XmppMSG = #message{
        id = ProtoMSG#pb_message.id,
        type = ProtoMSG#pb_message.type,
        to = PbToJid,
        from = PbFromJid,
        sub_els = [SubEl]
    },
    XmppMSG.


xmpp_msg_subel_mapping(ProtoPayload) ->
    SubEl = case ProtoPayload of
        {contact_list, ContactListRecord} ->
            contact_parser:proto_to_xmpp(ContactListRecord);
        {contact_hash, ContactHashRecord} ->
            contact_parser:proto_to_xmpp(ContactHashRecord);
        {avatar, AvatarRecord} ->
            avatar_parser:proto_to_xmpp(AvatarRecord);
        {whisper_keys, WhisperKeysRecord} ->
            whisper_keys_parser:proto_to_xmpp(WhisperKeysRecord);
        {seen, SeenRecord} ->
            receipts_parser:proto_to_xmpp(SeenRecord);
        {delivery, ReceivedRecord} ->
            receipts_parser:proto_to_xmpp(ReceivedRecord);
        {chat, ChatRecord} ->
            chat_parser:proto_to_xmpp(ChatRecord);
        {feed_item, FeedItemRecord} ->
            feed_parser:proto_to_xmpp(FeedItemRecord);
        {feed_items, FeedItemsRecord} ->
            feed_parser:proto_to_xmpp(FeedItemsRecord);
        {group_stanza, GroupStanzaRecord} ->
            groups_parser:proto_to_xmpp(GroupStanzaRecord);
        {group_chat, GroupChatRecord} ->
            groups_parser:proto_to_xmpp(GroupChatRecord);
        {name, NameRecord} ->
            name_parser:proto_to_xmpp(NameRecord);
        {groupchat_retract, GroupChatRetractRecord} ->
            retract_parser:proto_to_xmpp(GroupChatRetractRecord);
        {chat_retract, ChatRetractRecord} ->
            retract_parser:proto_to_xmpp(ChatRetractRecord);
        {group_feed_item, GroupFeedItemRecord} ->
            group_feed_parser:proto_to_xmpp(GroupFeedItemRecord)
    end,
    SubEl.
