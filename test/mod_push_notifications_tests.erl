%%%-------------------------------------------------------------------
%%% File: mod_push_notifications_tests.erl
%%% copyright (C) 2020, halloapp, inc.
%%%
%%%
%%%-------------------------------------------------------------------
-module(mod_push_notifications_tests).
-author('murali').

-include_lib("eunit/include/eunit.hrl").
-include("xmpp.hrl").
-include("parser_test_data.hrl").


feed_push1_test() ->
    PostSt1 = struct_util:create_pb_post(?ID1, ?UID1, ?NAME1, ?PAYLOAD1, undefined, ?TIMESTAMP1),
    FeedSt1 = struct_util:create_feed_item(publish, PostSt1),
    MessageSt1 = struct_util:create_pb_message(?ID1, undefined, undefined, normal, FeedSt1),
    ?assertEqual(true, mod_push_notifications:should_push(MessageSt1)),
    ok.

feed_push2_test() ->
    PostSt2 = struct_util:create_pb_post(?ID1, ?UID1, undefined, undefined, undefined, undefined),
    FeedSt2 = struct_util:create_feed_item(retract, PostSt2),
    MessageSt2 = struct_util:create_pb_message(?ID1, undefined, undefined, normal, FeedSt2),
    ?assertEqual(true, mod_push_notifications:should_push(MessageSt2)),
    ok.


group_feed_push1_test() ->
    PostSt = struct_util:create_pb_post(?ID1, ?UID1, ?NAME1, ?PAYLOAD1, undefined, ?TIMESTAMP1),
    FeedSt1 = struct_util:create_group_feed_item(publish, ?GID1, ?G_NAME1, ?G_AVATAR_ID1, PostSt),
    MessageSt1 = struct_util:create_pb_message(?ID1, undefined, undefined, normal, FeedSt1),
    ?assertEqual(true, mod_push_notifications:should_push(MessageSt1)),
    ok.

group_feed_push2_test() ->
    CommentSt = struct_util:create_pb_comment(?ID3, ?ID1, undefined, undefined, undefined, undefined, undefined),
    FeedSt2 = struct_util:create_group_feed_item(retract, ?GID1, <<>>, undefined, CommentSt),
    MessageSt2 = struct_util:create_pb_message(?ID1, undefined, undefined, normal, FeedSt2),
    ?assertEqual(true, mod_push_notifications:should_push(MessageSt2)),
    ok.


chat_retract_push1_test() ->
    RetractSt1 = struct_util:create_pb_chat_retract(?ID1),
    MessageSt1 = struct_util:create_pb_message(?ID1, undefined, undefined, chat, RetractSt1),
    ?assertEqual(true, mod_push_notifications:should_push(MessageSt1)),
    ok.

chat_retract_push2_test() ->
    RetractSt2 = struct_util:create_pb_groupchat_retract(?ID1, ?GID1),
    MessageSt2 = struct_util:create_pb_message(?ID1, undefined, undefined, groupchat, RetractSt2),
    ?assertEqual(true, mod_push_notifications:should_push(MessageSt2)),
    ok.


chat_push1_test() ->
    ChatSt = struct_util:create_pb_chat_stanza(?TIMESTAMP1, ?NAME1, ?PAYLOAD1, ?PAYLOAD2, ?PAYLOAD1, 12),
    MessageSt1 = struct_util:create_pb_message(?ID1, undefined, undefined, chat, ChatSt),
    ?assertEqual(true, mod_push_notifications:should_push(MessageSt1)),
    ok.

chat_push2_test() ->
    GroupChatSt = struct_util:create_pb_group_chat(?GID1, ?G_NAME1, ?G_AVATAR_ID1, ?UID2, ?NAME2, ?TIMESTAMP1, ?PAYLOAD1),
    MessageSt2 = struct_util:create_pb_message(?ID1, undefined, undefined, groupchat, GroupChatSt),
    ?assertEqual(true, mod_push_notifications:should_push(MessageSt2)),
    ok.


contact_push1_test() ->
    Contact1 = struct_util:create_pb_contact(add, ?RAW1, ?NORM1, ?UID1, ?ID1, ?NAME1),
    ContactList1 = struct_util:create_pb_contact_list(full, ?ID1, 0, true, [Contact1]),
    MessageSt1 = struct_util:create_pb_message(?ID1, undefined, undefined, normal, ContactList1),
    ?assertEqual(true, mod_push_notifications:should_push(MessageSt1)),
    ok.

contact_push2_test() ->
    ContactList2 = struct_util:create_pb_contact_hash(?HASH1_BASE64),
    MessageSt2 = struct_util:create_pb_message(?ID1, undefined, undefined, normal, ContactList2),
    ?assertEqual(true, mod_push_notifications:should_push(MessageSt2)),
    ok.


whisper_push1_test() ->
    WhisperKeys = struct_util:create_pb_whisper_keys(?UID1, add, ?KEY1, ?KEY2, 5, [?KEY3, ?KEY4]),
    MessageSt = struct_util:create_pb_message(?ID1, undefined, undefined, normal, WhisperKeys),
    ?assertEqual(false, mod_push_notifications:should_push(MessageSt)),
    ok.

should_push_group_add_test() ->
    MemberSt2 = struct_util:create_pb_member(add, ?UID2, member, ?NAME2, ?AVATAR_ID2, ok, undefined),
    MemberSt3 = struct_util:create_pb_member(add, ?UID3, member, ?NAME3, ?AVATAR_ID3, ok, undefined),
    GroupSt = struct_util:create_pb_group_stanza(modify_members, ?GID1, ?G_NAME1, ?G_AVATAR_ID1, ?UID1,
        ?NAME1, [MemberSt2, MemberSt3]),
    MessageSt2 = struct_util:create_pb_message(?ID1, ?UID2, ?UID1, groupchat, GroupSt),
    ?assertEqual(true, mod_push_notifications:should_push(MessageSt2)),
    MessageSt3 = struct_util:create_pb_message(?ID1, ?UID3, ?UID1, groupchat, GroupSt),
    ?assertEqual(true, mod_push_notifications:should_push(MessageSt3)),
    MessageSt1 = struct_util:create_pb_message(?ID1, ?UID1, ?UID1, groupchat, GroupSt),
    ?assertEqual(false, mod_push_notifications:should_push(MessageSt1)),
    ok.


