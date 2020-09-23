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

%% -------------------------------------------- %%
%% define chat constants
%% -------------------------------------------- %%

-define(UID1, <<"1000000000045484920">>).
-define(UID1_INT, 1000000000045484920).
-define(NAME1, <<"name1">>).

-define(UID2, <<"1000000000519345762">>).
-define(UID2_INT, 1000000000519345762).
-define(NAME2, <<"name2">>).

-define(ID1, <<"id1">>).
-define(ID2, <<"id2">>).
-define(ID3, <<"id3">>).
-define(GID1, <<"gid1">>).
-define(GNAME1, <<"gname1">>).
-define(AVATARID1, <<"avatarid1">>).

-define(PAYLOAD1, <<"123">>).
-define(PAYLOAD2, <<"456">>).
-define(PAYLOAD1_BASE64, <<"MTIz">>).
-define(PAYLOAD2_BASE64, <<"NDU2">>).
-define(TIMESTAMP1, <<"2000090910">>).
-define(TIMESTAMP1_INT, 2000090910).
-define(TIMESTAMP2, <<"1850012340">>).
-define(TIMESTAMP2_INT, 1850012340).
-define(SERVER, <<"s.halloapp.net">>).


create_group_post_st(Id, PublisherUid, PublisherName, Payload, Timestamp) ->
    #group_post_st{
        id = Id,
        publisher_uid = PublisherUid,
        publisher_name = PublisherName,
        payload = Payload,
        timestamp = Timestamp
    }.


create_group_comment_st(Id, PostId, ParentCommentId, PublisherUid, PublisherName, Payload, Timestamp) ->
    #group_comment_st{
        id = Id,
        post_id = PostId,
        parent_comment_id = ParentCommentId,
        publisher_uid = PublisherUid,
        publisher_name = PublisherName,
        payload = Payload,
        timestamp = Timestamp
    }.


create_group_feed_st(Action, Gid, Name, AvatarId, Post, Comment) ->
    #group_feed_st{
        action = Action,
        gid = Gid,
        name = Name,
        avatar_id = AvatarId,
        post = Post,
        comment = Comment
    }.

create_pb_post(Id, PublisherUid, PublisherName, Payload, Audience, Timestamp) ->
    #pb_post{
        id = Id,
        publisher_uid = PublisherUid,
        publisher_name = PublisherName,
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


create_group_feed_item(Action, Gid, Name, AvatarId, Item) ->
    #pb_group_feed_item{
        action = Action,
        gid = Gid,
        name = Name,
        avatar_id = AvatarId,
        item = Item
    }.


create_jid(Uid, Server) ->
    jid:make(Uid, Server).


create_message_stanza(Id, ToJid, FromJid, Type, SubEl) ->
    #message{
        id = Id,
        to = ToJid,
        from = FromJid,
        type = Type,
        sub_els = [SubEl]
    }.


create_pb_message(Id, ToUid, FromUid, Type, PayloadContent) ->
    #pb_ha_message{
        id = Id,
        to_uid = ToUid,
        from_uid = FromUid,
        type = Type,
        payload = #pb_msg_payload{
                content = PayloadContent
            }
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
    #pb_ha_iq{
        id = Id,
        type = Type,
        payload = #pb_iq_payload{
                content = PayloadContent
            }
    }.


%% -------------------------------------------- %%
%% internal tests
%% -------------------------------------------- %%

setup() ->
    stringprep:start(),
    ok.


xmpp_to_proto_message_feed_item_test() ->
    setup(),

    PbPost = create_pb_post(?ID1, ?UID1_INT, ?NAME1, ?PAYLOAD1, undefined, ?TIMESTAMP1_INT),
    PbFeedItem = create_group_feed_item(publish, ?GID1, ?GNAME1, ?AVATARID1, {post, PbPost}),
    PbMessage = create_pb_message(?ID1, ?UID2_INT, ?UID1_INT, normal, {group_feed_item, PbFeedItem}),

    PostSt = create_group_post_st(?ID1, ?UID1, ?NAME1, ?PAYLOAD1_BASE64, ?TIMESTAMP1),
    FeedSt = create_group_feed_st(publish, ?GID1, ?GNAME1, ?AVATARID1, PostSt, undefined),
    ToJid = create_jid(?UID2, ?SERVER),
    FromJid = create_jid(?UID1, ?SERVER),
    MessageSt = create_message_stanza(?ID1, ToJid, FromJid, normal, FeedSt),

    ProtoMsg = message_parser:xmpp_to_proto(MessageSt),
    ?assertEqual(true, is_record(ProtoMsg, pb_ha_message)),
    ?assertEqual(PbMessage, ProtoMsg).


xmpp_to_proto_iq_feed_item_test() ->
    setup(),

    PbComment = create_pb_comment(?ID3, ?ID1, <<>>, ?UID2_INT, ?NAME2, ?PAYLOAD2, ?TIMESTAMP2_INT),
    PbFeedItem =create_group_feed_item(publish, ?GID1, ?GNAME1, ?AVATARID1, {comment, PbComment}),
    PbIq = create_pb_iq(?ID1, result, {group_feed_item, PbFeedItem}),

    CommentSt = create_group_comment_st(?ID3, ?ID1, <<>>, ?UID2, ?NAME2, ?PAYLOAD2_BASE64, ?TIMESTAMP2),
    FeedSt = create_group_feed_st(publish, ?GID1, ?GNAME1, ?AVATARID1, undefined, CommentSt),
    IqSt = create_iq_stanza(?ID1, undefined, undefined, result, FeedSt),

    ActualProtoIq = iq_parser:xmpp_to_proto(IqSt),
    ?assertEqual(true, is_record(ActualProtoIq, pb_ha_iq)),
    ?assertEqual(PbIq, ActualProtoIq).


proto_to_xmpp_iq_feed_item_test() ->
    setup(),

    PbComment = create_pb_comment(?ID3, ?ID1, <<>>, undefined, undefined, ?PAYLOAD2, undefined),
    PbFeedItem =create_group_feed_item(publish, ?GID1, undefined, undefined, {comment, PbComment}),
    PbIq = create_pb_iq(?ID1, set, {group_feed_item, PbFeedItem}),

    CommentSt = create_group_comment_st(?ID3, ?ID1, <<>>, <<>>, undefined, ?PAYLOAD2_BASE64, undefined),
    FeedSt = create_group_feed_st(publish, ?GID1, <<>>, undefined, undefined, CommentSt),
    IqSt = create_iq_stanza(?ID1, undefined, undefined, set, FeedSt),

    XmppIq = iq_parser:proto_to_xmpp(PbIq),
    ?assertEqual(true, is_record(XmppIq, iq)),
    ?assertEqual(IqSt, XmppIq).

