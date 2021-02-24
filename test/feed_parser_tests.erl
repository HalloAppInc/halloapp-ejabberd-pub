%%%-------------------------------------------------------------------
%%% File: feed_parser_tests.erl
%%% Copyright (C) 2020, Halloapp Inc.
%%%
%%%-------------------------------------------------------------------
-module(feed_parser_tests).
-author('murali').

-include_lib("eunit/include/eunit.hrl").
-include("packets.hrl").
-include("xmpp.hrl").
-include("parser_test_data.hrl").

%% -------------------------------------------- %%
%% internal tests
%% -------------------------------------------- %%

setup() ->
    stringprep:start(),
    ok.

xmpp_to_proto_message_feed_item_test() ->
    setup(),

    PbPost = struct_util:create_pb_post(?ID1, ?UID1, ?NAME1, ?PAYLOAD1, undefined, ?TIMESTAMP1_INT),
    PbFeedItem = struct_util:create_feed_item(publish, PbPost),
    PbMessage = struct_util:create_pb_message(?ID1, ?UID2, ?UID1, normal, PbFeedItem),

    PostSt = struct_util:create_post_st(?ID1, ?UID1, ?NAME1, ?PAYLOAD1_BASE64, ?TIMESTAMP1),
    FeedSt = struct_util:create_feed_st(publish, [PostSt], [], [], []),
    ToJid = struct_util:create_jid(?UID2, ?SERVER),
    FromJid = struct_util:create_jid(?UID1, ?SERVER),
    MessageSt = struct_util:create_message_stanza(?ID1, ToJid, FromJid, normal, FeedSt),

    ProtoMsg = message_parser:xmpp_to_proto(MessageSt),
    ?assertEqual(true, is_record(ProtoMsg, pb_msg)),
    ?assertEqual(PbMessage, ProtoMsg).


xmpp_to_proto_retract_message_feed_item_test() ->
    setup(),

    PbPost = struct_util:create_pb_post(?ID1, ?UID1, ?NAME1, <<>>, undefined, ?TIMESTAMP1_INT),
    PbFeedItem = struct_util:create_feed_item(retract, PbPost),
    PbMessage = struct_util:create_pb_message(?ID1, ?UID2, ?UID1, normal, PbFeedItem),

    PostSt = struct_util:create_post_st(?ID1, ?UID1, ?NAME1, <<>>, ?TIMESTAMP1),
    FeedSt = struct_util:create_feed_st(retract, [PostSt], [], [], []),
    ToJid = struct_util:create_jid(?UID2, ?SERVER),
    FromJid = struct_util:create_jid(?UID1, ?SERVER),
    MessageSt = struct_util:create_message_stanza(?ID1, ToJid, FromJid, normal, FeedSt),

    ProtoMsg = message_parser:xmpp_to_proto(MessageSt),
    ?assertEqual(true, is_record(ProtoMsg, pb_msg)),
    ?assertEqual(PbMessage, ProtoMsg).


xmpp_to_proto_message_feed_items_test() ->
    setup(),

    PbPost1 = struct_util:create_pb_post(?ID1, ?UID1, ?NAME1, ?PAYLOAD1, undefined, ?TIMESTAMP1_INT),
    PbPost2 = struct_util:create_pb_post(?ID2, ?UID1, ?NAME2, ?PAYLOAD2, undefined, ?TIMESTAMP2_INT),
    PbComment1 = struct_util:create_pb_comment(?ID3, ?ID1, <<>>, ?UID2, ?NAME2, ?PAYLOAD2, ?TIMESTAMP2_INT),
    PbFeedItem1 = struct_util:create_feed_item(publish, PbPost1),
    PbFeedItem2 = struct_util:create_feed_item(publish, PbPost2),
    PbFeedItem3 = struct_util:create_feed_item(publish, PbComment1),
    PbFeedItems = struct_util:create_feed_items(?UID1, [PbFeedItem1, PbFeedItem2, PbFeedItem3]),
    PbMessage = struct_util:create_pb_message(?ID1, ?UID3, ?UID1, normal, PbFeedItems),

    PostSt1 = struct_util:create_post_st(?ID1, ?UID1, ?NAME1, ?PAYLOAD1_BASE64, ?TIMESTAMP1),
    PostSt2 = struct_util:create_post_st(?ID2, ?UID1, ?NAME2, ?PAYLOAD2_BASE64, ?TIMESTAMP2),
    CommentSt1 = struct_util:create_comment_st(?ID3, ?ID1, <<>>, ?UID2, ?NAME2, ?PAYLOAD2_BASE64, ?TIMESTAMP2),
    FeedSt = struct_util:create_feed_st(share, [PostSt1, PostSt2], [CommentSt1], [], []),
    ToJid = struct_util:create_jid(?UID3, ?SERVER),
    FromJid = struct_util:create_jid(?UID1, ?SERVER),
    MessageSt = struct_util:create_message_stanza(?ID1, ToJid, FromJid, normal, FeedSt),

    ProtoMsg = message_parser:xmpp_to_proto(MessageSt),
    ?assertEqual(true, is_record(ProtoMsg, pb_msg)),
    ?assertEqual(PbMessage, ProtoMsg).


proto_to_xmpp_message_feed_items_test() ->
    setup(),

    PbPost1 = struct_util:create_pb_post(?ID1, ?UID1, ?NAME1, ?PAYLOAD1, undefined, ?TIMESTAMP1_INT),
    PbPost2 = struct_util:create_pb_post(?ID2, ?UID1, ?NAME2, ?PAYLOAD2, undefined, ?TIMESTAMP2_INT),
    PbComment1 = struct_util:create_pb_comment(?ID3, ?ID1, <<>>, ?UID2, ?NAME2, ?PAYLOAD2, ?TIMESTAMP2_INT),
    PbFeedItem1 = struct_util:create_feed_item(publish, PbPost1),
    PbFeedItem2 = struct_util:create_feed_item(publish, PbPost2),
    PbFeedItem3 = struct_util:create_feed_item(publish, PbComment1),
    PbFeedItems = struct_util:create_feed_items(?UID1, [PbFeedItem1, PbFeedItem2, PbFeedItem3]),
    PbMessage = struct_util:create_pb_message(?ID1, ?UID3, ?UID1, normal, PbFeedItems),

    PostSt1 = struct_util:create_post_st(?ID1, ?UID1, ?NAME1, ?PAYLOAD1_BASE64, ?TIMESTAMP1),
    PostSt2 = struct_util:create_post_st(?ID2, ?UID1, ?NAME2, ?PAYLOAD2_BASE64, ?TIMESTAMP2),
    CommentSt1 = struct_util:create_comment_st(?ID3, ?ID1, <<>>, ?UID2, ?NAME2, ?PAYLOAD2_BASE64, ?TIMESTAMP2),
    FeedSt = struct_util:create_feed_st(share, [PostSt1, PostSt2], [CommentSt1], [], []),
    ToJid = struct_util:create_jid(?UID3, ?SERVER),
    FromJid = struct_util:create_jid(?UID1, ?SERVER),
    MessageSt = struct_util:create_message_stanza(?ID1, ToJid, FromJid, normal, FeedSt),

    XmppMsg = message_parser:proto_to_xmpp(PbMessage),
    ?assertEqual(true, is_record(XmppMsg, message)),
    ?assertEqual(XmppMsg, MessageSt).

