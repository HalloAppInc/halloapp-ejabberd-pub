%%%-------------------------------------------------------------------
%%% File: struct_util.erl
%%% Copyright (C) 2020, Halloapp Inc.
%%%
%%%-------------------------------------------------------------------
-module(struct_util).
-author('murali').

-include_lib("eunit/include/eunit.hrl").
-include("packets.hrl").
-include("xmpp.hrl").

%% Export all functions for unit tests
-compile(export_all).


create_pb_audience(Type, Uids) ->
    #pb_audience{
        type = Type,
        uids = Uids
    }.

create_pb_post(Id, PublisherUid, PublisherName, Payload, Audience, Timestamp) ->
    #pb_post{
        id = Id,
        publisher_uid = PublisherUid,
        publisher_name = PublisherName,
        payload = Payload,
        audience = Audience,
        timestamp = Timestamp
    }.



create_pb_comment(Id, PostId, ParentCommentId, PublisherUid, PublisherName, Payload, Timestamp) ->
    #pb_comment{
        id = Id,
        post_id = PostId,
        parent_comment_id = ParentCommentId,
        publisher_uid = PublisherUid,
        publisher_name = PublisherName,
        payload = Payload,
        timestamp = Timestamp
    }.


create_feed_item(Action, Item) ->
    #pb_feed_item{
        action = Action,
        item = Item
    }.


create_feed_items(Uid, Items) ->
    #pb_feed_items{
        uid = Uid,
        items = Items
    }.

create_share_feed_request(Uid, PostIds) ->
    #pb_share_stanza{
        uid = Uid,
        post_ids = PostIds
    }.


create_share_feed_requests(PbShareStanzas) ->
    #pb_feed_item{
        action = share,
        share_stanzas = PbShareStanzas
    }.


create_share_feed_response(Uid, Result, Reason) ->
    #pb_share_stanza {
        uid = Uid,
        result = Result,
        reason = Reason
    }.


create_share_feed_responses(PbShareStanzas) ->
    #pb_feed_item{
        action = share,
        share_stanzas = PbShareStanzas
    }.


create_group_feed_item(Action, Gid, Name, AvatarId, Item) ->
    #pb_group_feed_item{
        action = Action,
        gid = Gid,
        name = Name,
        avatar_id = AvatarId,
        item = Item
    }.


create_group_feed_items(Gid, Name, AvatarId, Items) ->
    #pb_group_feed_items{
        gid = Gid,
        name = Name,
        avatar_id = AvatarId,
        items = Items
    }.


create_jid(Uid, Server) ->
    jid:make(Uid, Server).


create_pb_message(Id, ToUid, FromUid, Type, PayloadContent) ->
    #pb_msg{
        id = Id,
        to_uid = ToUid,
        from_uid = FromUid,
        type = Type,
        payload = PayloadContent
    }.


create_pb_iq(Id, Type, PayloadContent) ->
    #pb_iq{
        id = Id,
        type = Type,
        payload = PayloadContent
    }.


create_pb_member(Action, Uid, Type, Name, AvatarId, Result, Reason) ->
    #pb_group_member{
        action = Action,
        uid = Uid,
        type = Type,
        name = Name,
        avatar_id = AvatarId,
        result = Result,
        reason = Reason
    }.


create_group_st(Action, Gid, Name, AvatarId, SenderUid, SenderName, Members) ->
    #group_st{
        action = Action,
        gid = Gid,
        name = Name,
        avatar = AvatarId,
        sender = SenderUid,
        sender_name = SenderName,
        members = Members
    }.


create_pb_group_stanza(Action, Gid, Name, AvatarId, SenderUid, SenderName, PbMembers) ->
    #pb_group_stanza{
        action = Action,
        gid = Gid,
        name = Name,
        avatar_id = AvatarId,
        sender_uid = SenderUid,
        sender_name = SenderName,
        members = PbMembers
    }.


create_pb_groups_stanza(Action, GroupsStanza) ->
    #pb_groups_stanza{
        action = Action,
        group_stanzas = GroupsStanza
    }.


create_pb_name(Uid, Name) ->
    #pb_name{
        uid = Uid,
        name = Name
    }.


create_pb_uid_element(Action, Uid) ->
    #pb_uid_element{
        action = Action,
        uid = Uid
    }.


create_pb_privacy_list(Type, Hash, UidElements) ->
    #pb_privacy_list{
        type = Type,
        hash = Hash,
        uid_elements = UidElements
    }.


create_pb_privacy_lists(ActiveType, PbPrivacyLists) ->
    #pb_privacy_lists{
        active_type = ActiveType,
        lists = PbPrivacyLists
    }.


create_pb_chat_state(Type, ThreadId, ThreadType, FromUid) ->
    #pb_chat_state{
        type = Type,
        thread_id = ThreadId,
        thread_type = ThreadType,
        from_uid = FromUid
    }.


create_pb_chat_retract(Id) ->
    #pb_chat_retract{
        id = Id
    }.


create_pb_groupchat_retract(Id, Gid) ->
    #pb_group_chat_retract{
        id = Id,
        gid = Gid
    }.


create_pb_group_chat(Gid, Name, AvatarId, SenderUid, SenderName, Timestamp, Payload) ->
    #pb_group_chat{
        gid = Gid,
        name = Name,
        avatar_id = AvatarId,
        sender_uid = SenderUid,
        sender_name = SenderName,
        timestamp = Timestamp,
        payload = Payload
    }.


create_pb_chat_stanza(Timestamp, SenderName, Payload, EncPayload, PublicKey, OneTimeKeyId) ->
    create_pb_chat_stanza(Timestamp, SenderName, Payload, EncPayload, PublicKey, OneTimeKeyId, undefined, undefined).

create_pb_chat_stanza(Timestamp, SenderName, Payload, EncPayload, PublicKey, OneTimeKeyId, SenderLogInfo, SenderClientVersion) ->
    #pb_chat_stanza{
        timestamp = Timestamp,
        sender_name = SenderName,
        payload = Payload,
        enc_payload = EncPayload,
        public_key = PublicKey,
        one_time_pre_key_id = OneTimeKeyId,
        sender_log_info = SenderLogInfo,
        sender_client_version = SenderClientVersion
    }.


create_pb_contact(Action, Raw, Normalized, UserId, AvatarId, Name) ->
    #pb_contact{
        action = Action, 
        raw = Raw, 
        normalized = Normalized,
        uid = UserId, 
        avatar_id = AvatarId,
        name = Name
    }.


create_pb_contact_list(Type, SyncId, Index, Last, Contacts) ->
    #pb_contact_list{
        type = Type,
        sync_id = SyncId,
        batch_index = Index, 
        is_last = Last, 
        contacts = Contacts
    }.


create_pb_contact_hash(ContactHash) ->
    #pb_contact_hash{
        hash = ContactHash
    }.


create_pb_seen_receipt(Id, ThreadId, Timestamp) ->
    #pb_seen_receipt{
        id = Id,
        thread_id = ThreadId,
        timestamp = Timestamp
    }.


create_pb_delivery_receipt(Id, ThreadId, Timestamp) ->
    #pb_delivery_receipt{
        id = Id,
        thread_id = ThreadId,
        timestamp = Timestamp
    }.


create_pb_whisper_keys(Uid, Action, IdentityKey, SignedKey, OtpKeyCount, OneTimeKeys) ->
    #pb_whisper_keys{
        uid = Uid,
        action = Action,
        identity_key = IdentityKey,
        signed_key = SignedKey,
        otp_key_count = OtpKeyCount,
        one_time_keys = OneTimeKeys
    }.


create_pb_ack(Id, Timestamp) ->
    #pb_ack{
        id = Id,
        timestamp = Timestamp
    }.


create_pb_presence(Id, Type, Uid, ToUid, FromUid, LastSeen) ->
    #pb_presence{
        id = Id,
        type = Type,
        last_seen = LastSeen,
        uid = Uid,
        to_uid = ToUid,
        from_uid = FromUid
    }.

