%%%-------------------------------------------------------------------
%%% File: push_util_tests.erl
%%% copyright (C) 2022, halloapp, inc.
%%%
%%%
%%%-------------------------------------------------------------------
-module(push_util_tests).

-include_lib("eunit/include/eunit.hrl").
-include ("push_message.hrl").

-define(ANDROID, android).
-define(ID1, <<"1">>).
-define(ID2, <<"2">>).
-define(TYPE, contact).
-define(PHONE, <<"1234567890">>).


parse_metadata_test() ->

    % Chats
    Chat = #pb_msg{id = ?ID1, payload = #pb_chat_stanza{}},
    #push_metadata{content_id = ?ID1, content_type = pb_chat_stanza} = push_util:parse_metadata(Chat),
    ChatRetract = #pb_msg{id = ?ID1, payload = #pb_chat_retract{id = ?ID2}},
    #push_metadata{content_id = ?ID2, content_type = pb_chat_retract} = push_util:parse_metadata(ChatRetract),
    GroupChat = #pb_msg{id = ?ID1, payload = #pb_group_chat{}},
    #push_metadata{content_id = ?ID1, content_type = pb_group_chat} = push_util:parse_metadata(GroupChat),
    GroupChatRetract = #pb_msg{id = ?ID1, payload = #pb_group_chat_retract{id = ?ID2}},
    #push_metadata{content_id = ?ID2, content_type = pb_group_chat_retract} = push_util:parse_metadata(GroupChatRetract),

    % Contacts
    ContactHash = #pb_msg{id = ?ID1, payload = #pb_contact_hash{}},
    #push_metadata{content_id = ?ID1, content_type = pb_contact_hash} = push_util:parse_metadata(ContactHash),
    ContactList = #pb_msg{payload = #pb_contact_list{contacts = [#pb_contact{normalized = ?PHONE}], type = ?TYPE}},
    #push_metadata{content_id = ?PHONE, content_type = ?TYPE} = push_util:parse_metadata(ContactList),

    % Feed
    Feedpost = #pb_msg{id = ?ID1, payload = #pb_feed_item{item = #pb_post{id = ?ID2}}},
    #push_metadata{content_id = ?ID2, content_type = feedpost} = push_util:parse_metadata(Feedpost),
    FeedpostRetract = #pb_msg{id = ?ID1, payload = #pb_feed_item{action = retract, item = #pb_post{id = ?ID2}}},
    #push_metadata{content_id = ?ID2, content_type = feedpost_retract} = push_util:parse_metadata(FeedpostRetract),
    Comment = #pb_msg{id = ?ID1, payload = #pb_feed_item{item = #pb_comment{id = ?ID2}}},
    #push_metadata{content_id = ?ID2, content_type = comment} = push_util:parse_metadata(Comment),
    CommentRetract = #pb_msg{id = ?ID1, payload = #pb_feed_item{action = retract, item = #pb_comment{id = ?ID2}}},
    #push_metadata{content_id = ?ID2, content_type = comment_retract} = push_util:parse_metadata(CommentRetract),

    % Group feed
    GroupFeedpost = #pb_msg{id = ?ID1, payload = #pb_group_feed_item{item = #pb_post{id = ?ID2}}},
    #push_metadata{content_id = ?ID2, content_type = group_post} = push_util:parse_metadata(GroupFeedpost),
    GroupFeedpostRetract = #pb_msg{id = ?ID1, payload = #pb_group_feed_item{action = retract, item = #pb_post{id = ?ID2}}},
    #push_metadata{content_id = ?ID2, content_type = group_post_retract} = push_util:parse_metadata(GroupFeedpostRetract),
    GroupComment = #pb_msg{id = ?ID1, payload = #pb_group_feed_item{item = #pb_comment{id = ?ID2}}},
    #push_metadata{content_id = ?ID2, content_type = group_comment} = push_util:parse_metadata(GroupComment),
    GroupCommentRetract = #pb_msg{id = ?ID1, payload = #pb_group_feed_item{action = retract, item = #pb_comment{id = ?ID2}}},
    #push_metadata{content_id = ?ID2, content_type = group_comment_retract} = push_util:parse_metadata(GroupCommentRetract),
    GroupStanza = #pb_msg{id = ?ID1, payload = #pb_group_stanza{}},
    #push_metadata{content_id = ?ID1, content_type = pb_group_stanza} = push_util:parse_metadata(GroupStanza),

    % Rerequests
    Rerequest = #pb_msg{id = ?ID1, payload = #pb_rerequest{}},
    #push_metadata{content_id = ?ID1, content_type = pb_rerequest} = push_util:parse_metadata(Rerequest),
    GroupRerequest = #pb_msg{id = ?ID1, payload = #pb_group_feed_rerequest{}},
    #push_metadata{content_id = ?ID1, content_type = pb_group_feed_rerequest} = push_util:parse_metadata(GroupRerequest),
    HomeRerequest = #pb_msg{id = ?ID1, payload = #pb_home_feed_rerequest{}},
    #push_metadata{content_id = ?ID1, content_type = pb_home_feed_rerequest} = push_util:parse_metadata(HomeRerequest),
    GroupFeedItem = #pb_msg{id = ?ID1, payload = #pb_group_feed_items{}},
    #push_metadata{content_id = ?ID1, content_type = pb_group_feed_items} = push_util:parse_metadata(GroupFeedItem),
    FeedItem = #pb_msg{id = ?ID1, payload = #pb_feed_items{}},
    #push_metadata{content_id = ?ID1, content_type = pb_feed_items} = push_util:parse_metadata(FeedItem),
    RequestLogs = #pb_msg{id = ?ID1, payload = #pb_request_logs{}},
    #push_metadata{content_id = ?ID1, content_type = pb_request_logs} = push_util:parse_metadata(RequestLogs),
    WakeUp = #pb_msg{id = ?ID1, payload = #pb_wake_up{}},
    #push_metadata{content_id = ?ID1, content_type = pb_wake_up} = push_util:parse_metadata(WakeUp),

    % Calls
    Incoming = #pb_msg{id = ?ID1, payload = #pb_incoming_call{call_id = ?ID2}},
    #push_metadata{content_id = ?ID2, content_type = pb_incoming_call} = push_util:parse_metadata(Incoming),
    Ringing = #pb_msg{id = ?ID1, payload = #pb_call_ringing{call_id = ?ID2}},
    #push_metadata{content_id = ?ID2, content_type = pb_call_ringing} = push_util:parse_metadata(Ringing),
    PreAnswer = #pb_msg{id = ?ID1, payload = #pb_pre_answer_call{call_id = ?ID2}},
    #push_metadata{content_id = ?ID2, content_type = pb_pre_answer_call} = push_util:parse_metadata(PreAnswer),
    End = #pb_msg{id = ?ID1, payload = #pb_end_call{call_id = ?ID2}},
    #push_metadata{content_id = ?ID2, content_type = pb_end_call} = push_util:parse_metadata(End),
    Ice = #pb_msg{id = ?ID1, payload = #pb_ice_candidate{call_id = ?ID2}},
    #push_metadata{content_id = ?ID2, content_type = pb_ice_candidate} = push_util:parse_metadata(Ice),

    % Marketing
    Invite = #pb_msg{id = ?ID1, payload = #pb_marketing_alert{type = invite_friends}},
    #push_metadata{content_id = ?ID1, content_type = pb_marketing_alert} = push_util:parse_metadata(Invite),
    Share = #pb_msg{id = ?ID1, payload = #pb_marketing_alert{type = invite_friends}},
    #push_metadata{content_id = ?ID1, content_type = pb_marketing_alert} = push_util:parse_metadata(Share),

    % Catch All
    Msg = #pb_msg{id = ?ID1},
    #push_metadata{content_id = ?ID1, content_type = undefined, push_type = alert} = push_util:parse_metadata(Msg),
    
    ok.


process_push_times_test() ->
    PushTimes = [],
    [10] = push_util:process_push_times(PushTimes, 10, ?ANDROID),
    PushTimes2 = [1,2,3,4],
    % Newest time is added at the end
    [1,2,3,4,10] = push_util:process_push_times(PushTimes2, 10, ?ANDROID),
    PushTimes3 = [0,1,2,3,4,5,6,7,8,9],
    % Only hold last ten times
    [1,2,3,4,5,6,7,8,9,10] = push_util:process_push_times(PushTimes3, 10, ?ANDROID),
    ok.

