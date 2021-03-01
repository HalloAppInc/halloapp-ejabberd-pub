%%%----------------------------------------------------------------------
%%% File    : push_util.erl
%%%
%%% Copyright (C) 2020 halloappinc.
%%%
%%% This module handles all the utility functions related to push notifications.
%%%----------------------------------------------------------------------

-module(push_util).
-author('murali').
-include("logger.hrl").
-include("xmpp.hrl").
-include("packets.hrl").
-include ("push_message.hrl").

-export([
    parse_metadata/2,
    record_push_sent/1,
    get_push_type/3
]).

-spec parse_metadata(Message :: pb_msg(), PushInfo :: push_info()) -> push_metadata().
parse_metadata(#pb_msg{id = Id, payload = Payload,
        from_uid = FromUid}, _PushInfo) when is_record(Payload, pb_chat_stanza) ->
    #push_metadata{
        content_id = Id,
        content_type = <<"chat">>,
        from_uid = FromUid,
        timestamp = Payload#pb_chat_stanza.timestamp,
        thread_id = FromUid,
        sender_name = Payload#pb_chat_stanza.sender_name,
        subject = <<"New Message">>,
        body = <<"You got a new message.">>,
        push_type = alert
    };

parse_metadata(#pb_msg{id = Id, payload = Payload,
        from_uid = FromUid}, _PushInfo) when is_record(Payload, pb_group_chat) ->
    #push_metadata{
        content_id = Id,
        content_type = <<"group_chat">>,
        from_uid = FromUid,
        timestamp = Payload#pb_group_chat.timestamp,
        thread_id = Payload#pb_group_chat.gid,
        thread_name = Payload#pb_group_chat.name,
        sender_name = Payload#pb_group_chat.sender_name,
        subject = <<"New Group Message">>,
        body = <<"You got a new group message.">>,
        push_type = alert
    };

%% TODO(murali@): this is not great, we need to send the entire message.
%% Let the client extract whatever they need.
parse_metadata(#pb_msg{id = Id, payload = Payload}, _PushInfo)
        when is_record(Payload, pb_contact_hash) ->
    #push_metadata{
        content_id = Id,
        content_type = <<"contact_notification">>,
        from_uid = <<>>,
        timestamp = <<>>,
        thread_id = <<>>,
        thread_name = <<>>,
        subject = <<>>,
        body = <<>>,
        push_type = silent
    };

parse_metadata(#pb_msg{id = _Id, type = MsgType, payload = Payload} = Message, PushInfo)
        when is_record(Payload, pb_contact_list) ->
    [Contact | _] = Payload#pb_contact_list.contacts,
    Name = Contact#pb_contact.name,
    {Subject, Body} = case Payload#pb_contact_list.type of
        friend_notice ->
            {<<"New Friend">>, <<"Your friend ", Name/binary, " is now on halloapp">>};
        inviter_notice ->
            {<<"Invite Accepted">>, <<Name/binary, " just accepted your invite to join HalloApp">>};
        normal ->
            {<<"New Contact">>, <<"New contact notification">>}
    end,
    NewMsgType = {MsgType, Payload#pb_contact_list.type},
    PayloadType = util:get_payload_type(Message),
    #push_metadata{
        content_id = Contact#pb_contact.normalized,
        content_type = <<"contact_notification">>,
        from_uid = Contact#pb_contact.uid,
        timestamp = <<>>,
        thread_id = Contact#pb_contact.normalized,
        thread_name = Contact#pb_contact.name,
        subject = Subject,
        body = Body,
        push_type = get_push_type(NewMsgType, PayloadType, PushInfo)
    };

parse_metadata(#pb_msg{type = MsgType,
        payload = #pb_feed_item{item = #pb_post{} = Post}} = _Message, PushInfo) ->
    #push_metadata{
        content_id = Post#pb_post.id,
        content_type = <<"feedpost">>,
        from_uid = Post#pb_post.publisher_uid,
        timestamp = Post#pb_post.timestamp,
        thread_id = <<"feed">>,
        sender_name = Post#pb_post.publisher_name,
        subject = <<"New Notification">>,
        body = <<"New post">>,
        push_type = get_push_type(MsgType, feed_post, PushInfo)
    };

parse_metadata(#pb_msg{type = MsgType,
        payload = #pb_feed_item{item = #pb_comment{} = Comment}} = _Message, PushInfo) ->
    #push_metadata{
        content_id = Comment#pb_comment.id,
        content_type = <<"comment">>,
        from_uid = Comment#pb_comment.publisher_uid,
        timestamp = Comment#pb_comment.timestamp,
        thread_id = <<"feed">>,
        sender_name = Comment#pb_comment.publisher_name,
        subject = <<"New Notification">>,
        body = <<"New comment">>,
        push_type = get_push_type(MsgType, feed_comment, PushInfo)
    };

parse_metadata(#pb_msg{type = MsgType, payload = #pb_group_feed_item{gid = Gid,
        item = #pb_post{} = Post} = Payload} = Message, PushInfo) ->
    PayloadType = util:get_payload_type(Message),
    #push_metadata{
        content_id = Post#pb_post.id,
        content_type = <<"group_post">>,
        from_uid = Post#pb_post.publisher_uid,
        timestamp = Post#pb_post.timestamp,
        thread_id = Gid,
        thread_name = Payload#pb_group_feed_item.name,
        sender_name = Post#pb_post.publisher_name,
        subject = <<"New Group Message">>,
        body = <<"New post">>,
        push_type = get_push_type(MsgType, PayloadType, PushInfo)
    };

parse_metadata(#pb_msg{type = MsgType, payload = #pb_group_feed_item{gid = Gid,
        item = #pb_comment{} = Comment} = Payload} = Message, PushInfo) ->
    PayloadType = util:get_payload_type(Message),
    #push_metadata{
        content_id = Comment#pb_comment.id,
        content_type = <<"group_comment">>,
        from_uid = Comment#pb_comment.publisher_uid,
        timestamp = Comment#pb_comment.timestamp,
        thread_id = Gid,
        thread_name = Payload#pb_group_feed_item.name,
        sender_name = Comment#pb_comment.publisher_name,
        subject = <<"New Group Message">>,
        body = <<"New comment">>,
        push_type = get_push_type(MsgType, PayloadType, PushInfo)
    };

parse_metadata(#pb_msg{id = Id, type = MsgType, payload = #pb_group_stanza{gid = Gid, name = Name,
        sender_uid = Sender, sender_name = SenderName} = _Payload} = Message, PushInfo) ->
    PayloadType = util:get_payload_type(Message),
    #push_metadata{
        content_id = Id,
        content_type = <<"group_add">>,
        from_uid = Sender,
        timestamp = <<>>, % All other events have Ts. Maybe we should add Ts to group_st
        thread_id = Gid,
        thread_name = Name,
        sender_name = SenderName,
        subject = <<"New Group">>,
        body = <<"You got added to new group">>,
        push_type = get_push_type(MsgType, PayloadType, PushInfo)
    };

parse_metadata(#pb_msg{to_uid = Uid, id = Id}, _PushInfo) ->
    ?ERROR("Uid: ~s, Invalid message for push notification: id: ~s", [Uid, Id]),
    #push_metadata{}.


%% Adding a special case to be able to send all alert and silent notifications for contact_list
%% updates. If we use the content_id which is the phone number in this case: we will not be sending
%% other pushes for these messages.
-spec record_push_sent(Message :: message()) -> boolean().
record_push_sent(#pb_msg{id = MsgId, to_uid = UserId, payload = Payload})
        when is_record(Payload, pb_contact_list) ->
    model_messages:record_push_sent(UserId, MsgId);
record_push_sent(Message) ->
    %% We parse again for content_id only, so its okay to ignore push_info here.
    %% TODO(murali@): However, it is not clean: that we are parsing this again.
    PushMetadata = parse_metadata(Message, undefined),
    ContentId = PushMetadata#push_metadata.content_id,
    UserId = Message#pb_msg.to_uid,
    model_messages:record_push_sent(UserId, ContentId).


-spec get_push_type(MsgType :: message_type(),
        PayloadType :: atom(), PushInfo :: push_info()) -> silent | alert.
get_push_type(groupchat, group_chat, _PushInfo) -> alert;
get_push_type(_MsgType, chat, _PushInfo) -> alert;
get_push_type(groupchat, group_st, _PushInfo) -> alert;
get_push_type(headline, group_feed_st, _PushInfo) -> alert;
get_push_type(normal, group_feed_st, _PushInfo) -> silent;
get_push_type(headline, feed_post, #push_info{post_pref = true}) -> alert;
get_push_type(headline, feed_comment, #push_info{comment_pref = true}) -> alert;
get_push_type({headline, _}, contact_list, _PushInfo) -> alert;
get_push_type({_, friend_notice}, contact_list, _PushInfo) -> alert;
get_push_type({_, inviter_notice}, contact_list, _PushInfo) -> alert;
get_push_type(_MsgType, _PayloadType, _PushInfo) -> silent.

