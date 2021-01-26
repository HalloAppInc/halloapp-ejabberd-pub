%%%-------------------------------------------------------------------
%%% File: group_feed_parser_tests.erl
%%% Copyright (C) 2020, Halloapp Inc.
%%%
%%%-------------------------------------------------------------------
-module(group_feed_parser_tests).
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

    PbPost = struct_util:create_pb_post(?ID1, ?UID1_INT, ?NAME1, ?PAYLOAD1, undefined, ?TIMESTAMP1_INT),
    PbFeedItem = struct_util:create_group_feed_item(publish, ?GID1, ?G_NAME1, ?G_AVATAR_ID1, PbPost),
    PbMessage = struct_util:create_pb_message(?ID1, ?UID2_INT, ?UID1_INT, normal, PbFeedItem),

    PostSt = struct_util:create_group_post_st(?ID1, ?UID1, ?NAME1, ?PAYLOAD1_BASE64, ?TIMESTAMP1),
    FeedSt = struct_util:create_group_feed_st(publish, ?GID1, ?G_NAME1, ?G_AVATAR_ID1, [PostSt], []),
    ToJid = struct_util:create_jid(?UID2, ?SERVER),
    FromJid = struct_util:create_jid(?UID1, ?SERVER),
    MessageSt = struct_util:create_message_stanza(?ID1, ToJid, FromJid, normal, FeedSt),

    ProtoMsg = message_parser:xmpp_to_proto(MessageSt),
    ?assertEqual(true, is_record(ProtoMsg, pb_msg)),
    ?assertEqual(PbMessage, ProtoMsg).


xmpp_to_proto_iq_feed_item_test() ->
    setup(),

    PbComment = struct_util:create_pb_comment(?ID3, ?ID1, <<>>, ?UID2_INT, ?NAME2, ?PAYLOAD2, ?TIMESTAMP2_INT),
    PbFeedItem = struct_util:create_group_feed_item(publish, ?GID1, ?G_NAME1, ?G_AVATAR_ID1, PbComment),
    PbIq = struct_util:create_pb_iq(?ID1, result, PbFeedItem),

    CommentSt = struct_util:create_group_comment_st(?ID3, ?ID1, <<>>, ?UID2, ?NAME2, ?PAYLOAD2_BASE64, ?TIMESTAMP2),
    FeedSt = struct_util:create_group_feed_st(publish, ?GID1, ?G_NAME1, ?G_AVATAR_ID1, [], [CommentSt]),
    IqSt = struct_util:create_iq_stanza(?ID1, undefined, undefined, result, FeedSt),

    ActualProtoIq = iq_parser:xmpp_to_proto(IqSt),
    ?assertEqual(true, is_record(ActualProtoIq, pb_iq)),
    ?assertEqual(PbIq, ActualProtoIq).


proto_to_xmpp_iq_feed_item_test() ->
    setup(),

    PbComment = struct_util:create_pb_comment(?ID3, ?ID1, <<>>, undefined, undefined, ?PAYLOAD2, undefined),
    PbFeedItem = struct_util:create_group_feed_item(publish, ?GID1, undefined, undefined, PbComment),
    PbIq = struct_util:create_pb_iq(?ID1, set, PbFeedItem),

    CommentSt = struct_util:create_group_comment_st(?ID3, ?ID1, <<>>, <<>>, undefined, ?PAYLOAD2_BASE64, undefined),
    FeedSt = struct_util:create_group_feed_st(publish, ?GID1, <<>>, undefined, [], [CommentSt]),
    IqSt = struct_util:create_iq_stanza(?ID1, undefined, undefined, set, FeedSt),

    XmppIq = iq_parser:proto_to_xmpp(PbIq),
    ?assertEqual(true, is_record(XmppIq, iq)),
    ?assertEqual(IqSt, XmppIq).


xmpp_to_proto_message_feed_items_test() ->
    setup(),

    PbPost = struct_util:create_pb_post(?ID1, ?UID1_INT, ?NAME1, ?PAYLOAD1, undefined, ?TIMESTAMP1_INT),
    PbFeedItem1 = struct_util:create_group_feed_item(publish, <<>>, <<>>, <<>>, PbPost),
    PbComment = struct_util:create_pb_comment(?ID3, ?ID1, <<>>, ?UID2_INT, ?NAME2, ?PAYLOAD2, ?TIMESTAMP2_INT),
    PbFeedItem2 = struct_util:create_group_feed_item(publish, <<>>, <<>>, <<>>, PbComment),
    PbGroupFeedItems = struct_util:create_group_feed_items(?GID1, ?G_NAME1, ?G_AVATAR_ID1, [PbFeedItem1, PbFeedItem2]),
    PbMessage = struct_util:create_pb_message(?ID1, ?UID2_INT, ?UID1_INT, normal, PbGroupFeedItems),

    PostSt = struct_util:create_group_post_st(?ID1, ?UID1, ?NAME1, ?PAYLOAD1_BASE64, ?TIMESTAMP1),
    CommentSt = struct_util:create_group_comment_st(?ID3, ?ID1, <<>>, ?UID2, ?NAME2, ?PAYLOAD2_BASE64, ?TIMESTAMP2),
    FeedSt = struct_util:create_group_feed_st(share, ?GID1, ?G_NAME1, ?G_AVATAR_ID1, [PostSt], [CommentSt]),
    ToJid = struct_util:create_jid(?UID2, ?SERVER),
    FromJid = struct_util:create_jid(?UID1, ?SERVER),
    MessageSt = struct_util:create_message_stanza(?ID1, ToJid, FromJid, normal, FeedSt),

    ProtoMsg = message_parser:xmpp_to_proto(MessageSt),
    ?assertEqual(true, is_record(ProtoMsg, pb_msg)),
    ?assertEqual(PbMessage, ProtoMsg),
    ok.


proto_to_xmpp_message_feed_items_test() ->
    setup(),

    PbPost = struct_util:create_pb_post(?ID1, ?UID1_INT, ?NAME1, ?PAYLOAD1, undefined, ?TIMESTAMP1_INT),
    PbFeedItem1 = struct_util:create_group_feed_item(publish, <<>>, <<>>, <<>>, PbPost),
    PbComment = struct_util:create_pb_comment(?ID3, ?ID1, <<>>, ?UID2_INT, ?NAME2, ?PAYLOAD2, ?TIMESTAMP2_INT),
    PbFeedItem2 = struct_util:create_group_feed_item(publish, <<>>, <<>>, <<>>, PbComment),
    PbGroupFeedItems = struct_util:create_group_feed_items(?GID1, ?G_NAME1, ?G_AVATAR_ID1, [PbFeedItem1, PbFeedItem2]),
    PbMessage = struct_util:create_pb_message(?ID1, ?UID2_INT, ?UID1_INT, normal, PbGroupFeedItems),

    PostSt = struct_util:create_group_post_st(?ID1, ?UID1, ?NAME1, ?PAYLOAD1_BASE64, ?TIMESTAMP1),
    CommentSt = struct_util:create_group_comment_st(?ID3, ?ID1, <<>>, ?UID2, ?NAME2, ?PAYLOAD2_BASE64, ?TIMESTAMP2),
    FeedSt = struct_util:create_group_feed_st(share, ?GID1, ?G_NAME1, ?G_AVATAR_ID1, [PostSt], [CommentSt]),
    ToJid = struct_util:create_jid(?UID2, ?SERVER),
    FromJid = struct_util:create_jid(?UID1, ?SERVER),
    MessageSt = struct_util:create_message_stanza(?ID1, ToJid, FromJid, normal, FeedSt),

    XmppMsg = message_parser:proto_to_xmpp(PbMessage),
    ?assertEqual(true, is_record(XmppMsg, message)),
    ?assertEqual(MessageSt, XmppMsg),
    ok.

