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
    parse_metadata/1,
    get_title_body/2
]).

-spec parse_metadata(Message :: pb_msg()) -> push_metadata().
parse_metadata(#pb_msg{id = Id, payload = Payload} = Message) when is_record(Payload, pb_chat_stanza) ->
    #push_metadata{
        content_id = Id,
        content_type = pb:get_payload_type(Message)
    };

parse_metadata(#pb_msg{payload = Payload} = Message) when is_record(Payload, pb_chat_retract) ->
    #push_metadata{
        content_id = Payload#pb_chat_retract.id,
        content_type = pb:get_payload_type(Message)
    };

parse_metadata(#pb_msg{id = Id, payload = Payload} = Message) when is_record(Payload, pb_group_chat) ->
    #push_metadata{
        content_id = Id,
        content_type = pb:get_payload_type(Message)
    };

parse_metadata(#pb_msg{payload = Payload} = Message) when is_record(Payload, pb_group_chat_retract) ->
    #push_metadata{
        content_id = Payload#pb_group_chat_retract.id,
        content_type = pb:get_payload_type(Message)
    };

parse_metadata(#pb_msg{id = Id, payload = Payload} = Message) when is_record(Payload, pb_contact_hash) ->
    #push_metadata{
        content_id = Id,
        content_type = pb:get_payload_type(Message)
    };

parse_metadata(#pb_msg{payload = Payload}) when is_record(Payload, pb_contact_list) ->
    [Contact | _] = Payload#pb_contact_list.contacts,
    ContentType = Payload#pb_contact_list.type,
    #push_metadata{
        content_id = Contact#pb_contact.normalized,
        content_type = ContentType
    };

parse_metadata(#pb_msg{payload = #pb_feed_item{action = publish, item = #pb_post{} = Post}}) ->
    #push_metadata{
        content_id = Post#pb_post.id,
        content_type = feedpost
    };

parse_metadata(#pb_msg{payload = #pb_feed_item{action = retract, item = #pb_post{} = Post}}) ->
    #push_metadata{
        content_id = Post#pb_post.id,
        content_type = feedpost_retract
    };

parse_metadata(#pb_msg{payload = #pb_feed_item{action = publish, item = #pb_comment{} = Comment}}) ->
    #push_metadata{
        content_id = Comment#pb_comment.id,
        content_type = comment
    };

parse_metadata(#pb_msg{payload = #pb_feed_item{action = retract, item = #pb_comment{} = Comment}}) ->
    #push_metadata{
        content_id = Comment#pb_comment.id,
        content_type = comment_retract
    };

parse_metadata(#pb_msg{payload = #pb_group_feed_item{action = publish, item = #pb_post{} = Post}}) ->
    #push_metadata{
        content_id = Post#pb_post.id,
        content_type = group_post
    };

parse_metadata(#pb_msg{payload = #pb_group_feed_item{action = retract, item = #pb_post{} = Post}}) ->
    #push_metadata{
        content_id = Post#pb_post.id,
        content_type = group_post_retract
    };

parse_metadata(#pb_msg{payload = #pb_group_feed_item{action = publish, item = #pb_comment{} = Comment}}) ->
    #push_metadata{
        content_id = Comment#pb_comment.id,
        content_type = group_comment
    };

parse_metadata(#pb_msg{payload = #pb_group_feed_item{action = retract, item = #pb_comment{} = Comment}}) ->
    #push_metadata{
        content_id = Comment#pb_comment.id,
        content_type = group_comment_retract
    };

parse_metadata(#pb_msg{id = Id, payload = #pb_group_stanza{}} = Message) ->
    #push_metadata{
        content_id = Id,
        content_type = pb:get_payload_type(Message)
    };

parse_metadata(#pb_msg{id = Id, payload = #pb_rerequest{}} = Message) ->
    #push_metadata{
        content_id = Id,
        content_type = pb:get_payload_type(Message)
    };

parse_metadata(#pb_msg{id = Id, payload = #pb_group_feed_rerequest{}} = Message) ->
    #push_metadata{
        content_id = Id,
        content_type = pb:get_payload_type(Message)
    };

parse_metadata(#pb_msg{id = Id, payload = #pb_home_feed_rerequest{}} = Message) ->
    #push_metadata{
        content_id = Id,
        content_type = pb:get_payload_type(Message)
    };

parse_metadata(#pb_msg{id = Id, payload = #pb_group_feed_items{}} = Message) ->
    #push_metadata{
        content_id = Id,
        content_type = pb:get_payload_type(Message)
    };

parse_metadata(#pb_msg{id = Id, payload = #pb_feed_items{}} = Message) ->
    #push_metadata{
        content_id = Id,
        content_type = pb:get_payload_type(Message)
    };

parse_metadata(#pb_msg{id = Id, payload = #pb_request_logs{}} = Message) ->
    #push_metadata{
        content_id = Id,
        content_type = pb:get_payload_type(Message)
    };

parse_metadata(#pb_msg{id = Id, payload = #pb_wake_up{}} = Message) ->
    #push_metadata{
        content_id = Id,
        content_type = pb:get_payload_type(Message)
    };

parse_metadata(#pb_msg{id = Id, payload = #pb_incoming_call{call_id = CallId}} = Message) ->
    #push_metadata{
        content_id = <<CallId/binary, "-", Id/binary>>,
        content_type = pb:get_payload_type(Message)
    };

parse_metadata(#pb_msg{id = Id, payload = #pb_call_ringing{call_id = CallId}} = Message) ->
    #push_metadata{
        content_id = <<CallId/binary, "-", Id/binary>>,
        content_type = pb:get_payload_type(Message)
    };

parse_metadata(#pb_msg{id = Id, payload = #pb_pre_answer_call{call_id = CallId}} = Message) ->
    #push_metadata{
        content_id = <<CallId/binary, "-", Id/binary>>,
        content_type = pb:get_payload_type(Message)
    };

parse_metadata(#pb_msg{id = Id, payload = #pb_answer_call{call_id = CallId}} = Message) ->
    #push_metadata{
        content_id = <<CallId/binary, "-", Id/binary>>,
        content_type = pb:get_payload_type(Message)
    };

parse_metadata(#pb_msg{id = Id, payload = #pb_end_call{call_id = CallId}} = Message) ->
    #push_metadata{
        content_id = <<CallId/binary, "-", Id/binary>>,
        content_type = pb:get_payload_type(Message)
    };

parse_metadata(#pb_msg{id = Id, payload = #pb_ice_candidate{call_id = CallId}} = Message) ->
    #push_metadata{
        content_id = <<CallId/binary, "-", Id/binary>>,
        content_type = pb:get_payload_type(Message)
    };

parse_metadata(#pb_msg{id = Id, payload = #pb_marketing_alert{type = invite_friends}} = Message) ->
    #push_metadata{
        content_id = Id,
        content_type = pb:get_payload_type(Message),
        push_type = direct_alert
    };

parse_metadata(#pb_msg{id = Id, payload = #pb_marketing_alert{type = share_post}} = Message) ->
    #push_metadata{
        content_id = Id,
        content_type = pb:get_payload_type(Message),
        push_type = direct_alert
    };

parse_metadata(#pb_msg{to_uid = Uid, id = Id}) ->
    #push_metadata{
        content_id = Id,
        content_type = pb:get_payload_type(Message),
        push_type = alert
    }.


-spec get_title_body(Message :: pb_msg(), PushInfo :: push_info()) -> {binary(), binary()}.
get_title_body(#pb_msg{payload = #pb_marketing_alert{type = invite_friends}}, PushInfo) ->
    Title = translate(<<"server.marketing.title">>, PushInfo#push_info.lang_id),
    Body = translate(<<"server.marketing.body">>, PushInfo#push_info.lang_id),
    {Title, Body};
get_title_body(#pb_msg{payload = #pb_marketing_alert{type = share_post}}, PushInfo) ->
    Title = translate(<<"server.marketing.post.title">>, PushInfo#push_info.lang_id),
    Body = translate(<<"server.marketing.post.body">>, PushInfo#push_info.lang_id),
    {Title, Body}.


-spec translate(Token :: binary(), LangId :: binary()) -> binary().
translate(Token, LangId) ->
    translate(Token, [], LangId).

-spec translate(Token :: binary(), Args :: [binary()], LangId :: binary()) -> binary().
translate(Token, Args, LangId) ->
    {Translation, _ResultLangId} = mod_translate:translate(Token, Args, LangId),
    Translation.

