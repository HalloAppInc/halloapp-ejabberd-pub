-module(feed_tests).

-compile(export_all).
-include("suite.hrl").
-include("packets.hrl").
-include("account_test_data.hrl").
-include_lib("stdlib/include/assert.hrl").

-define(PAYLOAD1, <<"123">>).
-define(POST_ID1, <<"PostId1">>).
-define(COMMENT_ID1, <<"CommentId1">>).

%TODO: make a post with audience including non-friend user and blocked user - and make sure they don't get the post. Same with comments.
group() ->
    {feed, [sequence], [
        feed_dummy_test,
        feed_make_post_test,
        feed_make_comment_test
    ]}.

dummy_test(_Conf) ->
    ok.

make_post_test(_Conf) ->
    {ok, C1} = ha_client:connect_and_login(?UID1, ?PASSWORD1),
    {ok, C2} = ha_client:connect_and_login(?UID2, ?PASSWORD2),

    PbAudience = struct_util:create_pb_audience(only, [?UID2_INT, ?UID3_INT]),
    PbPost = struct_util:create_pb_post(?POST_ID1, ?UID1_INT, ?NAME1, ?PAYLOAD1, PbAudience, ?TS1),
    PbFeedItem = struct_util:create_feed_item(publish, PbPost),

    IqRes = ha_client:send_iq(C1, ?UID1, set, PbFeedItem),

    % make sure IQ was successful
    #pb_packet{
        stanza = #pb_iq{
            id = ?UID1,
            type = result,
            payload = #pb_feed_item{
                action = publish,
                item = #pb_post{
                    id = ?POST_ID1,
                    publisher_uid = ?UID1_INT,
                    publisher_name = ?NAME1
                }
            }
        }
    } = IqRes,

    RecvMsg = ha_client:wait_for(C2,
        fun (P) ->
            case P of
                #pb_packet{stanza = #pb_msg{payload = #pb_feed_item{}}} -> true;
                _Any -> false
            end
        end),

    #pb_packet{
        stanza = #pb_msg{
            type = headline,
            to_uid = ?UID2_INT,
            payload = #pb_feed_item{
                action = publish,
                item = #pb_post{
                    id = ?POST_ID1,
                    publisher_uid = ?UID1_INT,
                    publisher_name = ?NAME1,
                    payload = ?PAYLOAD1
                }
            }
        }
    } = RecvMsg,
    ok.


make_comment_test(_Conf) ->
    {ok, C1} = ha_client:connect_and_login(?UID1, ?PASSWORD1),
    {ok, C2} = ha_client:connect_and_login(?UID2, ?PASSWORD2),
    % we don't have a parent comment id right now, hence it is left as the default value <<>>
    PbComment1 = struct_util:create_pb_comment(?COMMENT_ID1, ?POST_ID1, <<>>, ?UID2_INT, ?NAME2, ?PAYLOAD1, ?TS2),
    PbFeedItem = struct_util:create_feed_item(publish, PbComment1),

    IqRes = ha_client:send_iq(C2, ?UID2, set, PbFeedItem),
    % make sure IQ was successful, payload is empty here, only timestamp relevant
    #pb_packet{
        stanza = #pb_iq{
            id = ?UID2,
            type = result,
            payload = #pb_feed_item{
                action = publish,
                item = #pb_comment{
                    id = ?COMMENT_ID1,
                    post_id = ?POST_ID1,
                    publisher_uid = ?UID2_INT,
                    publisher_name = ?NAME2
                }
            }
        }
    } = IqRes,

    % verify C1 gets the comment
    RecvMsg = ha_client:wait_for(C1,
        fun (P) ->
            case P of
                #pb_packet{stanza = #pb_msg{payload = #pb_feed_item{}}} -> true;
                _Any -> false
            end
        end),

    #pb_packet{
        stanza = #pb_msg{
            type = headline,
            to_uid = ?UID1_INT,
            payload = #pb_feed_item{
                action = publish,
                item = #pb_comment{
                    id = ?COMMENT_ID1,
                    post_id = ?POST_ID1,
                    publisher_uid = ?UID2_INT,
                    publisher_name = ?NAME2,
                    payload = ?PAYLOAD1
                }
            }
        }
    } = RecvMsg,
    ok.
