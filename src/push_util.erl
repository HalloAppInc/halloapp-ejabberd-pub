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
    get_title_body/2,
    process_push_times/3
]).

-spec parse_metadata(Message :: pb_msg()) -> push_metadata().
parse_metadata(#pb_msg{payload = Payload} = Message) when is_record(Payload, pb_chat_stanza) ->
    #push_metadata{
        content_id = pb:get_content_id(Message),
        content_type = pb:get_payload_type(Message)
    };

parse_metadata(#pb_msg{payload = Payload} = Message) when is_record(Payload, pb_chat_retract) ->
    #push_metadata{
        content_id = pb:get_content_id(Message),
        content_type = pb:get_payload_type(Message)
    };

parse_metadata(#pb_msg{payload = Payload} = Message) when is_record(Payload, pb_group_chat) ->
    #push_metadata{
        content_id = pb:get_content_id(Message),
        content_type = pb:get_payload_type(Message)
    };

parse_metadata(#pb_msg{payload = Payload} = Message) when is_record(Payload, pb_group_chat_retract) ->
    #push_metadata{
        content_id = pb:get_content_id(Message),
        content_type = pb:get_payload_type(Message)
    };

parse_metadata(#pb_msg{payload = Payload} = Message) when is_record(Payload, pb_contact_hash) ->
    #push_metadata{
        content_id = pb:get_content_id(Message),
        content_type = pb:get_payload_type(Message)
    };

parse_metadata(#pb_msg{payload = Payload} = Message) when is_record(Payload, pb_contact_list) ->
    ContentType = Payload#pb_contact_list.type,
    #push_metadata{
        content_id = pb:get_content_id(Message),
        content_type = ContentType
    };

parse_metadata(#pb_msg{payload = #pb_feed_item{action = publish, item = #pb_post{}}} = Message) ->
    #push_metadata{
        content_id = pb:get_content_id(Message),
        content_type = feedpost
    };

parse_metadata(#pb_msg{payload = #pb_feed_item{action = retract, item = #pb_post{}}} = Message) ->
    #push_metadata{
        content_id = pb:get_content_id(Message),
        content_type = feedpost_retract
    };

parse_metadata(#pb_msg{payload = #pb_feed_item{action = publish, item = #pb_comment{}}} = Message) ->
    #push_metadata{
        content_id = pb:get_content_id(Message),
        content_type = comment
    };

parse_metadata(#pb_msg{payload = #pb_feed_item{action = retract, item = #pb_comment{}}} = Message) ->
    #push_metadata{
        content_id = pb:get_content_id(Message),
        content_type = comment_retract
    };

parse_metadata(#pb_msg{payload = #pb_group_feed_item{action = publish, item = #pb_post{}}} = Message) ->
    #push_metadata{
        content_id = pb:get_content_id(Message),
        content_type = group_post
    };

parse_metadata(#pb_msg{payload = #pb_group_feed_item{action = retract, item = #pb_post{}}} = Message) ->
    #push_metadata{
        content_id = pb:get_content_id(Message),
        content_type = group_post_retract
    };

parse_metadata(#pb_msg{payload = #pb_group_feed_item{action = publish, item = #pb_comment{}}} = Message) ->
    #push_metadata{
        content_id = pb:get_content_id(Message),
        content_type = group_comment
    };

parse_metadata(#pb_msg{payload = #pb_group_feed_item{action = retract, item = #pb_comment{}}} = Message) ->
    #push_metadata{
        content_id = pb:get_content_id(Message),
        content_type = group_comment_retract
    };

parse_metadata(#pb_msg{payload = #pb_group_stanza{}} = Message) ->
    #push_metadata{
        content_id = pb:get_content_id(Message),
        content_type = pb:get_payload_type(Message)
    };

parse_metadata(#pb_msg{payload = #pb_rerequest{}} = Message) ->
    #push_metadata{
        content_id = pb:get_content_id(Message),
        content_type = pb:get_payload_type(Message)
    };

parse_metadata(#pb_msg{payload = #pb_group_feed_rerequest{}} = Message) ->
    #push_metadata{
        content_id = pb:get_content_id(Message),
        content_type = pb:get_payload_type(Message)
    };

parse_metadata(#pb_msg{payload = #pb_home_feed_rerequest{}} = Message) ->
    #push_metadata{
        content_id = pb:get_content_id(Message),
        content_type = pb:get_payload_type(Message)
    };

parse_metadata(#pb_msg{payload = #pb_group_feed_items{}} = Message) ->
    #push_metadata{
        content_id = pb:get_content_id(Message),
        content_type = pb:get_payload_type(Message)
    };

parse_metadata(#pb_msg{payload = #pb_feed_items{}} = Message) ->
    #push_metadata{
        content_id = pb:get_content_id(Message),
        content_type = pb:get_payload_type(Message)
    };

parse_metadata(#pb_msg{payload = #pb_request_logs{}} = Message) ->
    #push_metadata{
        content_id = pb:get_content_id(Message),
        content_type = pb:get_payload_type(Message)
    };

parse_metadata(#pb_msg{payload = #pb_wake_up{}} = Message) ->
    #push_metadata{
        content_id = pb:get_content_id(Message),
        content_type = pb:get_payload_type(Message)
    };

parse_metadata(#pb_msg{payload = #pb_incoming_call{}} = Message) ->
    #push_metadata{
        content_id = pb:get_content_id(Message),
        content_type = pb:get_payload_type(Message)
    };

parse_metadata(#pb_msg{payload = #pb_call_ringing{}} = Message) ->
    #push_metadata{
        content_id = pb:get_content_id(Message),
        content_type = pb:get_payload_type(Message)
    };

parse_metadata(#pb_msg{payload = #pb_pre_answer_call{}} = Message) ->
    #push_metadata{
        content_id = pb:get_content_id(Message),
        content_type = pb:get_payload_type(Message)
    };

parse_metadata(#pb_msg{payload = #pb_answer_call{}} = Message) ->
    #push_metadata{
        content_id = pb:get_content_id(Message),
        content_type = pb:get_payload_type(Message)
    };

parse_metadata(#pb_msg{payload = #pb_end_call{}} = Message) ->
    #push_metadata{
        content_id = pb:get_content_id(Message),
        content_type = pb:get_payload_type(Message)
    };

parse_metadata(#pb_msg{payload = #pb_ice_candidate{}} = Message) ->
    #push_metadata{
        content_id = pb:get_content_id(Message),
        content_type = pb:get_payload_type(Message)
    };

parse_metadata(#pb_msg{payload = #pb_marketing_alert{type = invite_friends}} = Message) ->
    #push_metadata{
        content_id = pb:get_content_id(Message),
        content_type = pb:get_payload_type(Message),
        push_type = direct_alert
    };

parse_metadata(#pb_msg{payload = #pb_marketing_alert{type = share_post}} = Message) ->
    #push_metadata{
        content_id = pb:get_content_id(Message),
        content_type = pb:get_payload_type(Message),
        push_type = direct_alert
    };

parse_metadata(#pb_msg{} = Message) ->
    #push_metadata{
        content_id = pb:get_content_id(Message),
        content_type = pb:get_payload_type(Message)
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


% Rolling average of how long the last ten push notifications have taken
-spec process_push_times(PushTimes :: [integer()], Time :: integer(), Platform :: android | ios) -> [integer()].
process_push_times(PushTimes, Time, Platform) ->
    NewPushTimes = case PushTimes of
        PrevTimes when length(PushTimes) < 10 -> PrevTimes ++ [Time];
        [_OldestTime | PrevTimes] -> PrevTimes ++ [Time]
    end,
    Avg = lists:sum(NewPushTimes)/length(NewPushTimes),
    FormattedAvg = io_lib:format("~.1f",[Avg]),
    ?INFO("Average time over ~p ~p push notification: ~p ms. ", [length(NewPushTimes), Platform, FormattedAvg]),
    stat:count("HA/push", "push_time", 1, [{platform, Platform}, {length, FormattedAvg}]),
    NewPushTimes.

