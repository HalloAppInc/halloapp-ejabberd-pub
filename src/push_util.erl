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
-include("translate.hrl").

-export([
    parse_metadata/2,
    record_push_sent/2,
    get_push_type/3
]).

-spec parse_metadata(Message :: pb_msg(), PushInfo :: push_info()) -> push_metadata().
parse_metadata(#pb_msg{id = Id, payload = Payload,
        from_uid = FromUid}, PushInfo) when is_record(Payload, pb_chat_stanza) ->
    #push_metadata{
        content_id = Id,
        content_type = <<"chat">>,
        from_uid = FromUid,
        timestamp = Payload#pb_chat_stanza.timestamp,
        thread_id = FromUid,
        sender_name = Payload#pb_chat_stanza.sender_name,
        subject = Payload#pb_chat_stanza.sender_name,
        body = translate(<<"server.new.message">>, PushInfo#push_info.lang_id),
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
        from_uid = FromUid}, PushInfo) when is_record(Payload, pb_group_chat) ->
    PushName = Payload#pb_group_chat.sender_name,
    GroupName = Payload#pb_group_chat.name,
    #push_metadata{
        content_id = Id,
        content_type = <<"group_chat">>,
        from_uid = FromUid,
        timestamp = Payload#pb_group_chat.timestamp,
        thread_id = Payload#pb_group_chat.gid,
        thread_name = GroupName,
        sender_name = PushName,
        subject = <<PushName/binary, " @ ", GroupName/binary>>,
        body = translate(<<"server.new.group.message">>, PushInfo#push_info.lang_id),
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
            NewBody = translate(<<"server.new.contact">>, [Name], PushInfo#push_info.lang_id),
            {<<"contact_notice">>, <<>>, <<NewBody/binary>>};
        inviter_notice ->
            NewBody = translate(<<"server.new.inviter">>, [Name], PushInfo#push_info.lang_id),
            {<<"inviter_notice">>, <<>>, <<NewBody/binary>>};
        _ ->
            NewBody = translate(<<"server.new.contact">>, [Name], PushInfo#push_info.lang_id),
            {<<"contact_notification">>, <<>>, <<NewBody/binary>>}
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
        subject = Post#pb_post.publisher_name,
        body = translate(<<"server.new.post">>, PushInfo#push_info.lang_id),
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
        subject = Comment#pb_comment.publisher_name,
        body = translate(<<"server.new.comment">>, PushInfo#push_info.lang_id),
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
    PushName = Post#pb_post.publisher_name,
    GroupName = Payload#pb_group_feed_item.name,
    #push_metadata{
        content_id = Post#pb_post.id,
        content_type = <<"group_post">>,
        from_uid = Post#pb_post.publisher_uid,
        timestamp = Post#pb_post.timestamp,
        thread_id = Gid,
        thread_name = Payload#pb_group_feed_item.name,
        sender_name = Post#pb_post.publisher_name,
        subject = <<PushName/binary, " @ ", GroupName/binary>>,
        body = translate(<<"server.new.post">>, PushInfo#push_info.lang_id),
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
    PushName = Comment#pb_comment.publisher_name,
    GroupName = Payload#pb_group_feed_item.name,
    #push_metadata{
        content_id = Comment#pb_comment.id,
        content_type = <<"group_comment">>,
        from_uid = Comment#pb_comment.publisher_uid,
        timestamp = Comment#pb_comment.timestamp,
        thread_id = Gid,
        thread_name = Payload#pb_group_feed_item.name,
        sender_name = Comment#pb_comment.publisher_name,
        subject = <<PushName/binary, " @ ", GroupName/binary>>,
        body = translate(<<"server.new.comment">>, PushInfo#push_info.lang_id),
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

parse_metadata(#pb_msg{id = Id, type = MsgType, payload = #pb_group_stanza{gid = Gid, name = GroupName,
        sender_uid = Sender, sender_name = SenderName} = _Payload} = Message, PushInfo) ->
    PayloadType = util:get_payload_type(Message),
    #push_metadata{
        content_id = Id,
        content_type = <<"group_add">>,
        from_uid = Sender,
        timestamp = <<>>, % All other events have Ts. Maybe we should add Ts to group_st
        thread_id = Gid,
        thread_name = GroupName,
        sender_name = SenderName,
        subject = GroupName,
        body = translate(<<"server.new.group">>, PushInfo#push_info.lang_id),
        push_type = get_push_type(MsgType, PayloadType, PushInfo)
    };

parse_metadata(#pb_msg{id = Id, payload = #pb_rerequest{} = _Payload} = _Message, _PushInfo) ->
    #push_metadata{
        content_id = Id,
        content_type = <<"rerequest">>,
        push_type = silent
    };

parse_metadata(#pb_msg{id = Id, payload = #pb_group_feed_rerequest{} = _Payload} = _Message, _PushInfo) ->
    #push_metadata{
        content_id = Id,
        content_type = <<"group_feed_rerequest">>,
        push_type = silent
    };

parse_metadata(#pb_msg{id = Id, payload = #pb_home_feed_rerequest{} = _Payload} = _Message, _PushInfo) ->
    #push_metadata{
        content_id = Id,
        content_type = <<"home_feed_rerequest">>,
        push_type = silent
    };

parse_metadata(#pb_msg{id = Id, payload = #pb_group_feed_items{} = _Payload} = _Message, _PushInfo) ->
    #push_metadata{
        content_id = Id,
        content_type = <<"group_feed_items">>,
        push_type = silent
    };

parse_metadata(#pb_msg{id = Id, payload = #pb_feed_items{} = _Payload} = _Message, _PushInfo) ->
    #push_metadata{
        content_id = Id,
        content_type = <<"feed_items">>,
        push_type = silent
    };

parse_metadata(#pb_msg{id = Id, payload = #pb_request_logs{} = _Payload} = _Message, _PushInfo) ->
    #push_metadata{
        content_id = Id,
        content_type = <<"pb_request_logs">>,
        push_type = silent
    };

parse_metadata(#pb_msg{id = Id, payload = #pb_wake_up{} = _Payload} = _Message, 
        #push_info{} = _PushInfo) ->
    #push_metadata{
        content_id = Id,
        content_type = <<"sms_app_wakeup">>,
        push_type = silent
    };

parse_metadata(#pb_msg{id = Id, payload = #pb_incoming_call{call_id = CallId} = _Payload} = _Message,
        #push_info{} = _PushInfo) ->
    #push_metadata{
        content_id = <<CallId/binary, "-", Id/binary>>,
        content_type = <<"incoming_call">>,
        push_type = alert
    };

parse_metadata(#pb_msg{id = Id, payload = #pb_call_ringing{call_id = CallId} = _Payload} = _Message,
        #push_info{} = _PushInfo) ->
    #push_metadata{
        content_id = <<CallId/binary, "-", Id/binary>>,
        content_type = <<"call_ringing">>,
        push_type = silent
    };

parse_metadata(#pb_msg{id = Id, payload = #pb_answer_call{call_id = CallId} = _Payload} = _Message,
        #push_info{} = _PushInfo) ->
    #push_metadata{
        content_id = <<CallId/binary, "-", Id/binary>>,
        content_type = <<"answer_call">>,
        push_type = silent
    };

parse_metadata(#pb_msg{id = Id, payload = #pb_end_call{call_id = CallId} = _Payload} = _Message,
        #push_info{} = _PushInfo) ->
    #push_metadata{
        content_id = <<CallId/binary, "-", Id/binary>>,
        content_type = <<"end_call">>,
        push_type = silent
    };

parse_metadata(#pb_msg{id = Id, payload = #pb_ice_candidate{call_id = CallId} = _Payload} = _Message,
        #push_info{} = _PushInfo) ->
    #push_metadata{
        content_id = <<CallId/binary, "-", Id/binary>>,
        content_type = <<"ice_candidate">>,
        push_type = silent
    };

parse_metadata(#pb_msg{id = Id, payload = #pb_marketing_alert{}} = _Message, #push_info{} = PushInfo) ->
    #push_metadata{
        content_id = Id,
        content_type = <<"marketing_alert">>,
        subject = translate(<<"server.marketing.title">>, PushInfo#push_info.lang_id),
        body = translate(<<"server.marketing.body">>, PushInfo#push_info.lang_id),
        push_type = direct_alert
    };

parse_metadata(#pb_msg{to_uid = Uid, id = Id}, _PushInfo) ->
    ?ERROR("Uid: ~s, Invalid message for push notification: id: ~s", [Uid, Id]),
    #push_metadata{}.


%% Adding a special case to be able to send all alert and silent notifications for contact_list
%% updates. If we use the content_id which is the phone number in this case: we will not be sending
%% other pushes for these messages.
-spec record_push_sent(Message :: pb_msg(), PushInfo :: push_info()) -> boolean().
record_push_sent(#pb_msg{rerequest_count = RerequestCount}, _PushInfo) when RerequestCount > 0 ->
    %% Always send push notifications for rerequested messages.
    %% These are messages with some content: so we need to let the user know.
    true;
record_push_sent(#pb_msg{id = MsgId, to_uid = UserId, payload = Payload}, _PushInfo)
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
    model_messages:record_push_sent(UserId, PushId).


-spec translate(Token :: binary(), LangId :: binary()) -> binary().
translate(Token, LangId) ->
    translate(Token, [], LangId).

-spec translate(Token :: binary(), Args :: [binary()], LangId :: binary()) -> binary().
translate(Token, Args, LangId) ->
    {Translation, _ResultLangId} = mod_translate:translate(Token, Args, LangId),
    Translation.


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
get_push_type(_MsgType, pb_rerequest, _PushInfo) -> silent;
get_push_type(_MsgType, pb_group_feed_rerequest, _PushInfo) -> silent;
get_push_type(_MsgType, pb_home_feed_rerequest, _PushInfo) -> silent;
get_push_type(_MsgType, _PayloadType, _PushInfo) -> silent.

