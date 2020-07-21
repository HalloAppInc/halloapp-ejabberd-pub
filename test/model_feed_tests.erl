%%%-------------------------------------------------------------------
%%% File: model_feed_tests.erl
%%%
%%% Copyright (C) 2020, Halloapp Inc.
%%%
%%%-------------------------------------------------------------------

-module(model_feed_tests).
-author('murali').

-include_lib("eunit/include/eunit.hrl").
-include("feed.hrl").

-define(UID1, <<"1000000000376503286">>).
-define(UID2, <<"1000000000457424539">>).

-define(POST_ID1, <<"P1">>).
-define(PAYLOAD1, <<"payload1">>).

-define(POST_ID2, <<"P2">>).
-define(PAYLOAD2, <<"payload2">>).

-define(COMMENT_ID1, <<"C1">>).
-define(COMMENT_PAYLOAD1, <<"comment_payload1">>).

-define(COMMENT_ID2, <<"C2">>).
-define(COMMENT_PAYLOAD2, <<"comment_payload2">>).

-define(COMMENT_ID3, <<"C3">>).
-define(COMMENT_PAYLOAD3, <<"comment_payload3">>).

-define(COMMENT_ID4, <<"C4">>).
-define(COMMENT_PAYLOAD4, <<"comment_payload4">>).

%% The setup is as follows:
%% There are two posts: P1 (by U1) and P2 (by U2).
%% There are a total of 4 comments: C1, C2, C3 and C4.
%% C1, C3 are posted by U1 on P1.
%% C2 is posted by U2 on P1 and C4 is also by U2 on P2.


setup() ->
    redis_sup:start_link(),
    clear(),
    ok.


clear() ->
    ok = gen_server:cast(redis_feed_client, flushdb).


keys_test() ->
    setup(),
    ?assertEqual(<<"fp:{P1}">>, model_feed:post_key(?POST_ID1)),
    ?assertEqual(<<"fc:{P1}:C1">>, model_feed:comment_key(?COMMENT_ID1, ?POST_ID1)),
    ?assertEqual(<<"fpc:{P1}">>, model_feed:post_comments_key(?POST_ID1)),
    ?assertEqual(<<"rfp:{1000000000376503286}">>, model_feed:reverse_post_key(?UID1)),
    ok.


publish_post_test() ->
    setup(),
    ?assertEqual({error, missing}, model_feed:get_post(?POST_ID1)),
    Timestamp1 = util:now_ms(),
    ok = model_feed:publish_post(?POST_ID1, ?UID1, ?PAYLOAD1, Timestamp1),
    ExpectedPost = get_post1(Timestamp1),
    {ok, ActualPost} = model_feed:get_post(?POST_ID1),
    ?assertEqual(ExpectedPost, ActualPost),
    ?assertEqual({ok, true}, model_feed:is_post_owner(?POST_ID1, ?UID1)),
    ?assertEqual({ok, false}, model_feed:is_post_owner(?POST_ID1, ?UID2)),
    ok.


publish_comment_test() ->
    setup(),
    Timestamp1 = util:now_ms(),
    ok = model_feed:publish_post(?POST_ID1, ?UID1, ?PAYLOAD1, Timestamp1),
    ?assertEqual({error, missing}, model_feed:get_comment(?COMMENT_ID1, ?POST_ID1)),
    ok = model_feed:publish_comment(?COMMENT_ID1, ?POST_ID1,
            ?UID1, <<>>, ?COMMENT_PAYLOAD1, Timestamp1),
    ExpectedComment = get_comment1(Timestamp1),
    {ok, ActualComment} = model_feed:get_comment(?COMMENT_ID1, ?POST_ID1),
    ?assertEqual(ExpectedComment, ActualComment),
    ok.


retract_post_test() ->
    setup(),
    Timestamp1 = util:now_ms(),
    ok = model_feed:publish_post(?POST_ID1, ?UID1, ?PAYLOAD1, Timestamp1),
    ok = model_feed:retract_post(?POST_ID1, ?UID1),
    ?assertEqual({error, missing}, model_feed:get_post(?POST_ID1)),
    ok.


retract_comment_test() ->
    setup(),
    Timestamp1 = util:now_ms(),
    ok = model_feed:publish_post(?POST_ID1, ?UID1, ?PAYLOAD1, Timestamp1),
    ok = model_feed:publish_comment(?COMMENT_ID1, ?POST_ID1,
            ?UID1, <<>>, ?COMMENT_PAYLOAD1, Timestamp1),
    ok = model_feed:retract_comment(?COMMENT_ID1, ?POST_ID1),
    ?assertEqual({error, missing}, model_feed:get_comment(?COMMENT_ID1, ?POST_ID1)),
    ok.


get_post_and_comment_test() ->
    setup(),
    Timestamp1 = util:now_ms(),
    ok = model_feed:publish_post(?POST_ID1, ?UID1, ?PAYLOAD1, Timestamp1),
    ok = model_feed:publish_comment(?COMMENT_ID1, ?POST_ID1,
            ?UID1, <<>>, ?COMMENT_PAYLOAD1, Timestamp1),
    Post1 = get_post1(Timestamp1),
    Comment1 = get_comment1(Timestamp1),
    ?assertEqual(
        [{ok, Post1}, {ok, Comment1}], model_feed:get_post_and_comment(?POST_ID1, ?COMMENT_ID1)),
    ?assertEqual(
        [{ok, Post1}, {error, missing}], model_feed:get_post_and_comment(?POST_ID1, ?COMMENT_ID2)),
    ?assertEqual(
        [{error, missing}, {error, missing}], model_feed:get_post_and_comment(?POST_ID2, ?COMMENT_ID4)),
    ok.


get_user_feed_test() ->
    setup(),
    Timestamp1 = util:now_ms() - ?WEEKS_MS - ?HOURS_MS,
    Timestamp2 = util:now_ms(),
    ok = model_feed:publish_post(?POST_ID1, ?UID1, ?PAYLOAD1, Timestamp1),
    ok = model_feed:publish_comment(?COMMENT_ID1, ?POST_ID1,
            ?UID1, <<>>, ?COMMENT_PAYLOAD1, Timestamp1),
    ok = model_feed:publish_comment(?COMMENT_ID2, ?POST_ID1,
            ?UID2, ?COMMENT_ID1, ?COMMENT_PAYLOAD2, Timestamp1),
    ok = model_feed:publish_comment(?COMMENT_ID3, ?POST_ID1,
            ?UID1, ?COMMENT_ID2, ?COMMENT_PAYLOAD3, Timestamp1),

    ok = model_feed:publish_post(?POST_ID2, ?UID1, ?PAYLOAD2, Timestamp2),
    ok = model_feed:publish_comment(?COMMENT_ID4, ?POST_ID2,
            ?UID2, <<>>, ?COMMENT_PAYLOAD4, Timestamp2),

    Post1 = get_post1(Timestamp1),
    Comment1 = get_comment1(Timestamp1),
    Comment2 = get_comment2(Timestamp1),
    Comment3 = get_comment3(Timestamp1),

    Post2 = get_post2(Timestamp2),
    Comment4 = get_comment4(Timestamp2),
    
    FeedItems_7Day = [Post2, Comment4],
    ?assertEqual({ok, FeedItems_7Day}, model_feed:get_7day_user_feed(?UID1)),

    FeedItems_30Day = [Post1, Post2, Comment1, Comment2, Comment3, Comment4],
    ?assertEqual({ok, FeedItems_30Day}, model_feed:get_entire_user_feed(?UID1)),
    ok.


clean_up_old_posts_test() ->
    setup(),
    Timestamp1 = util:now_ms() - ?POST_TTL_MS - ?HOURS_MS,
    Timestamp2 = util:now_ms(),
    ok = model_feed:publish_post(?POST_ID1, ?UID1, ?PAYLOAD1, Timestamp1),
    ok = model_feed:publish_comment(?COMMENT_ID1, ?POST_ID1,
            ?UID1, <<>>, ?COMMENT_PAYLOAD1, Timestamp1),
    ok = model_feed:publish_comment(?COMMENT_ID2, ?POST_ID1,
            ?UID2, ?COMMENT_ID1, ?COMMENT_PAYLOAD2, Timestamp1),
    ok = model_feed:publish_comment(?COMMENT_ID3, ?POST_ID1,
            ?UID1, ?COMMENT_ID2, ?COMMENT_PAYLOAD3, Timestamp1),

    ok = model_feed:publish_post(?POST_ID2, ?UID1, ?PAYLOAD2, Timestamp2),
    ok = model_feed:publish_comment(?COMMENT_ID4, ?POST_ID2,
            ?UID2, <<>>, ?COMMENT_PAYLOAD4, Timestamp2),

    ok = model_feed:cleanup_old_posts(?UID1),

    ExpectedPost = get_post2(Timestamp2),
    {ok, ActualPost} = model_feed:get_post(?POST_ID2),
    ExpectedComment = get_comment4(Timestamp2),
    {ok, ActualComment} = model_feed:get_comment(?COMMENT_ID4, ?POST_ID2),

    ?assertEqual(ExpectedPost, ActualPost),
    ?assertEqual(ExpectedComment, ActualComment),
    ?assertEqual({ok, [ExpectedPost, ExpectedComment]}, model_feed:get_entire_user_feed(?UID1)),

    ok = model_feed:remove_all_user_posts(?UID1),
    ?assertEqual({ok, []}, model_feed:get_entire_user_feed(?UID1)),
    ok.



%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%                      Helper functions                                  %%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

get_post1(Timestamp) ->
    #post{id = ?POST_ID1, uid = ?UID1, payload = ?PAYLOAD1, ts_ms = Timestamp}.

get_post2(Timestamp) ->
    #post{id = ?POST_ID2, uid = ?UID1, payload = ?PAYLOAD2, ts_ms = Timestamp}.

get_comment1(Timestamp) ->
    #comment{id = ?COMMENT_ID1, post_id = ?POST_ID1,
            publisher_uid = ?UID1, parent_id = <<>>,
            payload = ?COMMENT_PAYLOAD1, ts_ms = Timestamp}.

get_comment2(Timestamp) ->
    #comment{id = ?COMMENT_ID2, post_id = ?POST_ID1,
            publisher_uid = ?UID2, parent_id = ?COMMENT_ID1,
            payload = ?COMMENT_PAYLOAD2, ts_ms = Timestamp}.

get_comment3(Timestamp) ->
    #comment{id = ?COMMENT_ID3, post_id = ?POST_ID1,
            publisher_uid = ?UID1, parent_id = ?COMMENT_ID2,
            payload = ?COMMENT_PAYLOAD3, ts_ms = Timestamp}.

get_comment4(Timestamp) ->
    #comment{id = ?COMMENT_ID4, post_id = ?POST_ID2,
            publisher_uid = ?UID2, parent_id = <<>>,
            payload = ?COMMENT_PAYLOAD4, ts_ms = Timestamp}.

