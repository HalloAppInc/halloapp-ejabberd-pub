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
-include ("push_message.hrl").

-export([
    parse_metadata/1,
    record_push_sent/1
]).


-spec parse_metadata(Message :: message()) -> {binary(), binary(), binary(), binary()}.
parse_metadata(#message{id = Id, sub_els = [SubElement],
        from = #jid{luser = FromUid}}) when is_record(SubElement, chat) ->
    #push_metadata{
        content_id = Id,
        content_type = <<"chat">>,
        from_uid = FromUid,
        timestamp = SubElement#chat.timestamp,
        thread_id = FromUid,
        sender_name = SubElement#chat.sender_name
    };

parse_metadata(#message{id = Id, sub_els = [SubElement],
        from = #jid{luser = FromUid}}) when is_record(SubElement, group_chat) ->
    #push_metadata{
        content_id = Id,
        content_type = <<"group_chat">>,
        from_uid = FromUid,
        timestamp = SubElement#group_chat.timestamp,
        thread_id = SubElement#group_chat.gid,
        thread_name = SubElement#group_chat.name,
        sender_name = SubElement#group_chat.sender_name
    };

%% TODO(murali@): this is not great, we need to send the entire message.
%% Let the client extract whatever they need.
parse_metadata(#message{id = Id, sub_els = [SubElement]})
        when is_record(SubElement, contact_list), SubElement#contact_list.contacts =:= [] ->
    #push_metadata{
        content_id = Id,
        content_type = <<"contact_notification">>,
        from_uid = <<>>,
        timestamp = <<>>,
        thread_id = <<>>,
        thread_name = <<>>
    };

parse_metadata(#message{id = Id, sub_els = [SubElement]})
        when is_record(SubElement, contact_list), SubElement#contact_list.contacts =/= [] ->
    [Contact | _] = SubElement#contact_list.contacts,
    #push_metadata{
        content_id = Id,
        content_type = <<"contact_notification">>,
        from_uid = Contact#contact.userid,
        timestamp = <<>>,
        thread_id = Contact#contact.normalized,
        thread_name = Contact#contact.name
    };

parse_metadata(#message{sub_els = [#ps_event{items = #ps_items{
        items = [#ps_item{id = Id, publisher = FromId,
        type = ItemType, timestamp = TimestampBin}]}}]}) ->
    #jid{luser = FromUid} = jid:from_string(FromId),
    #push_metadata{
        content_id = Id,
        content_type = util:to_binary(ItemType),
        from_uid = FromUid,
        timestamp = TimestampBin,
        thread_id = <<"feed">>
    };

parse_metadata(#message{sub_els = [#feed_st{posts = [Post]}]}) ->
    #push_metadata{
        content_id = Post#post_st.id,
        content_type = <<"feedpost">>,
        from_uid = Post#post_st.uid,
        timestamp = Post#post_st.timestamp,
        thread_id = <<"feed">>,
        sender_name = Post#post_st.publisher_name
    };

parse_metadata(#message{sub_els = [#feed_st{comments = [Comment]}]}) ->
    #push_metadata{
        content_id = Comment#comment_st.id,
        content_type = <<"comment">>,
        from_uid = Comment#comment_st.publisher_uid,
        timestamp = Comment#comment_st.timestamp,
        thread_id = <<"feed">>,
        sender_name = Comment#comment_st.publisher_name
    };

parse_metadata(#message{sub_els = [#group_feed_st{gid = Gid, post = Post, comment = undefined} = SubElement]}) ->
    #push_metadata{
        content_id = Post#group_post_st.id,
        content_type = <<"group_post">>,
        from_uid = Post#group_post_st.publisher_uid,
        timestamp = Post#group_post_st.timestamp,
        thread_id = Gid,
        thread_name = SubElement#group_feed_st.name,
        sender_name = Post#group_post_st.publisher_name
    };

parse_metadata(#message{sub_els = [#group_feed_st{gid = Gid, post = undefined, comment = Comment} = SubElement]}) ->
    #push_metadata{
        content_id = Comment#group_comment_st.id,
        content_type = <<"group_comment">>,
        from_uid = Comment#group_comment_st.publisher_uid,
        timestamp = Comment#group_comment_st.timestamp,
        thread_id = Gid,
        thread_name = SubElement#group_feed_st.name,
        sender_name = Comment#group_comment_st.publisher_name
    };

parse_metadata(#message{to = #jid{luser = Uid}, id = Id}) ->
    ?ERROR("Uid: ~s, Invalid message for push notification: id: ~s", [Uid, Id]),
    #push_metadata{}.


-spec record_push_sent(Message :: message()) -> boolean().
record_push_sent(Message) ->
    PushMetadata = parse_metadata(Message),
    ContentId = PushMetadata#push_metadata.content_id,
    #jid{user = UserId} = Message#message.to,
    model_messages:record_push_sent(UserId, ContentId).


