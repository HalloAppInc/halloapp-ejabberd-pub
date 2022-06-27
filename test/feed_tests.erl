-module(feed_tests).

-compile([nowarn_export_all, export_all]).
-include("suite.hrl").
-include("packets.hrl").
-include("account_test_data.hrl").
-include_lib("stdlib/include/assert.hrl").

-define(PAYLOAD1, <<"123">>).
-define(POST_ID1, <<"PostId1">>).
-define(COMMENT_ID1, <<"CommentId1">>).

group() ->
    {feed, [sequence], [
        feed_dummy_test,
        feed_make_post_test,
        feed_make_comment_test,
        feed_retract_comment_test,
        feed_retract_post_test,
        feed_audience_test
    ]}.

dummy_test(_Conf) ->
    ok.

make_post_test(_Conf) ->
    {ok, C1} = ha_client:connect_and_login(?UID1, ?KEYPAIR1),
    {ok, C2} = ha_client:connect_and_login(?UID2, ?KEYPAIR2),
    % UID4 and UID1 are not friends; UID5 has blocked UID1
    PbAudience = struct_util:create_pb_audience(only, [?UID2, ?UID3, ?UID4, ?UID5]),
    PbPost = struct_util:create_pb_post(?POST_ID1, ?UID1, ?NAME1, ?PAYLOAD1, PbAudience, ?TS1),
    PbFeedItem = struct_util:create_feed_item(publish, PbPost),

    IqRes = ha_client:send_iq(C1, set, PbFeedItem),

    % make sure IQ was successful
    #pb_packet{
        stanza = #pb_iq{
            type = result,
            payload = #pb_feed_item{
                action = publish,
                item = #pb_post{
                    id = ?POST_ID1,
                    publisher_uid = ?UID1,
                    publisher_name = ?NAME1,
                    audience = #pb_audience{ type = only }
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
            to_uid = ?UID2,
            payload = #pb_feed_item{
                action = publish,
                item = #pb_post{
                    id = ?POST_ID1,
                    publisher_uid = ?UID1,
                    publisher_name = ?NAME1,
                    payload = ?PAYLOAD1,
                    audience = #pb_audience{ type = only }
                }
            }
        }
    } = RecvMsg,


    {ok, C4} = ha_client:connect_and_login(?UID4, ?KEYPAIR4),
    {ok, C5} = ha_client:connect_and_login(?UID5, ?KEYPAIR5),

    confirm_no_feed_item(C4, #pb_post{id = ?POST_ID1}),
    confirm_no_feed_item(C5, #pb_post{id = ?POST_ID1}),
    ok.


make_comment_test(_Conf) ->
    {ok, C1} = ha_client:connect_and_login(?UID1, ?KEYPAIR1),
    {ok, C2} = ha_client:connect_and_login(?UID2, ?KEYPAIR2),

    % we don't have a parent comment id right now, hence it is left as the default value <<>>
    PbComment1 = struct_util:create_pb_comment(?COMMENT_ID1, ?POST_ID1, <<>>, ?UID2, ?NAME2, ?PAYLOAD1, ?TS2),
    PbFeedItem = struct_util:create_feed_item(publish, PbComment1),

    IqRes = ha_client:send_iq(C2, set, PbFeedItem),
    % make sure IQ was successful, payload is empty here, only timestamp relevant
    #pb_packet{
        stanza = #pb_iq{
            type = result,
            payload = #pb_feed_item{
                action = publish,
                item = #pb_comment{
                    id = ?COMMENT_ID1,
                    post_id = ?POST_ID1,
                    publisher_uid = ?UID2,
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
            to_uid = ?UID1,
            payload = #pb_feed_item{
                action = publish,
                item = #pb_comment{
                    id = ?COMMENT_ID1,
                    post_id = ?POST_ID1,
                    publisher_uid = ?UID2,
                    publisher_name = ?NAME2,
                    payload = ?PAYLOAD1
                }
            }
        }
    } = RecvMsg,

    {ok, C4} = ha_client:connect_and_login(?UID4, ?KEYPAIR4),
    {ok, C5} = ha_client:connect_and_login(?UID5, ?KEYPAIR5),

    confirm_no_feed_item(C4, #pb_comment{id = ?COMMENT_ID1}),
    confirm_no_feed_item(C5, #pb_comment{id = ?COMMENT_ID1}),
    ok.

retract_comment_test(_Conf) ->
    {ok, C2} = ha_client:connect_and_login(?UID2, ?KEYPAIR2),
    {ok, C3} = ha_client:connect_and_login(?UID3, ?KEYPAIR3),

    PbComment1 = struct_util:create_pb_comment(?COMMENT_ID1, ?POST_ID1, <<>>, ?UID2, <<"">>, <<"">>, ?TS3),
    PbFeedItem = struct_util:create_feed_item(retract, PbComment1),

    IqRes = ha_client:send_iq(C2, set, PbFeedItem),

    % make sure IQ was successful
    #pb_packet{
        stanza = #pb_iq{
            type = result,
            payload = #pb_feed_item{
                action = retract,
                item = #pb_comment{
                    id = ?COMMENT_ID1,
                    post_id = ?POST_ID1
                }
            }
        }
    } = IqRes,

    RecvMsg = ha_client:wait_for(C3,
        fun (P) ->
            case P of
                #pb_packet{stanza = #pb_msg{payload = #pb_feed_item{action=retract, item=#pb_comment{}}}} -> true;
                _Any -> false
            end
        end),

    #pb_packet{
        stanza = #pb_msg{
            type = normal,
            payload = #pb_feed_item{
                action = retract,
                item = #pb_comment{
                    id = ?COMMENT_ID1,
                    post_id = ?POST_ID1
                }
            }
        }
    } = RecvMsg,
    ok.

retract_post_test(_Conf) ->
    {ok, C1} = ha_client:connect_and_login(?UID1, ?KEYPAIR1),
    {ok, C2} = ha_client:connect_and_login(?UID2, ?KEYPAIR2),

    PbPost = struct_util:create_pb_post(?POST_ID1, ?UID1, ?NAME1, ?PAYLOAD1, undefined, ?TS1),
    PbFeedItem = struct_util:create_feed_item(retract, PbPost), % retract previous post

    IqRes = ha_client:send_iq(C1, set, PbFeedItem),

    % make sure IQ was successful
    #pb_packet{
        stanza = #pb_iq{
            type = result,
            payload = #pb_feed_item{
                action = retract,
                item = #pb_post{
                    id = ?POST_ID1,
                    publisher_uid = ?UID1,
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
            type = normal,
            to_uid = ?UID2,
            payload = #pb_feed_item{
                action = retract,
                item = #pb_post{
                    id = ?POST_ID1
                }
            }
        }
    } = RecvMsg,
    ok.


audience_test(_Conf) ->
    %% UID1 is friends with UID2 and UID3
    %% UID5 blocked UID1
    %% UID1 is not friends with UID4.
    %% In this test - UID1 makes a post with the rest in the audience.
    %% However, server must distribute the content to only UID2 and UID3.
    {ok, C1} = ha_client:connect_and_login(?UID1, ?KEYPAIR1),
    {ok, C2} = ha_client:connect_and_login(?UID2, ?KEYPAIR2),
    {ok, C3} = ha_client:connect_and_login(?UID3, ?KEYPAIR3),
    {ok, C4} = ha_client:connect_and_login(?UID4, ?KEYPAIR4),
    {ok, C5} = ha_client:connect_and_login(?UID5, ?KEYPAIR5),

    ha_client:wait_for_eoq(C1),
    ha_client:wait_for_eoq(C2),
    ha_client:wait_for_eoq(C3),
    ha_client:wait_for_eoq(C4),
    ha_client:wait_for_eoq(C5),
    ha_client:clear_queue(C1),
    ha_client:clear_queue(C2),
    ha_client:clear_queue(C3),
    ha_client:clear_queue(C4),
    ha_client:clear_queue(C5),

    %% UID1 publishes a post.
    PbAudience = struct_util:create_pb_audience(all, [?UID2, ?UID3, ?UID4, ?UID5]),
    PbPost = struct_util:create_pb_post(?POST_ID1, ?UID1, ?NAME1, ?PAYLOAD1, PbAudience, ?TS1),
    PbFeedItem = struct_util:create_feed_item(publish, PbPost),
    IqRes = ha_client:send_iq(C1, set, PbFeedItem),

    % make sure IQ was successful
    #pb_packet{
        stanza = #pb_iq{
            type = result,
            payload = #pb_feed_item{
                action = publish,
                item = #pb_post{
                    id = ?POST_ID1,
                    publisher_uid = ?UID1,
                    publisher_name = ?NAME1,
                    audience = #pb_audience{ type = all }
                }
            }
        }
    } = IqRes,

    %% UID2 must receive the post.
    RecvMsg1 = ha_client:wait_for(C2,
        fun (P) ->
            case P of
                #pb_packet{stanza = #pb_msg{payload = #pb_feed_item{}}} -> true;
                _Any -> false
            end
        end),
    #pb_packet{
        stanza = #pb_msg{
            type = headline,
            to_uid = ?UID2,
            payload = #pb_feed_item{
                action = publish,
                item = #pb_post{
                    id = ?POST_ID1,
                    publisher_uid = ?UID1,
                    publisher_name = ?NAME1,
                    payload = ?PAYLOAD1,
                    audience = #pb_audience{ type = all }
                }
            }
        }
    } = RecvMsg1,

    %% UID3 must receive the post.
    RecvMsg2 = ha_client:wait_for(C3,
        fun (P) ->
            case P of
                #pb_packet{stanza = #pb_msg{payload = #pb_feed_item{}}} -> true;
                _Any -> false
            end
        end),
    #pb_packet{
        stanza = #pb_msg{
            type = headline,
            to_uid = ?UID3,
            payload = #pb_feed_item{
                action = publish,
                item = #pb_post{
                    id = ?POST_ID1,
                    publisher_uid = ?UID1,
                    publisher_name = ?NAME1,
                    payload = ?PAYLOAD1,
                    audience = #pb_audience{ type = all }
                }
            }
        }
    } = RecvMsg2,

    %% UID4 and UID5 must not receive anything.
    ?assertEqual(undefined, ha_client:recv(C4, 100)),
    ?assertEqual(undefined, ha_client:recv(C5, 100)),
    ok.


confirm_no_feed_item(Client, Item) ->
    ha_client:wait_for_eoq(Client),
    AllMessages = ha_client:recv_all_nb(Client),
    % verify Item is not in the queue
    ?assertNot(lists:any(
        fun(T) ->
            case T of
                #pb_packet{stanza = #pb_msg{payload = #pb_feed_item{item = Item}}} -> true;
                _Any -> false
            end
        end, AllMessages)),
    ok.
