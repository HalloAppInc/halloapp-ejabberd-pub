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


create_post_st(Id, Uid, PublisherName, Payload, Timestamp) ->
    #post_st{
        id = Id,
        uid = Uid,
        payload = Payload,
        publisher_name = PublisherName,
        timestamp = Timestamp
    }.


create_comment_st(Id, PostId, ParentCommentId, PublisherUid, PublisherName, Payload, Timestamp) ->
    #comment_st{
        id = Id,
        post_id = PostId,
        parent_comment_id = ParentCommentId,
        publisher_uid = PublisherUid,
        publisher_name = PublisherName,
        payload = Payload,
        timestamp = Timestamp
    }.


create_audience_list(Type, Uids) ->
    UidEls = lists:map(fun(Uid) -> #uid_element{uid = Uid} end, Uids),
    #audience_list_st{
        type = Type,
        uids = UidEls
    }.


create_share_posts_st(Uid, Posts, Result, Reason) ->
    #share_posts_st{
        uid = Uid,
        posts = Posts,
        result = Result,
        reason = Reason
    }.


create_feed_st(Action, Posts, Comments, AudienceList, SharePosts) ->
    #feed_st{
        action = Action,
        posts = Posts,
        comments = Comments,
        audience_list = AudienceList,
        share_posts = SharePosts
    }.


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


create_jid(Uid, Server) ->
    jid:make(Uid, Server).


create_message_stanza(Id, ToJid, FromJid, Type, SubEl) ->
    #message{
        id = Id,
        to = ToJid,
        from = FromJid,
        type = Type,
        sub_els = [SubEl]
    }.


create_pb_message(Id, ToUid, FromUid, Type, PayloadContent) ->
    #pb_msg{
        id = Id,
        to_uid = ToUid,
        from_uid = FromUid,
        type = Type,
        payload = PayloadContent
    }.


create_iq_stanza(Id, ToJid, FromJid, Type, SubEls) when is_list(SubEls) ->
    #iq{
        id = Id,
        to = ToJid,
        from = FromJid,
        type = Type,
        sub_els = SubEls
    };
create_iq_stanza(Id, ToJid, FromJid, Type, SubEl) ->
    #iq{
        id = Id,
        to = ToJid,
        from = FromJid,
        type = Type,
        sub_els = [SubEl]
    }.


create_pb_iq(Id, Type, PayloadContent) ->
    #pb_iq{
        id = Id,
        type = Type,
        payload = PayloadContent
    }.


create_group_avatar(Gid, Cdata) ->
    #group_avatar{
        gid = Gid,
        cdata = Cdata
    }.


create_pb_upload_group_avatar(Gid, Data) ->
    #pb_upload_group_avatar{
        gid = Gid,
        data = Data
    }.


create_group_post_st(Id, PublisherUid, PublisherName, Payload, Timestamp) ->
    #group_post_st{
        id = Id,
        publisher_uid = PublisherUid,
        publisher_name = PublisherName,
        payload = Payload,
        timestamp = Timestamp
    }.


create_group_comment_st(Id, PostId, ParentCommentId, PublisherUid, PublisherName, Payload, Timestamp) ->
    #group_comment_st{
        id = Id,
        post_id = PostId,
        parent_comment_id = ParentCommentId,
        publisher_uid = PublisherUid,
        publisher_name = PublisherName,
        payload = Payload,
        timestamp = Timestamp
    }.


create_group_feed_st(Action, Gid, Name, AvatarId, Posts, Comments) ->
    #group_feed_st{
        action = Action,
        gid = Gid,
        name = Name,
        avatar_id = AvatarId,
        posts = Posts,
        comments = Comments
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


create_member_st(Action, Uid, Type, Name, AvatarId, Result, Reason) ->
    #member_st{
        action = Action,
        uid = Uid,
        type = Type,
        name = Name,
        avatar = AvatarId,
        result = Result,
        reason = Reason
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


create_group_chat(Gid, Name, AvatarId, SenderUid, SenderName, Timestamp, Payload) ->
    #group_chat{
        xmlns = <<"halloapp:groups">>,
        gid = Gid,
        name = Name,
        avatar = AvatarId,
        sender = SenderUid,
        sender_name = SenderName,
        timestamp = Timestamp,
        sub_els = [{xmlel,<<"s1">>,[],[{xmlcdata, Payload}]}]
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


create_groups_st(Action, Groups) ->
    #groups{
        action = Action,
        groups = Groups
    }.


create_pb_groups_stanza(Action, GroupsStanza) ->
    #pb_groups_stanza{
        action = Action,
        group_stanzas = GroupsStanza
    }.


create_invite(Phone, Result, Reason) ->
    #invite{
        phone = Phone,
        result = Result,
        reason = Reason
    }.


create_invites(InvitesLeft, TimeUnitRefresh, Invites) ->
    #invites{
        invites_left = InvitesLeft,
        time_until_refresh = TimeUnitRefresh,
        invites = Invites
    }.


create_pb_invite(Phone, Result, Reason) ->
    #pb_invite{
        phone = Phone,
        result = Result,
        reason = Reason
    }.

create_pb_invites_request(PbInvites) ->
    #pb_invites_request{
        invites = PbInvites
    }.

create_pb_invites_response(InvitesLeft, TimeUnitRefresh, PbInvites) ->
    #pb_invites_response{
        invites_left = InvitesLeft,
        time_until_refresh = TimeUnitRefresh,
        invites = PbInvites
    }.

create_name_st(Uid, Name) ->
    #name{
        uid = Uid,
        name = Name
    }.


create_pb_name(Uid, Name) ->
    #pb_name{
        uid = Uid,
        name = Name
    }.


create_uid_el(Type, Uid) ->
    #uid_el{
        type = Type,
        uid = Uid
    }.


create_user_privacy_list(Type, Hash, UidEls) ->
    #user_privacy_list {
        type = Type,
        hash = Hash,
        uid_els = UidEls
    }.


create_user_privacy_lists(ActiveType, Lists) ->
    #user_privacy_lists{
        active_type = ActiveType,
        lists = Lists
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


create_pb_error_stanza(Reason, Hash) ->
    #pb_error_stanza{
        reason = Reason
    }.


create_error_st(Reason, Hash) ->
    #error_st{
        reason = Reason,
        hash = Hash
    }.


create_prop(Name, Value) ->
    #prop{
        name = Name,
        value = Value
    }.


create_pb_prop(Name, Value) ->
    #pb_prop{
        name = Name,
        value = Value
    }.


create_props(Hash, Props) ->
    #props{
        hash = Hash,
        props = Props
    }.


create_pb_props(Hash, Props) ->
    #pb_props{
        hash = Hash,
        props = Props
    }.


create_push_register(Os, Token) ->
    #push_register{
        push_token = {Os, Token}
    }.

create_pb_push_register(Os, Token) ->
    #pb_push_register{
        push_token = #pb_push_token{
            os = Os,
            token = Token
        }
    }.

create_push_pref(Name, Value) ->
    #push_pref{
        name = Name,
        value = Value
    }.

create_pb_push_pref(Name, Value) ->
    #pb_push_pref{
        name = Name,
        value = Value
    }.


create_notification_prefs(PushPrefs) ->
    #notification_prefs{
        push_prefs = PushPrefs
    }.


create_pb_notification_prefs(PushPrefs) ->
    #pb_notification_prefs{
        push_prefs = PushPrefs
    }.


create_chat_state(ToJid, FromJid, Type, ThreadId, ThreadType) ->
    #chat_state{
        to = ToJid,
        from = FromJid,
        type = Type,
        thread_id = ThreadId,
        thread_type = ThreadType
    }.


create_pb_chat_state(Type, ThreadId, ThreadType, FromUid) ->
    #pb_chat_state{
        type = Type,
        thread_id = ThreadId,
        thread_type = ThreadType,
        from_uid = FromUid
    }.


create_chat_retract_st(Id) ->
    #chat_retract_st{
        id = Id
    }.


create_groupchat_retract_st(Id, Gid) ->
    #groupchat_retract_st{
        id = Id,
        gid = Gid
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


create_error_st(Reason) ->
    util:err(Reason).


create_stanza_error(Reason) ->
    #stanza_error{reason = Reason}.


create_pb_error(Reason) ->
    #pb_error_stanza{
        reason = Reason
    }.


create_dim_st(Name, Value) ->
    #dim_st{
        name = Name,
        value = Value
    }.

create_count_st(Namespace, Metric, Count, Dims) ->
    #count_st{
        namespace = Namespace,
        metric = Metric,
        count = Count,
        dims = Dims
    }.


create_event_st(Namespace, Event) ->
    #event_st{
        namespace = Namespace,
        event = Event
    }.

create_client_log_st(Counts, Events) ->
    #client_log_st{
        counts = Counts,
        events = Events
    }.


create_pb_dim(Name, Value) ->
    #pb_dim{
        name = Name,
        value = Value
    }.

create_pb_count(Namespace, Metric, Count, Dims) ->
    #pb_count{
        namespace = Namespace,
        metric = Metric,
        count = Count,
        dims = Dims
    }.


create_pb_event_data(Uid, Platform, Version, Edata) ->
    #pb_event_data{
        uid = Uid,
        platform = Platform,
        version = Version,
        edata = Edata
    }.


create_pb_client_log(Counts, Events) ->
    #pb_client_log{
        counts = Counts,
        events = Events
    }.


create_pb_avatar(Id, Uid) ->
    #pb_avatar{
        id = Id,
        uid = Uid
    }.


create_s1_xmlel(Data) ->
    {xmlel,<<"s1">>,[],[{xmlcdata, Data}]}.


create_enc_xmlel(Data, IdentityKey, OneTimeKeyId) ->
    {xmlel,<<"enc">>,
        [{<<"identity_key">>, IdentityKey},
        {<<"one_time_pre_key_id">>,OneTimeKeyId}],
        [{xmlcdata,Data}]
    }.


create_chat_stanza(Timestamp, SenderName, SubEls) ->
    create_chat_stanza(Timestamp, SenderName, SubEls, undefined, undefined).


create_chat_stanza(Timestamp, SenderName, SubEls, SenderLogInfo, SenderClientVersion) ->
    #chat{
        xmlns = <<"halloapp:chat:messages">>,
        timestamp = Timestamp,
        sender_name = SenderName,
        sub_els = SubEls,
        sender_log_info = SenderLogInfo,
        sender_client_version = SenderClientVersion
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


create_contact(Type, Raw, Normalized, UserId, AvatarId, Name, Role) ->
    #contact{
        type = Type, 
        raw = Raw, 
        normalized = Normalized,
        userid = UserId, 
        avatarid = AvatarId,
        name = Name,
        role = Role
    }.

create_pb_contact(Action, Raw, Normalized, UserId, AvatarId, Name, Role) ->
    #pb_contact{
        action = Action, 
        raw = Raw, 
        normalized = Normalized,
        uid = UserId, 
        avatar_id = AvatarId,
        name = Name,
        role = Role
    }.


create_contact_list(Type, SyncId, Index, Last, Contacts, ContactHash) ->
    #contact_list{
        xmlns = <<"halloapp:user:contacts">>,
        type = Type,
        syncid = SyncId,
        index = Index, 
        last = Last, 
        contacts = Contacts,
        contact_hash = ContactHash
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


create_seen_receipt(Id, ThreadId, Timestamp) ->
    #receipt_seen{
        id = Id,
        thread_id = ThreadId,
        timestamp = Timestamp
    }.


create_pb_seen_receipt(Id, ThreadId, Timestamp) ->
    #pb_seen_receipt{
        id = Id,
        thread_id = ThreadId,
        timestamp = Timestamp
    }.


create_delivery_receipt(Id, ThreadId, Timestamp) ->
    #receipt_response{
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


create_whisper_keys(Uid, Type, IdentityKey, SignedKey, OtpKeyCount, OneTimeKeys) ->
    #whisper_keys{
        uid = Uid,
        type = Type,
        identity_key = IdentityKey,
        signed_key = SignedKey,
        otp_key_count = OtpKeyCount,
        one_time_keys = OneTimeKeys
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


create_ping() ->
    #ping{}.

create_pb_ping() ->
    #pb_ping{}.


create_media_url(Get, Put, Patch) ->
    #media_urls{
        get = Get,
        put = Put,
        patch = Patch
    }.


create_pb_media_url(Get, Put, Patch) ->
    #pb_media_url{
        get = Get,
        put = Put,
        patch = Patch
    }.

create_upload_media(Size, MediaUrls) ->
    #upload_media{
        size = Size,
        media_urls = MediaUrls
    }.


create_pb_upload_media(Size, Url) ->
    #pb_upload_media{
        size = Size,
        url = Url
    }.


create_avatar(Id, UserId, Data) ->
    #avatar{
        id = Id,
        userid = UserId,
        cdata = Data
    }.


create_avatars(Avatars) ->
    #avatars{
        avatars = Avatars
    }.


create_pb_upload_avatar(Id, Data) ->
    #pb_upload_avatar{
        id = Id,
        data = Data
    }.

create_pb_avatars(PbAvatars) ->
    #pb_avatars{
        avatars = PbAvatars
    }.


create_ack(Id, ToJid, FromJid, Timestamp) ->
    #ack{
        id = Id,
        to = ToJid,
        from = FromJid,
        timestamp = Timestamp
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


create_presence(Id, Type, ToJid, FromJid, LastSeen) ->
    #presence{
        id = Id,
        type = Type,
        from = FromJid,
        to = ToJid,
        last_seen = LastSeen
    }.


create_client_mode(Mode) ->
    #client_mode{
        mode = Mode
    }.


create_pb_client_mode(Mode) ->
    #pb_client_mode{
        mode = Mode
    }.


create_client_version(Version, SecondsLeft) ->
    #client_version{
        version = Version,
        seconds_left = SecondsLeft
    }.


create_pb_client_version(Version, SecondsLeft) ->
    #pb_client_version{
        version = Version,
        expires_in_seconds = SecondsLeft
    }.


create_auth_request(Uid, Password, ClientMode, ClientVersion, Resource) ->
    #halloapp_auth{
        uid = Uid,
        pwd = Password,
        client_mode = ClientMode,
        client_version = ClientVersion,
        resource = Resource
    }.


create_pb_auth_request(Uid, Password, PbClientMode, PbClientVersion, Resource) ->
    #pb_auth_request{
        uid = Uid,
        pwd = Password,
        client_mode = PbClientMode,
        client_version = PbClientVersion,
        resource = Resource
    }.


create_auth_result(Result, Reason, PropsHash) ->
    #halloapp_auth_result{
        result = Result,
        reason = Reason,
        props_hash = PropsHash
    }.


create_pb_auth_result(Result, Reason, PropsHash) ->
    #pb_auth_result{
        result_string = Result,
        reason_string = Reason,
        props_hash = PropsHash
    }.


create_rerequest_st(Id, IdentityKey) ->
    #rerequest_st{
        id = Id,
        identity_key = IdentityKey
    }.


create_pb_rerequest(Id, IdentityKey) ->
    #pb_rerequest{
        id = Id,
        identity_key = IdentityKey,
        signed_pre_key_id = undefined,
        one_time_pre_key_id = undefined
    }.


create_silent_chat(Chat) ->
    #silent_chat{
        chat = Chat
    }.

create_pb_silent_chat_stanza(ChatStanza) ->
    #pb_silent_chat_stanza{
        chat_stanza = ChatStanza
    }.

