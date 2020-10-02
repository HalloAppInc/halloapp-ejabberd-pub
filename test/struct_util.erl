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


create_post_st(Id, Uid, Payload, Timestamp) ->
    #post_st{
        id = Id,
        uid = Uid,
        payload = Payload,
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
    #jid{
        user = Uid,
        server = Server
    }.


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


create_group_feed_st(Action, Gid, Name, AvatarId, Post, Comment) ->
    #group_feed_st{
        action = Action,
        gid = Gid,
        name = Name,
        avatar_id = AvatarId,
        post = Post,
        comment = Comment
    }.


create_group_feed_item(Action, Gid, Name, AvatarId, Item) ->
    #pb_group_feed_item{
        action = Action,
        gid = Gid,
        name = Name,
        avatar_id = AvatarId,
        item = Item
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


create_pb_privacy_list_result(Result, Reason, Hash) ->
    #pb_privacy_list_result{
        result = Result,
        reason = Reason,
        hash = Hash
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


