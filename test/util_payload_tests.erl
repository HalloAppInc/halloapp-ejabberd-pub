%%%-------------------------------------------------------------------
%%% File: util_payload_tests.erl
%%% copyright (C) 2020, halloapp, inc.
%%%
%%%
%%%-------------------------------------------------------------------
-module(util_payload_tests).
-author('murali').

-include_lib("eunit/include/eunit.hrl").
-include("xmpp.hrl").
-include("parser_test_data.hrl").


ack_payload_type_test() ->
    Ack = struct_util:create_ack(?ID1, undefined, undefined, ?TIMESTAMP1),
    ?assertEqual(undefined, util:get_payload_type(Ack)),
    ok.


presence_payload_type_test() ->
    Presence = struct_util:create_presence(?ID1, available, undefined, undefined, undefined),
    ?assertEqual(undefined, util:get_payload_type(Presence)),
    ok.


chat_state_payload_type_test() ->
    ChatState = struct_util:create_chat_state(undefined, undefined, available, ?GID1, group_chat),
    ?assertEqual(undefined, util:get_payload_type(ChatState)),
    ok.


message_payload_type_test() ->
    PostSt = struct_util:create_post_st(?ID1, ?UID1, ?NAME1, ?PAYLOAD1_BASE64, ?TIMESTAMP1),
    FeedSt1 = struct_util:create_feed_st(publish, [PostSt], [], [], []),
    MessageSt = struct_util:create_message_stanza(undefined, undefined, undefined, normal, FeedSt1),
    ?assertEqual(feed_st, util:get_payload_type(MessageSt)),
    ok.

iq_payload_type_test() ->
    CommentSt = struct_util:create_comment_st(?ID3, ?ID1, <<>>, ?UID2, ?NAME2, ?PAYLOAD2_BASE64, ?TIMESTAMP2),
    FeedSt2 = struct_util:create_feed_st(publish, [], [CommentSt], [], []),
    IqSt = struct_util:create_iq_stanza(?ID1, undefined, undefined, set, FeedSt2),
    ?assertEqual(feed_st, util:get_payload_type(IqSt)),
    ok.

