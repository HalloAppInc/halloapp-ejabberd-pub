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

%% -------------------------------------------- %%
%% define chat constants
%% -------------------------------------------- %%

-define(UID1, <<"1000000000045484920">>).
-define(UID1_INT, 1000000000045484920).
-define(NAME1, <<"name1">>).

-define(UID2, <<"1000000000519345762">>).
-define(UID2_INT, 1000000000519345762).
-define(NAME2, <<"name2">>).

-define(UID3, <<"1000000000321423233">>).
-define(UID3_INT, 1000000000321423233).
-define(NAME3, <<"name3">>).

-define(ID1, <<"id1">>).
-define(ID2, <<"id2">>).
-define(ID3, <<"id3">>).

-define(PAYLOAD1, <<"123">>).
-define(PAYLOAD2, <<"456">>).
-define(PAYLOAD1_BASE64, <<"MTIz">>).
-define(PAYLOAD2_BASE64, <<"NDU2">>).
-define(TIMESTAMP1, <<"2000090910">>).
-define(TIMESTAMP1_INT, 2000090910).
-define(TIMESTAMP2, <<"1850012340">>).
-define(TIMESTAMP2_INT, 1850012340).
-define(SERVER, <<"s.halloapp.net">>).


%% -------------------------------------------- %%
%% internal tests
%% -------------------------------------------- %%


xmpp_to_proto_message_feed_item_test() ->
    PbPost = struct_util:create_pb_post(?ID1, ?UID1_INT, <<>>, ?PAYLOAD1, undefined, ?TIMESTAMP1_INT),
    PbFeedItem = struct_util:create_feed_item(publish, PbPost),
    PbMessage = struct_util:create_pb_message(?ID1, ?UID2_INT, ?UID1_INT, normal, PbFeedItem),

    PostSt = struct_util:create_post_st(?ID1, ?UID1, ?PAYLOAD1_BASE64, ?TIMESTAMP1),
    FeedSt = struct_util:create_feed_st(publish, [PostSt], [], [], []),
    ToJid = struct_util:create_jid(?UID2, ?SERVER),
    FromJid = struct_util:create_jid(?UID1, ?SERVER),
    MessageSt = struct_util:create_message_stanza(?ID1, ToJid, FromJid, normal, FeedSt),

    ProtoMsg = message_parser:xmpp_to_proto(MessageSt),
    ?assertEqual(true, is_record(ProtoMsg, pb_msg)),
    ?assertEqual(PbMessage, ProtoMsg).


xmpp_to_proto_retract_message_feed_item_test() ->
    PbPost = create_pb_post(?ID1, ?UID1_INT, undefined, undefined, ?TIMESTAMP1_INT),
    PbFeedItem = create_feed_item(retract, PbPost),
    PbMessage = create_pb_message(?ID1, ?UID2_INT, ?UID1_INT, normal, PbFeedItem),

    PostSt = create_post_st(?ID1, ?UID1, undefined, ?TIMESTAMP1),
    FeedSt = create_feed_st(retract, [PostSt], [], [], []),
    ToJid = create_jid(?UID2, ?SERVER),
    FromJid = create_jid(?UID1, ?SERVER),
    MessageSt = create_message_stanza(?ID1, ToJid, FromJid, normal, FeedSt),

    ProtoMsg = message_parser:xmpp_to_proto(MessageSt),
    ?assertEqual(true, is_record(ProtoMsg, pb_msg)),
    ?assertEqual(PbMessage, ProtoMsg).


xmpp_to_proto_message_feed_items_test() ->
    PbPost1 = struct_util:create_pb_post(?ID1, ?UID1_INT, <<>>, ?PAYLOAD1, undefined, ?TIMESTAMP1_INT),
    PbPost2 = struct_util:create_pb_post(?ID2, ?UID1_INT, <<>>, ?PAYLOAD2, undefined, ?TIMESTAMP2_INT),
    PbComment1 = struct_util:create_pb_comment(?ID3, ?ID1, <<>>, ?UID2_INT, ?NAME2, ?PAYLOAD2, ?TIMESTAMP2_INT),
    PbFeedItem1 = struct_util:create_feed_item(publish, PbPost1),
    PbFeedItem2 = struct_util:create_feed_item(publish, PbPost2),
    PbFeedItem3 = struct_util:create_feed_item(publish, PbComment1),
    PbFeedItems = struct_util:create_feed_items(?UID1_INT, [PbFeedItem1, PbFeedItem2, PbFeedItem3]),
    PbMessage = struct_util:create_pb_message(?ID1, ?UID3_INT, ?UID1_INT, normal, PbFeedItems),

    PostSt1 = struct_util:create_post_st(?ID1, ?UID1, ?PAYLOAD1_BASE64, ?TIMESTAMP1),
    PostSt2 = struct_util:create_post_st(?ID2, ?UID1, ?PAYLOAD2_BASE64, ?TIMESTAMP2),
    CommentSt1 = struct_util:create_comment_st(?ID3, ?ID1, <<>>, ?UID2, ?NAME2, ?PAYLOAD2_BASE64, ?TIMESTAMP2),
    FeedSt = struct_util:create_feed_st(share, [PostSt1, PostSt2], [CommentSt1], [], []),
    ToJid = struct_util:create_jid(?UID3, ?SERVER),
    FromJid = struct_util:create_jid(?UID1, ?SERVER),
    MessageSt = struct_util:create_message_stanza(?ID1, ToJid, FromJid, normal, FeedSt),

    ProtoMsg = message_parser:xmpp_to_proto(MessageSt),
    ?assertEqual(true, is_record(ProtoMsg, pb_msg)),
    ?assertEqual(PbMessage, ProtoMsg).


xmpp_to_proto_iq_share_response_test() ->
    ShareFeedResponse = struct_util:create_share_feed_response(?UID1_INT, <<"ok">>, undefined),
    ShareFeedResponses = struct_util:create_share_feed_responses([ShareFeedResponse]),
    PbIq = struct_util:create_pb_iq(?ID1, result, ShareFeedResponses),

    SharePostsSt = struct_util:create_share_posts_st(?UID1, [], ok, undefined),
    FeedSt = struct_util:create_feed_st(share, [], [], [], [SharePostsSt]),
    IqSt = struct_util:create_iq_stanza(?ID1, undefined, undefined, result, FeedSt),

    ProtoIq = iq_parser:xmpp_to_proto(IqSt),
    ?assertEqual(true, is_record(ProtoIq, pb_iq)),
    ?assertEqual(PbIq, ProtoIq).


proto_to_xmpp_iq_feed_item_test() ->
    PbComment = struct_util:create_pb_comment(?ID3, ?ID1, <<>>, ?UID2_INT, ?NAME2, ?PAYLOAD2, ?TIMESTAMP2_INT),
    PbFeedItem = struct_util:create_feed_item(publish, PbComment),
    PbIq = struct_util:create_pb_iq(?ID1, set, PbFeedItem),

    CommentSt = struct_util:create_comment_st(?ID3, ?ID1, <<>>, ?UID2, ?NAME2, ?PAYLOAD2_BASE64, ?TIMESTAMP2),
    FeedSt = struct_util:create_feed_st(publish, [], [CommentSt], [], []),
    IqSt = struct_util:create_iq_stanza(?ID1, undefined, undefined, set, FeedSt),

    XmppIq = iq_parser:proto_to_xmpp(PbIq),
    ?assertEqual(true, is_record(XmppIq, iq)),
    ?assertEqual(IqSt, XmppIq).


proto_to_xmpp_iq_retract_feed_item_test() ->
    PbComment = create_pb_comment(?ID3, ?ID1, <<>>, ?UID2_INT, ?NAME2, undefined, ?TIMESTAMP2_INT),
    PbFeedItem =create_feed_item(retract, PbComment),
    PbIq = create_pb_iq(?ID1, set, PbFeedItem),

    CommentSt = create_comment_st(?ID3, ?ID1, <<>>, ?UID2, ?NAME2, undefined, ?TIMESTAMP2),
    FeedSt = create_feed_st(retract, [], [CommentSt], [], []),
    IqSt = create_iq_stanza(?ID1, undefined, undefined, set, FeedSt),

    XmppIq = iq_parser:proto_to_xmpp(PbIq),
    ?assertEqual(true, is_record(XmppIq, iq)),
    ?assertEqual(IqSt, XmppIq).


proto_to_xmpp_iq_feed_item_audience_test() ->
    PbAudience = struct_util:create_pb_audience(only, [?UID2_INT, ?UID3_INT]),
    PbPost = struct_util:create_pb_post(?ID1, ?UID1_INT, ?NAME1, ?PAYLOAD1, PbAudience, ?TIMESTAMP1_INT),
    PbFeedItem = struct_util:create_feed_item(publish, PbPost),
    PbIq = struct_util:create_pb_iq(?ID1, set, PbFeedItem),

    AudienceSt = struct_util:create_audience_list(only, [?UID2, ?UID3]),
    PostSt = struct_util:create_post_st(?ID1, ?UID1, ?PAYLOAD1_BASE64, ?TIMESTAMP1),
    FeedSt = struct_util:create_feed_st(publish, [PostSt], [], [AudienceSt], []),
    IqSt = struct_util:create_iq_stanza(?ID1, undefined, undefined, set, FeedSt),

    XmppIq = iq_parser:proto_to_xmpp(PbIq),
    ?assertEqual(true, is_record(XmppIq, iq)),
    ?assertEqual(IqSt, XmppIq).


proto_to_xmpp_iq_share_request_test() ->
    ShareFeedRequest = struct_util:create_share_feed_request(?UID1_INT, [?ID1, ?ID2]),
    ShareFeedRequests = struct_util:create_share_feed_requests([ShareFeedRequest]),
    PbIq = struct_util:create_pb_iq(?ID1, set, ShareFeedRequests),

    PostSt1 = struct_util:create_post_st(?ID1, <<>>, <<>>, <<>>),
    PostSt2 = struct_util:create_post_st(?ID2, <<>>, <<>>, <<>>),
    SharePostsSt = struct_util:create_share_posts_st(?UID1, [PostSt1, PostSt2], undefined, undefined),
    FeedSt = struct_util:create_feed_st(share, [], [], [], [SharePostsSt]),
    IqSt = struct_util:create_iq_stanza(?ID1, undefined, undefined, set, FeedSt),

    XmppIq = iq_parser:proto_to_xmpp(PbIq),
    ?assertEqual(true, is_record(XmppIq, iq)),
    ?assertEqual(IqSt, XmppIq).

