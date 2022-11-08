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
-define(UID3, <<"1000000000231454777">>).

-define(POST_ID1, <<"P1">>).
-define(PAYLOAD1, <<"payload1">>).

-define(POST_ID2, <<"P2">>).
-define(PAYLOAD2, <<"payload2">>).

-define(POST_ID3, <<"P3">>).
-define(PAYLOAD3, <<"payload3">>).

-define(COMMENT_ID1, <<"C1">>).
-define(COMMENT_PAYLOAD1, <<"comment_payload1">>).

-define(COMMENT_ID2, <<"C2">>).
-define(COMMENT_PAYLOAD2, <<"comment_payload2">>).

-define(COMMENT_ID3, <<"C3">>).
-define(COMMENT_PAYLOAD3, <<"comment_payload3">>).

-define(COMMENT_ID4, <<"C4">>).
-define(COMMENT_PAYLOAD4, <<"comment_payload4">>).

-define(COMMENT_ID5, <<"C5">>).
-define(COMMENT_PAYLOAD5, <<"comment_payload5">>).

-define(GID1, <<"g1">>).

-define(POST_BLOB_ID, <<"PB">>).
-define(POST_BLOB_PAYLOAD, <<"PB_PAYLOAD">>).
-define(POST_BLOB_EXPIRE_DAYS, 1).

-define(PSA_TAG1, <<"psa_tag1">>).
-define(MOMENT_TAG, <<"moment_tag">>).

%% The setup is as follows:
%% There are two posts: P1 (by U1) and P2 (by U2).
%% There are a total of 4 comments: C1, C2, C3 and C4.
%% C1, C3 are posted by U1 on P1.
%% C2 is posted by U2 on P1 and C4 is also by U2 on P2.


setup() ->
    tutil:setup(),
    ha_redis:start(),
    clear(),
    ok.


clear() ->
    tutil:cleardb(redis_feed).


keys_test() ->
    setup(),
    ?assertEqual(<<"fp:{P1}">>, model_feed:post_key(?POST_ID1)),
    ?assertEqual(<<"fpa:{P1}">>, model_feed:post_audience_key(?POST_ID1)),
    ?assertEqual(<<"fc:{P1}:C1">>, model_feed:comment_key(?COMMENT_ID1, ?POST_ID1)),
    ?assertEqual(<<"fpc:{P1}">>, model_feed:post_comments_key(?POST_ID1)),
    ?assertEqual(<<"rfp:{1000000000376503286}">>, model_feed:reverse_post_key(?UID1)),
    ?assertEqual(<<"rfg:{g1}">>, model_feed:reverse_group_post_key(?GID1)),
    ok.


publish_post_test() ->
    setup(),
    ?assertEqual({error, missing}, model_feed:get_post(?POST_ID1)),
    Timestamp1 = util:now_ms(),
    ok = model_feed:publish_post(?POST_ID1, ?UID1, ?PAYLOAD1, empty, all, [?UID1, ?UID2], Timestamp1),
    ExpectedPost = get_post1(Timestamp1),
    {ok, ActualPost} = model_feed:get_post(?POST_ID1),
    ?assertEqual(ExpectedPost, ActualPost),
    ?assertEqual({ok, true}, model_feed:is_post_owner(?POST_ID1, ?UID1)),
    ?assertEqual({ok, false}, model_feed:is_post_owner(?POST_ID1, ?UID2)),
    ok.

publish_post2_test() ->
    setup(),
    ?assertEqual({error, missing}, model_feed:get_post(?POST_ID1)),
    Timestamp1 = util:now_ms(),
    ok = model_feed:publish_post(?POST_ID1, ?UID1, ?PAYLOAD1, empty, only, [], Timestamp1),
    Post1 = get_post1(Timestamp1),
    ExpectedPost = Post1#post{audience_type = only, audience_list = []},
    {ok, ActualPost} = model_feed:get_post(?POST_ID1),
    ?assertEqual(ExpectedPost, ActualPost),
    ?assertEqual({ok, true}, model_feed:is_post_owner(?POST_ID1, ?UID1)),
    ?assertEqual({ok, false}, model_feed:is_post_owner(?POST_ID1, ?UID2)),
    ok.


publish_group_post_test() ->
    setup(),
    ?assertEqual({error, missing}, model_feed:get_post(?POST_ID1)),
    Timestamp1 = util:now_ms(),
    ok = model_feed:publish_post(?POST_ID1, ?UID1, ?PAYLOAD1, empty, all, [?UID1, ?UID2], Timestamp1, ?GID1),
    ExpectedPost = get_post1(?GID1, Timestamp1),
    {ok, ActualPost} = model_feed:get_post(?POST_ID1),
    ?assertEqual(ExpectedPost, ActualPost),
    ?assertEqual({ok, true}, model_feed:is_post_owner(?POST_ID1, ?UID1)),
    ?assertEqual({ok, false}, model_feed:is_post_owner(?POST_ID1, ?UID2)),
    ok.


publish_comment_test() ->
    setup(),
    Timestamp1 = util:now_ms(),
    ok = model_feed:publish_post(?POST_ID1, ?UID1, ?PAYLOAD1, empty, all, [?UID1, ?UID2], Timestamp1),
    ?assertEqual({error, missing}, model_feed:get_comment(?COMMENT_ID1, ?POST_ID1)),
    ok = model_feed:publish_comment(?COMMENT_ID1, ?POST_ID1,
            ?UID1, undefined, ?COMMENT_PAYLOAD1, Timestamp1),
    ExpectedComment = get_comment1(Timestamp1),
    {ok, ActualComment} = model_feed:get_comment(?COMMENT_ID1, ?POST_ID1),
    ?assertEqual(ExpectedComment, ActualComment),
    ok.


retract_post_test() ->
    setup(),
    Timestamp1 = util:now_ms(),
    %% Delete post with comments.
    ?assertEqual(false, model_feed:is_post_deleted(?POST_ID1)),
    ok = model_feed:publish_post(?POST_ID1, ?UID1, ?PAYLOAD1, empty, all, [?UID1, ?UID2], Timestamp1),
    ok = model_feed:publish_comment(?COMMENT_ID1, ?POST_ID1,
            ?UID1, undefined, ?COMMENT_PAYLOAD1, Timestamp1),

    ?assertEqual(false, model_feed:is_post_deleted(?POST_ID1)),
    ok = model_feed:retract_post(?POST_ID1, ?UID1),
    ?assertEqual({error, missing}, model_feed:get_comment(?COMMENT_ID1, ?POST_ID1)),
    ?assertEqual({error, missing}, model_feed:get_post(?POST_ID1)),
    ?assertEqual(true, model_feed:is_post_deleted(?POST_ID1)),

    %% Delete post without comments.
    ?assertEqual(false, model_feed:is_post_deleted(?POST_ID2)),
    ok = model_feed:publish_post(?POST_ID2, ?UID1, ?PAYLOAD2, empty, all, [?UID1, ?UID2], Timestamp1),
    ?assertEqual(false, model_feed:is_post_deleted(?POST_ID2)),
    ok = model_feed:retract_post(?POST_ID2, ?UID1),
    ?assertEqual({error, missing}, model_feed:get_post(?POST_ID2)),
    ?assertEqual(true, model_feed:is_post_deleted(?POST_ID2)),
    ok.


retract_comment_test() ->
    setup(),
    Timestamp1 = util:now_ms(),
    ok = model_feed:publish_post(?POST_ID1, ?UID1, ?PAYLOAD1, empty, all, [?UID1, ?UID2], Timestamp1),
    ok = model_feed:publish_comment(?COMMENT_ID1, ?POST_ID1,
            ?UID1, undefined, ?COMMENT_PAYLOAD1, Timestamp1),

    ok = model_feed:retract_comment(?COMMENT_ID1, ?POST_ID1),
    ?assertEqual({error, missing}, model_feed:get_comment(?COMMENT_ID1, ?POST_ID1)),
    ok.


get_comment_data_test() ->
    setup(),
    Timestamp1 = util:now_ms(),
    ok = model_feed:publish_post(?POST_ID1, ?UID1, ?PAYLOAD1, empty, all, [?UID1, ?UID2], Timestamp1),
    ok = model_feed:publish_comment(?COMMENT_ID1, ?POST_ID1,
            ?UID1, undefined, ?COMMENT_PAYLOAD1, Timestamp1),
    Post1 = get_post1(Timestamp1),
    Comment1 = get_comment1(Timestamp1),
    ?assertEqual(
        {{ok, Post1}, {ok, Comment1}, {ok, [?UID1]}},
        model_feed:get_comment_data(?POST_ID1, ?COMMENT_ID1, undefined)),
    ?assertEqual(
        {{ok, Post1}, {error, missing}, {ok, [?UID1]}},
        model_feed:get_comment_data(?POST_ID1, ?COMMENT_ID2, undefined)),
    ?assertEqual(
        {{error, missing}, {error, missing}, {error, missing}},
        model_feed:get_comment_data(?POST_ID2, ?COMMENT_ID4, undefined)),
    ok.


get_comment_push_data_test() ->
    setup(),
    Timestamp1 = util:now_ms(),
    ok = model_feed:publish_post(?POST_ID1, ?UID1, ?PAYLOAD1, empty, all, [?UID1, ?UID2], Timestamp1),
    ok = model_feed:publish_comment(?COMMENT_ID1, ?POST_ID1,
            ?UID3, undefined, ?COMMENT_PAYLOAD1, Timestamp1),
    ok = model_feed:publish_comment(?COMMENT_ID2, ?POST_ID1,
            ?UID2, ?COMMENT_ID1, ?COMMENT_PAYLOAD2, Timestamp1),

    {_, _, {ok, Comment0PushList1}} = model_feed:get_comment_data(?POST_ID1, ?COMMENT_ID1, undefined),
    Comment0PushList2 = model_feed:get_comment_push_data(undefined, ?POST_ID1),
    Comment0UidsList = [?UID1],
    ?assertEqual(lists:sort(Comment0UidsList), lists:sort(Comment0PushList1)),
    ?assertEqual(lists:sort(Comment0UidsList), lists:sort(Comment0PushList2)),

    {_, _, {ok, Comment1PushList1}} = model_feed:get_comment_data(?POST_ID1, ?COMMENT_ID2, ?COMMENT_ID1),
    Comment1PushList2 = model_feed:get_comment_push_data(?COMMENT_ID1, ?POST_ID1),
    Comment1UidsList = [?UID1, ?UID3],
    ?assertEqual(lists:sort(Comment1UidsList), lists:sort(Comment1PushList1)),
    ?assertEqual(lists:sort(Comment1UidsList), lists:sort(Comment1PushList2)),

    {_, _, {ok, Comment2PushList1}} = model_feed:get_comment_data(?POST_ID1, ?COMMENT_ID3, ?COMMENT_ID2),
    Comment2PushList2 = model_feed:get_comment_push_data(?COMMENT_ID2, ?POST_ID1),
    Comment2UidsList = [?UID1, ?UID2, ?UID3],
    ?assertEqual(lists:sort(Comment2UidsList), lists:sort(Comment2PushList1)),
    ?assertEqual(lists:sort(Comment2UidsList), lists:sort(Comment2PushList2)),
    ok.


get_post_and_its_comments_test() ->
    setup(),

    %% Ensure post and its comments do not exist.
    ?assertEqual({error, missing}, model_feed:get_post_and_its_comments(?POST_ID1)),

    Timestamp1 = util:now_ms(),
    Post1 = get_post1(Timestamp1),
    Comment1 = get_comment1(Timestamp1),
    Comment2 = get_comment2(Timestamp1),
    Comment3 = get_comment3(Timestamp1),

    %% Publish post and check.
    ok = model_feed:publish_post(?POST_ID1, ?UID1, ?PAYLOAD1, empty, all, [?UID1, ?UID2], Timestamp1),
    ?assertEqual({ok, {Post1, []}}, model_feed:get_post_and_its_comments(?POST_ID1)),

    %% Publish 1st comment and check.
    ok = model_feed:publish_comment(?COMMENT_ID1, ?POST_ID1,
            ?UID1, undefined, ?COMMENT_PAYLOAD1, Timestamp1),
    {ok, {Post1, ActualComments1}} = model_feed:get_post_and_its_comments(?POST_ID1),
    ?assertEqual(lists:sort([Comment1]), ActualComments1),

    %% Publish 2nd comment and check.
    ok = model_feed:publish_comment(?COMMENT_ID2, ?POST_ID1,
            ?UID2, ?COMMENT_ID1, ?COMMENT_PAYLOAD2, Timestamp1),
    {ok, {Post1, ActualComments2}} = model_feed:get_post_and_its_comments(?POST_ID1),
    ?assertEqual(lists:sort([Comment1, Comment2]), ActualComments2),

    %% Publish 3rd comment and check.
    ok = model_feed:publish_comment(?COMMENT_ID3, ?POST_ID1,
            ?UID1, ?COMMENT_ID2, ?COMMENT_PAYLOAD3, Timestamp1),
    {ok, {Post1, ActualComments3}} = model_feed:get_post_and_its_comments(?POST_ID1),
    ?assertEqual(lists:sort([Comment1, Comment2, Comment3]), ActualComments3),
    ok.


get_posts_from_bucket_test() ->
    setup(),
    Timestamp1 = util:now_ms() - (3600 * 1000),
    Timestamp2 = util:now_ms(),
    %% Publish post and check.
    ok = model_feed:publish_post(?POST_ID1, ?UID1, ?PAYLOAD1, public_moment, all, [?UID1, ?UID2], Timestamp1),
    ok = model_feed:publish_post(?POST_ID2, ?UID1, ?PAYLOAD2, public_moment, except, [?UID2], Timestamp2),

    TimestampHr1 = floor(Timestamp1 / (3600 * 1000)),
    Posts1 = model_feed:get_posts_by_time_bucket(TimestampHr1, TimestampHr1, undefined, 10, 10, []),
    ?assertEqual(1, length(Posts1)),
    TimestampHr2 = floor(Timestamp2 / (3600 * 1000)),
    Posts2 = model_feed:get_posts_by_time_bucket(TimestampHr2, TimestampHr2, undefined, 10, 10, []),
    ?assertEqual(2, length(Posts2)),
    Posts3 = model_feed:get_posts_by_time_bucket(TimestampHr2, TimestampHr2, ?POST_ID2, 10, 10, []),
    ?assertEqual(1, length(Posts3)),
    ok.


comment_subs_test() ->
    setup(),
    Timestamp1 = util:now_ms(),
    ok = model_feed:publish_post(?POST_ID1, ?UID1, ?PAYLOAD1, empty, all, [?UID1, ?UID2], Timestamp1),
    ok = model_feed:publish_comment(?COMMENT_ID1, ?POST_ID1,
            ?UID1, undefined, ?COMMENT_PAYLOAD1, Timestamp1),
    ok = model_feed:publish_comment(?COMMENT_ID2, ?POST_ID1,
            ?UID2, ?COMMENT_ID1, ?COMMENT_PAYLOAD2, Timestamp1),
    ok = model_feed:publish_comment(?COMMENT_ID3, ?POST_ID1,
            ?UID1, ?COMMENT_ID2, ?COMMENT_PAYLOAD3, Timestamp1),

    Post1 = get_post1(Timestamp1),
    Comment1 = get_comment1(Timestamp1),
    Comment2 = get_comment2(Timestamp1),
    Comment3 = get_comment3(Timestamp1),

    ?assertEqual(
        {{ok, Post1}, {ok, Comment1}, {ok, [?UID1]}},
        model_feed:get_comment_data(?POST_ID1, ?COMMENT_ID1, undefined)),
    ?assertEqual(
        {{ok, Post1}, {ok, Comment2}, {ok, [?UID1]}},
        model_feed:get_comment_data(?POST_ID1, ?COMMENT_ID2, ?COMMENT_ID1)),
    ?assertEqual(
        {{ok, Post1}, {ok, Comment3}, {ok, [?UID1, ?UID2]}},
        model_feed:get_comment_data(?POST_ID1, ?COMMENT_ID3, ?COMMENT_ID2)),
    ok.


get_user_feed_test() ->
    setup(),
    Timestamp1 = util:now_ms() - ?WEEKS_MS - ?HOURS_MS,
    Timestamp2 = util:now_ms(),
    ok = model_feed:publish_post(?POST_ID1, ?UID1, ?PAYLOAD1, empty, all, [?UID1, ?UID2], Timestamp1),
    ok = model_feed:publish_comment(?COMMENT_ID1, ?POST_ID1,
            ?UID1, undefined, ?COMMENT_PAYLOAD1, Timestamp1),
    ok = model_feed:publish_comment(?COMMENT_ID2, ?POST_ID1,
            ?UID2, ?COMMENT_ID1, ?COMMENT_PAYLOAD2, Timestamp1),
    ok = model_feed:publish_comment(?COMMENT_ID3, ?POST_ID1,
            ?UID1, ?COMMENT_ID2, ?COMMENT_PAYLOAD3, Timestamp1),

    ok = model_feed:publish_post(?POST_ID2, ?UID1, ?PAYLOAD2, empty, except, [?UID2], Timestamp2),
    ok = model_feed:publish_comment(?COMMENT_ID4, ?POST_ID2,
            ?UID2, undefined, ?COMMENT_PAYLOAD4, Timestamp2),

    ok = model_feed:publish_post(?POST_ID3, ?UID1, ?PAYLOAD3, empty, except, [?UID2], Timestamp2, ?GID1),
    ok = model_feed:publish_comment(?COMMENT_ID5, ?POST_ID3,
            ?UID2, undefined, ?COMMENT_PAYLOAD5, Timestamp2),

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

    Post3 = get_post3(?GID1, Timestamp2),
    Comment5 = get_comment5(Timestamp2),
    ?assertEqual({ok, [Post3, Comment5]}, model_feed:get_entire_group_feed(?GID1)),
    ok.

get_group_feed_test() ->
    setup(),
    Timestamp1 = util:now_ms() - ?WEEKS_MS - ?HOURS_MS,
    Timestamp2 = util:now_ms(),
    ok = model_feed:publish_post(?POST_ID1, ?UID1, ?PAYLOAD1, empty, all, [?UID1, ?UID2], Timestamp1, ?GID1),
    ok = model_feed:publish_comment(?COMMENT_ID1, ?POST_ID1,
            ?UID1, undefined, ?COMMENT_PAYLOAD1, Timestamp1),
    ok = model_feed:publish_comment(?COMMENT_ID2, ?POST_ID1,
            ?UID2, ?COMMENT_ID1, ?COMMENT_PAYLOAD2, Timestamp1),
    ok = model_feed:publish_comment(?COMMENT_ID3, ?POST_ID1,
            ?UID1, ?COMMENT_ID2, ?COMMENT_PAYLOAD3, Timestamp1),

    ok = model_feed:publish_post(?POST_ID2, ?UID1, ?PAYLOAD2, empty, except, [?UID2], Timestamp2, ?GID1),
    ok = model_feed:publish_comment(?COMMENT_ID4, ?POST_ID2,
            ?UID2, undefined, ?COMMENT_PAYLOAD4, Timestamp2),

    ok = model_feed:publish_post(?POST_ID3, ?UID1, ?PAYLOAD3, empty, except, [?UID2], Timestamp2),
    ok = model_feed:publish_comment(?COMMENT_ID5, ?POST_ID3,
            ?UID2, undefined, ?COMMENT_PAYLOAD5, Timestamp2),

    Post1 = get_post1(?GID1, Timestamp1),
    Comment1 = get_comment1(Timestamp1),
    Comment2 = get_comment2(Timestamp1),
    Comment3 = get_comment3(Timestamp1),

    Post2 = get_post2(?GID1, Timestamp2),
    Comment4 = get_comment4(Timestamp2),

    FeedItems_7Day = [Post2, Comment4],
    ?assertEqual({ok, FeedItems_7Day}, model_feed:get_7day_group_feed(?GID1)),

    FeedItems_30Day = [Post1, Post2, Comment1, Comment2, Comment3, Comment4],
    ?assertEqual({ok, FeedItems_30Day}, model_feed:get_entire_group_feed(?GID1)),

    Post3 = get_post3(Timestamp2),
    Comment5 = get_comment5(Timestamp2),
    ?assertEqual({ok, [Post3, Comment5]}, model_feed:get_entire_user_feed(?UID1)),
    ok.


cleanup_reverse_index_test() ->
    setup(),
    Timestamp1 = util:now_ms() - ?POST_TTL_MS - ?HOURS_MS,
    Timestamp2 = util:now_ms(),
    ok = model_feed:publish_post(?POST_ID1, ?UID1, ?PAYLOAD1, empty, all, [?UID1, ?UID2], Timestamp1),
    ok = model_feed:publish_comment(?COMMENT_ID1, ?POST_ID1,
            ?UID1, undefined, ?COMMENT_PAYLOAD1, Timestamp1),
    ok = model_feed:publish_comment(?COMMENT_ID2, ?POST_ID1,
            ?UID2, ?COMMENT_ID1, ?COMMENT_PAYLOAD2, Timestamp1),
    ok = model_feed:publish_comment(?COMMENT_ID3, ?POST_ID1,
            ?UID1, ?COMMENT_ID2, ?COMMENT_PAYLOAD3, Timestamp1),

    ok = model_feed:publish_post(?POST_ID2, ?UID1, ?PAYLOAD2, empty, except, [?UID2], Timestamp2),
    ok = model_feed:publish_comment(?COMMENT_ID4, ?POST_ID2,
            ?UID2, undefined, ?COMMENT_PAYLOAD4, Timestamp2),

    ok = model_feed:cleanup_reverse_index(?UID1),

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


cleanup_group_reverse_index_test() ->
    setup(),
    Timestamp1 = util:now_ms() - ?POST_TTL_MS - ?HOURS_MS,
    Timestamp2 = util:now_ms(),
    ok = model_feed:publish_post(?POST_ID1, ?UID1, ?PAYLOAD1, empty, all, [?UID1, ?UID2], Timestamp1, ?GID1),
    ok = model_feed:publish_comment(?COMMENT_ID1, ?POST_ID1,
            ?UID1, undefined, ?COMMENT_PAYLOAD1, Timestamp1),
    ok = model_feed:publish_comment(?COMMENT_ID2, ?POST_ID1,
            ?UID2, ?COMMENT_ID1, ?COMMENT_PAYLOAD2, Timestamp1),
    ok = model_feed:publish_comment(?COMMENT_ID3, ?POST_ID1,
            ?UID1, ?COMMENT_ID2, ?COMMENT_PAYLOAD3, Timestamp1),

    ok = model_feed:publish_post(?POST_ID2, ?UID1, ?PAYLOAD2, empty, except, [?UID2], Timestamp2, ?GID1),
    ok = model_feed:publish_comment(?COMMENT_ID4, ?POST_ID2,
            ?UID2, undefined, ?COMMENT_PAYLOAD4, Timestamp2),

    ok = model_feed:cleanup_group_reverse_index(?GID1),

    ExpectedPost = get_post2(?GID1, Timestamp2),
    {ok, ActualPost} = model_feed:get_post(?POST_ID2),
    ExpectedComment = get_comment4(Timestamp2),
    {ok, ActualComment} = model_feed:get_comment(?COMMENT_ID4, ?POST_ID2),

    ?assertEqual(ExpectedPost, ActualPost),
    ?assertEqual(ExpectedComment, ActualComment),
    ?assertEqual({ok, [ExpectedPost, ExpectedComment]}, model_feed:get_entire_group_feed(?GID1)),
    ok.


update_audience_test() ->
    setup(),
    Timestamp1 = util:now_ms(),
    ok = model_feed:publish_post(?POST_ID1, ?UID1, ?PAYLOAD1, empty, all, [?UID1], Timestamp1),
    ExpectedPost = get_post1(Timestamp1),
    {ok, ActualPost1} = model_feed:get_post(?POST_ID1),
    ?assertNotEqual(ExpectedPost, ActualPost1),

    model_feed:add_uid_to_audience(?UID2, [?POST_ID1]),
    {ok, ActualPost2} = model_feed:get_post(?POST_ID1),
    ?assertEqual(ExpectedPost, ActualPost2),

    model_feed:add_uid_to_audience(?UID1, [?POST_ID1]),
    {ok, ActualPost2} = model_feed:get_post(?POST_ID1),
    ?assertEqual(ExpectedPost, ActualPost2),
    ok.


remove_user_test() ->
    setup(),
    Timestamp1 = util:now_ms() - ?WEEKS_MS - ?HOURS_MS,
    Timestamp2 = util:now_ms(),
    ok = model_feed:publish_post(?POST_ID1, ?UID1, ?PAYLOAD1, empty, all, [?UID1, ?UID2], Timestamp1),
    ok = model_feed:publish_comment(?COMMENT_ID1, ?POST_ID1,
            ?UID1, <<>>, ?COMMENT_PAYLOAD1, Timestamp1),
    ok = model_feed:publish_comment(?COMMENT_ID2, ?POST_ID1,
            ?UID2, ?COMMENT_ID1, ?COMMENT_PAYLOAD2, Timestamp1),
    ok = model_feed:publish_comment(?COMMENT_ID3, ?POST_ID1,
            ?UID1, ?COMMENT_ID2, ?COMMENT_PAYLOAD3, Timestamp1),

    ok = model_feed:publish_post(?POST_ID2, ?UID2, ?PAYLOAD2, empty, except, [?UID1], Timestamp2),
    ok = model_feed:publish_comment(?COMMENT_ID4, ?POST_ID2,
            ?UID1, <<>>, ?COMMENT_PAYLOAD4, Timestamp2),

    ok = model_feed:remove_user(?UID1),
    ?assertEqual({error, missing}, model_feed:get_post(?POST_ID1)),
    ?assertEqual({error, missing}, model_feed:get_comment(?COMMENT_ID1, ?POST_ID1)),
    ?assertEqual({error, missing}, model_feed:get_comment(?COMMENT_ID2, ?POST_ID1)),
    ?assertEqual({error, missing}, model_feed:get_comment(?COMMENT_ID3, ?POST_ID1)),
    ?assertEqual({error, missing}, model_feed:get_comment(?COMMENT_ID4, ?POST_ID2)),
    ?assertEqual({ok, []}, model_feed:get_entire_user_feed(?UID1)),
    ok.

external_share_post_test() ->
    setup(),
    {ok, undefined} = model_feed:get_external_share_post(?POST_BLOB_ID),
    true = model_feed:store_external_share_post(?POST_BLOB_ID, ?POST_BLOB_PAYLOAD, ?POST_BLOB_EXPIRE_DAYS),
    false = model_feed:store_external_share_post(?POST_BLOB_ID, ?POST_BLOB_PAYLOAD, ?POST_BLOB_EXPIRE_DAYS),
    {ok, ?POST_BLOB_PAYLOAD} = model_feed:get_external_share_post(?POST_BLOB_ID),
    ok = model_feed:delete_external_share_post(?POST_BLOB_ID),
    {ok, undefined} = model_feed:get_external_share_post(?POST_BLOB_ID),
    true = model_feed:store_external_share_post(?POST_BLOB_ID, ?POST_BLOB_PAYLOAD, ?POST_BLOB_EXPIRE_DAYS),
    ok = model_feed:delete_external_share_post(?POST_BLOB_ID),
    ok = model_feed:delete_external_share_post(?POST_BLOB_ID),
    ok.

psa_tag_post_test() ->
    setup(),
    false = model_feed:is_psa_tag_done(?PSA_TAG1),
    ok = model_feed:mark_psa_tag_done(?PSA_TAG1),
    true = model_feed:is_psa_tag_done(?PSA_TAG1),

    true = model_feed:del_psa_tag_done(?PSA_TAG1),
    false = model_feed:del_psa_tag_done(?PSA_TAG1),
    ok = model_feed:mark_psa_tag_done(?PSA_TAG1),
    true = model_feed:is_psa_tag_done(?PSA_TAG1),

    ?assertEqual({error, missing}, model_feed:get_post(?POST_ID1)),
    Timestamp1 = util:now_ms(),
    ok = model_feed:publish_psa_post(?POST_ID1, ?UID1, ?PAYLOAD1, empty, ?PSA_TAG1, Timestamp1),
    ExpectedPost = get_post4(Timestamp1),
    {ok, ActualPost} = model_feed:get_post(?POST_ID1),
    ?assertEqual(ExpectedPost, ActualPost),
    ?assertEqual({ok, true}, model_feed:is_post_owner(?POST_ID1, ?UID1)),
    ?assertEqual({ok, false}, model_feed:is_post_owner(?POST_ID1, ?UID2)),
    {ok, [ExpectedPost]} = model_feed:get_psa_tag_posts(?PSA_TAG1),
    ok.
      
moment_tag_test() ->
    setup(),
    false = model_feed:is_moment_tag_done(?MOMENT_TAG),
    ok = model_feed:mark_moment_tag_done(?MOMENT_TAG),
    true = model_feed:is_moment_tag_done(?MOMENT_TAG),
    Hr = model_feed:get_moment_time_to_send(?MOMENT_TAG),
    Hr = model_feed:get_moment_time_to_send(?MOMENT_TAG),
    false = model_feed:set_moment_time_to_send(Hr, ?MOMENT_TAG),
    ok.


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%                      Helper functions                                  %%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

get_post1(Gid, Timestamp) ->
    Post = get_post1(Timestamp),
    Post#post{gid = Gid}.

get_post1(Timestamp) ->
    #post{
        id = ?POST_ID1,
        uid = ?UID1,
        payload = ?PAYLOAD1,
        tag = empty,
        audience_type = all,
        audience_list = [?UID1, ?UID2],
        ts_ms = Timestamp
    }.

get_post2(Gid, Timestamp) ->
    Post = get_post2(Timestamp),
    Post#post{gid = Gid}.

get_post2(Timestamp) ->
    #post{
        id = ?POST_ID2,
        uid = ?UID1,
        payload = ?PAYLOAD2,
        tag = empty,
        audience_type = except,
        audience_list = [?UID2],
        ts_ms = Timestamp
    }.

get_post3(Gid, Timestamp) ->
    Post = get_post3(Timestamp),
    Post#post{gid = Gid}.

get_post3(Timestamp) ->
    #post{
        id = ?POST_ID3,
        uid = ?UID1,
        payload = ?PAYLOAD3,
        tag = empty,
        audience_type = except,
        audience_list = [?UID2],
        ts_ms = Timestamp
    }.

get_post4(Timestamp) ->
    #post{
        id = ?POST_ID1,
        uid = ?UID1,
        payload = ?PAYLOAD1,
        tag = empty,
        audience_type = all,
        audience_list = [],
        ts_ms = Timestamp,
        psa_tag = ?PSA_TAG1
    }.

get_comment1(Timestamp) ->
    #comment{
        id = ?COMMENT_ID1,
        post_id = ?POST_ID1,
        publisher_uid = ?UID1,
        parent_id = undefined,
        comment_type = comment,
        payload = ?COMMENT_PAYLOAD1,
        ts_ms = Timestamp
    }.

get_comment2(Timestamp) ->
    #comment{
        id = ?COMMENT_ID2,
        post_id = ?POST_ID1,
        publisher_uid = ?UID2,
        parent_id = ?COMMENT_ID1,
        comment_type = comment,
        payload = ?COMMENT_PAYLOAD2,
        ts_ms = Timestamp
    }.

get_comment3(Timestamp) ->
    #comment{
    id = ?COMMENT_ID3,
        post_id = ?POST_ID1,
        publisher_uid = ?UID1,
        parent_id = ?COMMENT_ID2,
        comment_type = comment,
        payload = ?COMMENT_PAYLOAD3,
        ts_ms = Timestamp
    }.

get_comment4(Timestamp) ->
    #comment{
        id = ?COMMENT_ID4,
        post_id = ?POST_ID2,
        publisher_uid = ?UID2,
        parent_id = undefined,
        comment_type = comment,
        payload = ?COMMENT_PAYLOAD4,
        ts_ms = Timestamp
    }.

get_comment5(Timestamp) ->
    #comment{
        id = ?COMMENT_ID5,
        post_id = ?POST_ID3,
        publisher_uid = ?UID2,
        parent_id = undefined,
        comment_type = comment,
        payload = ?COMMENT_PAYLOAD5,
        ts_ms = Timestamp
    }.


% get_posts_comments_perf_test() ->
%     tutil:perf(
%         100,
%         fun() -> setup() end,
%         fun() ->
%             setup(),
%             Timestamp1 = util:now_ms(),
%             ok = model_feed:publish_post(?POST_ID1, ?UID1, ?PAYLOAD1, empty, all, [?UID1, ?UID2], Timestamp1),
%             ok = model_feed:publish_comment(?COMMENT_ID1, ?POST_ID1,
%                     ?UID1, ?COMMENT_ID1, ?COMMENT_PAYLOAD1, Timestamp1),
%             ok = model_feed:publish_comment(?COMMENT_ID2, ?POST_ID1,
%                     ?UID2, ?COMMENT_ID2, ?COMMENT_PAYLOAD2, Timestamp1),
%             ok = model_feed:publish_comment(?COMMENT_ID3, ?POST_ID1,
%                     ?UID1, ?COMMENT_ID3, ?COMMENT_PAYLOAD3, Timestamp1),
%             ok = model_feed:publish_comment(?COMMENT_ID4, ?POST_ID1,
%                     ?UID1, ?COMMENT_ID4, ?COMMENT_PAYLOAD4, Timestamp1),
%             ok = model_feed:publish_comment(?COMMENT_ID5, ?POST_ID1,
%                     ?UID1, ?COMMENT_ID5, ?COMMENT_PAYLOAD5, Timestamp1),
%             {ok, _} = model_feed:get_post_and_its_comments(?POST_ID1),
%             ok
%         end
%     ).

