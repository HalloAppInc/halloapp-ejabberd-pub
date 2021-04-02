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
-include("packets.hrl").
-include ("push_message.hrl").

-export([
    parse_metadata/2,
    record_push_sent/2,
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
        push_type = alert,
        payload = Payload#pb_chat_stanza.payload
    };

parse_metadata(#pb_msg{id = _Id, payload = Payload,
        from_uid = FromUid}, _PushInfo) when is_record(Payload, pb_chat_retract) ->
    #push_metadata{
        content_id = Payload#pb_chat_retract.id,
        content_type = <<"chat_retract">>,
        from_uid = FromUid,
        thread_id = FromUid,
        push_type = silent,
        retract = true
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
        push_type = alert,
        payload = Payload#pb_group_chat.payload
    };

parse_metadata(#pb_msg{id = _Id, payload = Payload,
        from_uid = FromUid}, _PushInfo) when is_record(Payload, pb_group_chat_retract) ->
    #push_metadata{
        content_id = Payload#pb_group_chat_retract.id,
        content_type = <<"group_chat_retract">>,
        from_uid = FromUid,
        thread_id = Payload#pb_group_chat_retract.gid,
        push_type = silent,
        retract = true
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
    {ContentType, Subject, Body} = case Payload#pb_contact_list.type of
        contact_notice ->
            {<<"contact_notice">>, <<"New Contact">>, <<Name/binary, " is now on HalloApp">>};
        inviter_notice ->
            {<<"inviter_notice">>, <<"Invite Accepted">>, <<Name/binary, " just accepted your invite to join HalloApp">>};
        _ ->
            {<<"contact_notification">>, <<"New Contact">>, <<"New contact notification">>}
    end,
    NewMsgType = {MsgType, Payload#pb_contact_list.type},
    PayloadType = util:get_payload_type(Message),
    #push_metadata{
        content_id = Contact#pb_contact.normalized,
        content_type = ContentType,
        from_uid = Contact#pb_contact.uid,
        timestamp = <<>>,
        thread_id = Contact#pb_contact.normalized,
        thread_name = Contact#pb_contact.name,
        subject = Subject,
        body = Body,
        push_type = get_push_type(NewMsgType, PayloadType, PushInfo)
    };

parse_metadata(#pb_msg{type = MsgType,
        payload = #pb_feed_item{action = publish, item = #pb_post{} = Post}}, PushInfo) ->
    #push_metadata{
        content_id = Post#pb_post.id,
        content_type = <<"feedpost">>,
        from_uid = Post#pb_post.publisher_uid,
        timestamp = Post#pb_post.timestamp,
        thread_id = <<"feed">>,
        sender_name = Post#pb_post.publisher_name,
        subject = <<"New Notification">>,
        body = <<"New post">>,
        push_type = get_push_type(MsgType, feed_post, PushInfo),
        payload = Post#pb_post.payload
    };

parse_metadata(#pb_msg{
        payload = #pb_feed_item{action = retract, item = #pb_post{} = Post}}, _PushInfo) ->
    #push_metadata{
        content_id = Post#pb_post.id,
        content_type = <<"feedpost_retract">>,
        from_uid = Post#pb_post.publisher_uid,
        thread_id = <<"feed">>,
        push_type = silent,
        retract = true
    };

parse_metadata(#pb_msg{type = MsgType,
        payload = #pb_feed_item{action = publish, item = #pb_comment{} = Comment}}, PushInfo) ->
    #push_metadata{
        content_id = Comment#pb_comment.id,
        content_type = <<"comment">>,
        from_uid = Comment#pb_comment.publisher_uid,
        timestamp = Comment#pb_comment.timestamp,
        thread_id = <<"feed">>,
        sender_name = Comment#pb_comment.publisher_name,
        subject = <<"New Notification">>,
        body = <<"New comment">>,
        push_type = get_push_type(MsgType, feed_comment, PushInfo),
        payload = Comment#pb_comment.payload
    };

parse_metadata(#pb_msg{
        payload = #pb_feed_item{action = retract, item = #pb_comment{} = Comment}}, _PushInfo) ->
    #push_metadata{
        content_id = Comment#pb_comment.id,
        content_type = <<"comment_retract">>,
        from_uid = Comment#pb_comment.publisher_uid,
        thread_id = <<"feed">>,
        push_type = silent,
        retract = true
    };

parse_metadata(#pb_msg{type = MsgType, payload = #pb_group_feed_item{gid = Gid, action = publish,
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
        push_type = get_push_type(MsgType, PayloadType, PushInfo),
        payload = Post#pb_post.payload
    };

parse_metadata(#pb_msg{payload = #pb_group_feed_item{gid = Gid, action = retract,
        item = #pb_post{} = Post} = _Payload} = _Message, _PushInfo) ->
    #push_metadata{
        content_id = Post#pb_post.id,
        content_type = <<"group_post_retract">>,
        from_uid = Post#pb_post.publisher_uid,
        thread_id = Gid,
        push_type = silent,
        retract = true
    };

parse_metadata(#pb_msg{type = MsgType, payload = #pb_group_feed_item{gid = Gid, action = publish,
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
        push_type = get_push_type(MsgType, PayloadType, PushInfo),
        payload = Comment#pb_comment.payload
    };

parse_metadata(#pb_msg{payload = #pb_group_feed_item{gid = Gid, action = retract,
        item = #pb_comment{} = Comment} = _Payload} = _Message, _PushInfo) ->
    #push_metadata{
        content_id = Comment#pb_comment.id,
        content_type = <<"group_comment_retract">>,
        from_uid = Comment#pb_comment.publisher_uid,
        thread_id = Gid,
        push_type = silent,
        retract = true
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
-spec record_push_sent(Message :: pb_msg(), PushInfo :: push_info()) -> boolean().
record_push_sent(#pb_msg{id = MsgId, to_uid = UserId, payload = Payload}, PushInfo)
        when is_record(Payload, pb_contact_list) ->
    model_messages:record_push_sent(UserId, MsgId);
record_push_sent(Message, PushInfo) ->
    %% We parse again for content_id only, so its okay to ignore push_info here.
    %% TODO(murali@): However, it is not clean: that we are parsing this again.
    PushMetadata = parse_metadata(Message, PushInfo),
    ContentId = PushMetadata#push_metadata.content_id,
    PushTypeBin = util:to_binary(PushMetadata#push_metadata.push_type),
    PushId = <<ContentId/binary, PushTypeBin/binary>>,
    UserId = Message#pb_msg.to_uid,
    model_messages:record_push_sent(UserId, ContentId).


-spec get_push_type(MsgType :: atom(),
        PayloadType :: atom(), PushInfo :: push_info()) -> silent | alert.
get_push_type(groupchat, pb_group_chat, _PushInfo) -> alert;
get_push_type(_MsgType, pb_chat_stanza, _PushInfo) -> alert;
get_push_type(groupchat, pb_group_stanza, _PushInfo) -> alert;
get_push_type(headline, pb_group_feed_item, _PushInfo) -> alert;
get_push_type(normal, pb_group_feed_item, _PushInfo) -> silent;
get_push_type(headline, feed_post, #push_info{post_pref = true}) -> alert;
get_push_type(headline, feed_comment, #push_info{comment_pref = true}) -> alert;
get_push_type({headline, _}, pb_contact_list, _PushInfo) -> alert;
get_push_type({_, contact_notice}, pb_contact_list, _PushInfo) -> alert;
get_push_type({_, inviter_notice}, pb_contact_list, _PushInfo) -> alert;
get_push_type(_MsgType, _PayloadType, _PushInfo) -> silent.

