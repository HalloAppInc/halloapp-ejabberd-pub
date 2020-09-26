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


create_post_st(Id, Uid, Payload, Timestamp) ->
    #post_st{
        id = Id,
        uid = Uid,
        payload = Payload,
        timestamp = Timestamp
    }.


create_comment_st(Id, PostId, ParentCommentId, PublisherUid, PublisherName, Payload, Timestamp) ->
    #comment_st{
        id = Id,
        post_id = PostId,
        parent_comment_id = ParentCommentId,
        publisher_uid = PublisherUid,
        publisher_name = PublisherName,
        payload = Payload,
        timestamp = Timestamp
    }.


create_audience_list(Type, Uids) ->
    UidEls = lists:map(fun(Uid) -> #uid_element{uid = Uid} end, Uids),
    #audience_list_st{
        type = Type,
        uids = UidEls
    }.


create_share_posts_st(Uid, Posts, Result, Reason) ->
    #share_posts_st{
        uid = Uid,
        posts = Posts,
        result = Result,
        reason = Reason
    }.


create_feed_st(Action, Posts, Comments, AudienceList, SharePosts) ->
    #feed_st{
        action = Action,
        posts = Posts,
        comments = Comments,
        audience_list = AudienceList,
        share_posts = SharePosts
    }.


create_pb_audience(Type, Uids) ->
    #pb_audience{
        type = Type,
        uids = Uids
    }.

create_pb_post(Id, Uid, Payload, Audience, Timestamp) ->
    #pb_post{
        id = Id,
        publisher_uid = Uid,
        payload = Payload,
        audience = Audience,
        timestamp = Timestamp
    }.


create_pb_comment(Id, PostId, ParentCommentId, PublisherUid, PublisherName, Payload, Timestamp) ->
    #pb_comment{
        id = Id,
        post_id = PostId,
        parent_comment_id = ParentCommentId,
        publisher_uid = PublisherUid,
        publisher_name = PublisherName,
        payload = Payload,
        timestamp = Timestamp
    }.


create_feed_item(Action, Item) ->
    #pb_feed_item{
        action = Action,
        item = Item
    }.


create_feed_items(Uid, Items) ->
    #pb_feed_items{
        uid = Uid,
        items = Items
    }.

create_share_feed_request(Uid, PostIds) ->
    #pb_share_stanza{
        uid = Uid,
        post_ids = PostIds
    }.


create_share_feed_requests(PbShareStanzas) ->
    #pb_feed_item{
        action = share,
        share_stanzas = PbShareStanzas
    }.


create_share_feed_response(Uid, Result, Reason) ->
    #pb_share_stanza {
        uid = Uid,
        result = Result,
        reason = Reason
    }.


create_share_feed_responses(PbShareStanzas) ->
    #pb_feed_item{
        action = share,
        share_stanzas = PbShareStanzas
    }.


create_jid(Uid, Server) ->
    #jid{
        user = Uid,
        server = Server
    }.


create_message_stanza(Id, ToJid, FromJid, Type, SubEl) ->
    #message{
        id = Id,
        to = ToJid,
        from = FromJid,
        type = Type,
        sub_els = [SubEl]
    }.


create_pb_message(Id, ToUid, FromUid, Type, PayloadContent) ->
    #pb_msg{
        id = Id,
        to_uid = ToUid,
        from_uid = FromUid,
        type = Type,
        payload = PayloadContent
    }.


create_iq_stanza(Id, ToJid, FromJid, Type, SubEl) ->
    #iq{
        id = Id,
        to = ToJid,
        from = FromJid,
        type = Type,
        sub_els = [SubEl]
    }.


create_pb_iq(Id, Type, PayloadContent) ->
    #pb_iq{
        id = Id,
        type = Type,
        payload = PayloadContent
    }.


%% -------------------------------------------- %%
%% internal tests
%% -------------------------------------------- %%


xmpp_to_proto_message_feed_item_test() ->
    PbPost = create_pb_post(?ID1, ?UID1_INT, ?PAYLOAD1, undefined, ?TIMESTAMP1_INT),
    PbFeedItem = create_feed_item(publish, PbPost),
    PbMessage = create_pb_message(?ID1, ?UID2_INT, ?UID1_INT, normal, PbFeedItem),

    PostSt = create_post_st(?ID1, ?UID1, ?PAYLOAD1_BASE64, ?TIMESTAMP1),
    FeedSt = create_feed_st(publish, [PostSt], [], [], []),
    ToJid = create_jid(?UID2, ?SERVER),
    FromJid = create_jid(?UID1, ?SERVER),
    MessageSt = create_message_stanza(?ID1, ToJid, FromJid, normal, FeedSt),

    ProtoMsg = message_parser:xmpp_to_proto(MessageSt),
    ?assertEqual(true, is_record(ProtoMsg, pb_msg)),
    ?assertEqual(PbMessage, ProtoMsg).


xmpp_to_proto_message_feed_items_test() ->
    PbPost1 = create_pb_post(?ID1, ?UID1_INT, ?PAYLOAD1, undefined, ?TIMESTAMP1_INT),
    PbPost2 = create_pb_post(?ID2, ?UID1_INT, ?PAYLOAD2, undefined, ?TIMESTAMP2_INT),
    PbComment1 = create_pb_comment(?ID3, ?ID1, <<>>, ?UID2_INT, ?NAME2, ?PAYLOAD2, ?TIMESTAMP2_INT),
    PbFeedItem1 = create_feed_item(publish, PbPost1),
    PbFeedItem2 = create_feed_item(publish, PbPost2),
    PbFeedItem3 = create_feed_item(publish, PbComment1),
    PbFeedItems = create_feed_items(?UID1_INT, [PbFeedItem1, PbFeedItem2, PbFeedItem3]),
    PbMessage = create_pb_message(?ID1, ?UID3_INT, ?UID1_INT, normal, PbFeedItems),

    PostSt1 = create_post_st(?ID1, ?UID1, ?PAYLOAD1_BASE64, ?TIMESTAMP1),
    PostSt2 = create_post_st(?ID2, ?UID1, ?PAYLOAD2_BASE64, ?TIMESTAMP2),
    CommentSt1 = create_comment_st(?ID3, ?ID1, <<>>, ?UID2, ?NAME2, ?PAYLOAD2_BASE64, ?TIMESTAMP2),
    FeedSt = create_feed_st(share, [PostSt1, PostSt2], [CommentSt1], [], []),
    ToJid = create_jid(?UID3, ?SERVER),
    FromJid = create_jid(?UID1, ?SERVER),
    MessageSt = create_message_stanza(?ID1, ToJid, FromJid, normal, FeedSt),

    ProtoMsg = message_parser:xmpp_to_proto(MessageSt),
    ?assertEqual(true, is_record(ProtoMsg, pb_msg)),
    ?assertEqual(PbMessage, ProtoMsg).


xmpp_to_proto_iq_share_response_test() ->
    ShareFeedResponse = create_share_feed_response(?UID1_INT, <<"ok">>, undefined),
    ShareFeedResponses = create_share_feed_responses([ShareFeedResponse]),
    PbIq = create_pb_iq(?ID1, result, ShareFeedResponses),

    SharePostsSt = create_share_posts_st(?UID1, [], ok, undefined),
    FeedSt = create_feed_st(share, [], [], [], [SharePostsSt]),
    IqSt = create_iq_stanza(?ID1, undefined, undefined, result, FeedSt),

    ProtoIq = iq_parser:xmpp_to_proto(IqSt),
    ?assertEqual(true, is_record(ProtoIq, pb_iq)),
    ?assertEqual(PbIq, ProtoIq).


proto_to_xmpp_iq_feed_item_test() ->
    PbComment = create_pb_comment(?ID3, ?ID1, <<>>, ?UID2_INT, ?NAME2, ?PAYLOAD2, ?TIMESTAMP2_INT),
    PbFeedItem =create_feed_item(publish, PbComment),
    PbIq = create_pb_iq(?ID1, set, PbFeedItem),

    CommentSt = create_comment_st(?ID3, ?ID1, <<>>, ?UID2, ?NAME2, ?PAYLOAD2_BASE64, ?TIMESTAMP2),
    FeedSt = create_feed_st(publish, [], [CommentSt], [], []),
    IqSt = create_iq_stanza(?ID1, undefined, undefined, set, FeedSt),

    XmppIq = iq_parser:proto_to_xmpp(PbIq),
    ?assertEqual(true, is_record(XmppIq, iq)),
    ?assertEqual(IqSt, XmppIq).


proto_to_xmpp_iq_feed_item_audience_test() ->
    PbAudience = create_pb_audience(only, [?UID2_INT, ?UID3_INT]),
    PbPost = create_pb_post(?ID1, ?UID1_INT, ?PAYLOAD1, PbAudience, ?TIMESTAMP1_INT),
    PbFeedItem = create_feed_item(publish, PbPost),
    PbIq = create_pb_iq(?ID1, set, PbFeedItem),

    AudienceSt = create_audience_list(only, [?UID2, ?UID3]),
    PostSt = create_post_st(?ID1, ?UID1, ?PAYLOAD1_BASE64, ?TIMESTAMP1),
    FeedSt = create_feed_st(publish, [PostSt], [], [AudienceSt], []),
    IqSt = create_iq_stanza(?ID1, undefined, undefined, set, FeedSt),

    XmppIq = iq_parser:proto_to_xmpp(PbIq),
    ?assertEqual(true, is_record(XmppIq, iq)),
    ?assertEqual(IqSt, XmppIq).


proto_to_xmpp_iq_share_request_test() ->
    ShareFeedRequest = create_share_feed_request(?UID1_INT, [?ID1, ?ID2]),
    ShareFeedRequests = create_share_feed_requests([ShareFeedRequest]),
    PbIq = create_pb_iq(?ID1, set, ShareFeedRequests),

    PostSt1 = create_post_st(?ID1, <<>>, <<>>, <<>>),
    PostSt2 = create_post_st(?ID2, <<>>, <<>>, <<>>),
    SharePostsSt = create_share_posts_st(?UID1, [PostSt1, PostSt2], undefined, undefined),
    FeedSt = create_feed_st(share, [], [], [], [SharePostsSt]),
    IqSt = create_iq_stanza(?ID1, undefined, undefined, set, FeedSt),

    XmppIq = iq_parser:proto_to_xmpp(PbIq),
    ?assertEqual(true, is_record(XmppIq, iq)),
    ?assertEqual(IqSt, XmppIq).

