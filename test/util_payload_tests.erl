%%%-------------------------------------------------------------------
%%% File: util_payload_tests.erl
%%% copyright (C) 2020, halloapp, inc.
%%%
%%%
%%%-------------------------------------------------------------------
-module(util_payload_tests).
-author('murali').

-include_lib("eunit/include/eunit.hrl").
-include("parser_test_data.hrl").


ack_payload_type_test() ->
    Ack = struct_util:create_pb_ack(?ID1, ?TIMESTAMP1),
    ?assertEqual(undefined, util:get_payload_type(Ack)).


presence_payload_type_test() ->
    Presence = struct_util:create_pb_presence(?ID1, available, undefined, undefined, undefined, undefined),
    ?assertEqual(undefined, util:get_payload_type(Presence)).


chat_state_payload_type_test() ->
    ChatState = struct_util:create_pb_chat_state(available, ?GID1, group_chat, undefined),
    ?assertEqual(undefined, util:get_payload_type(ChatState)).


message_payload_type_test() ->
    PostSt = struct_util:create_pb_post(?ID1, ?UID1, ?NAME1, ?PAYLOAD1_BASE64, undefined, ?TIMESTAMP1),
    FeedSt1 = struct_util:create_feed_item(publish, PostSt),
    MessageSt = struct_util:create_pb_message(undefined, undefined, undefined, normal, FeedSt1),
    ?assertEqual(pb_feed_item, util:get_payload_type(MessageSt)).

iq_payload_type_test() ->
    CommentSt = struct_util:create_pb_comment(?ID3, ?ID1, <<>>, ?UID2, ?NAME2, ?PAYLOAD2_BASE64, ?TIMESTAMP2),
    FeedSt2 = struct_util:create_feed_item(publish, CommentSt),
    IqSt = struct_util:create_pb_iq(?ID1, set, FeedSt2),
    ?assertEqual(pb_feed_item, util:get_payload_type(IqSt)).

