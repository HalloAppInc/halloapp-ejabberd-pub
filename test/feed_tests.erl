-module(feed_tests).

-compile(export_all).
-include("suite.hrl").
-include("packets.hrl").
-include("account_test_data.hrl").
-include_lib("stdlib/include/assert.hrl").

group() ->
    {feed, [sequence], [
        feed_dummy_test,
        feed_connect_test,
        feed_make_post_test,
        feed_make_comment_test
    ]}.

dummy_test(_Conf) ->
    ok.

connect_test(_Conf) ->
    {ok, C} = ha_client:start_link(),
    ok = ha_client:stop(C),
    ok.

make_post_test(_Conf) ->
    {ok, C1} = ha_client:connect_and_login(?UID1, ?PASSWORD1),
    {ok, C2} = ha_client:connect_and_login(?UID2, ?PASSWORD2),

    PbAudience = struct_util:create_pb_audience(only, [?UID2_INT, ?UID3_INT]),
    PbPost = struct_util:create_pb_post(?POST_ID1, ?UID1_INT, ?NAME1, ?PAYLOAD1, PbAudience, ?TS1),
    PbFeedItem = struct_util:create_feed_item(publish, PbPost),

    ha_client:send_iq(C1, ?UID1, set, PbFeedItem),

    RecvMsg = ha_client:wait_for(C2,
        fun (P) ->
            case P of
                #pb_packet{stanza = #pb_msg{type = headline, to_uid = ?UID2_INT, payload = #pb_feed_item{item = #pb_post{id = ?POST_ID1}}}} -> true;
                _Any -> false
            end
        end),

    Msg = RecvMsg#pb_packet.stanza,
    FeedItem = Msg#pb_msg.payload,
    Post = FeedItem#pb_feed_item.item,
    Ts = Post#pb_post.timestamp,
    ModifiedPost = Post#pb_post{timestamp=Ts, audience=undefined},
    ModifiedFeedItem = FeedItem#pb_feed_item{item=ModifiedPost},
    Id = Msg#pb_msg.id,
    RetryCount = Msg#pb_msg.retry_count,
    ReRequestCount = Msg#pb_msg.rerequest_count,

    #pb_packet{
        stanza = #pb_msg{
            id = Id,
            type = headline,
            to_uid = ?UID2_INT,
            payload = ModifiedFeedItem,
            retry_count = RetryCount,
            rerequest_count = ReRequestCount
        }
    } = RecvMsg,
    ok.


make_comment_test(_Conf) ->
    {ok, C1} = ha_client:connect_and_login(?UID1, ?PASSWORD1),
    {ok, C2} = ha_client:connect_and_login(?UID2, ?PASSWORD2),
    % we don't have a parent comment id right now, hence it is left as the default value <<>>
    PbComment1 = struct_util:create_pb_comment(?COMMENT_ID1, ?POST_ID1, <<>>, ?UID2_INT, ?NAME2, ?PAYLOAD1, ?TS2),
    PbFeedItem = struct_util:create_feed_item(publish, PbComment1),

    ha_client:send_iq(C2, ?UID2, set, PbFeedItem),

    % verify C1 gets the comment
    RecvMsg = ha_client:wait_for(C1,
        fun (P) ->
            case P of
                #pb_packet{stanza = #pb_msg{payload = #pb_feed_item{item = #pb_comment{id = ?COMMENT_ID1}}}} -> true;
                _Any -> false
            end
        end),

    Msg = RecvMsg#pb_packet.stanza,
    FeedItem = Msg#pb_msg.payload,
    Comment = FeedItem#pb_feed_item.item,
    Ts = Comment#pb_comment.timestamp,
    ModifiedComment = Comment#pb_comment{timestamp=Ts},
    ModifiedFeedItem = FeedItem#pb_feed_item{item=ModifiedComment},
    Id = Msg#pb_msg.id,
    RetryCount = Msg#pb_msg.retry_count,
    ReRequestCount = Msg#pb_msg.rerequest_count,

    #pb_packet{
        stanza = #pb_msg{
            id = Id,
            type = headline,
            to_uid = ?UID1_INT,
            payload = ModifiedFeedItem,
            retry_count = RetryCount,
            rerequest_count = ReRequestCount
        }
    } = RecvMsg,
    ok.

