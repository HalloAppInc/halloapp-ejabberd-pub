%%%-------------------------------------------------------------------
%%% File: mod_feed_tests.erl
%%%
%%% Copyright (C) 2020, Halloapp Inc.
%%%
%%%-------------------------------------------------------------------
-module(mod_feed_tests).
-author('murali').

-include("feed.hrl").
-include("packets.hrl").

-include_lib("tutil.hrl").

-define(UID1, <<"1000000000376503286">>).
-define(UID2, <<"1000000000457424539">>).
-define(UID3, <<"1000000000686861254">>).

-define(POST_ID1, <<"P1">>).
-define(PAYLOAD1, <<"payload1">>).
-define(ENC_PAYLOAD1, <<"enc_payload1">>).

-define(POST_ID2, <<"P2">>).
-define(PAYLOAD2, <<"payload2">>).

-define(POST_ID3, <<"P3">>).

-define(COMMENT_ID1, <<"C1">>).
-define(COMMENT_PAYLOAD1, <<"comment_payload1">>).

-define(COMMENT_ID2, <<"C2">>).
-define(COMMENT_PAYLOAD2, <<"comment_payload2">>).

-define(SERVER, <<"s.halloapp.net">>).

-define(ENC_SENDER_STATE2, <<"enc_sender_state2">>).
-define(ENC_SENDER_STATE3, <<"enc_sender_state3">>).


setup() ->
    tutil:setup(),
    stringprep:start(),
    gen_iq_handler:start(ejabberd_local),
    ejabberd_hooks:start_link(),
    ha_redis:start(),
    mod_feed:start(?SERVER, []),
    clear(),
    #{}.


clear() ->
    tutil:cleardb(redis_feed).


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%%%%                   helper functions                           %%%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%


create_sender_state_bundles(SenderStateTuples) ->
    [#pb_sender_state_bundle{uid = Ouid, sender_state = create_sender_state(EncSenderState)}
        || {Ouid, EncSenderState} <- SenderStateTuples].

create_sender_state(EncSenderState) ->
    #pb_sender_state_with_key_info{enc_sender_state = EncSenderState}.


create_post_st(PostId, Uid, Payload, EncPayload, Timestamp, Audience) ->
    #pb_post{
        id = PostId,
        publisher_uid = Uid,
        payload = Payload,
        timestamp = Timestamp,
        audience = Audience,
        enc_payload = EncPayload,
        tag = empty
    }.

create_comment_st(CommentId, PostId, PublisherUid,
        PublisherName, ParentCommentId, Payload, EncPayload, Timestamp) ->
    #pb_comment{
        id = CommentId,
        post_id = PostId,
        publisher_uid = PublisherUid,
        publisher_name = PublisherName,
        parent_comment_id = ParentCommentId,
        payload = Payload,
        timestamp = Timestamp,
        enc_payload = EncPayload
    }.

create_feed_stanza(Action, Item, SharePostsSt, SenderStateBundles) ->
    #pb_feed_item{
        action = Action,
        item = Item,
        share_stanzas = SharePostsSt,
        sender_state_bundles = SenderStateBundles
    }.

create_audience_list_st(undefined, _) ->
    undefined;
create_audience_list_st(AudienceType, AudienceUids) ->
    #pb_audience{
        type = AudienceType,
        uids = AudienceUids
    }.

create_share_post_st(Uid, PostIds, Result, Reason) ->
    #pb_share_stanza{
        uid = Uid,
        post_ids = PostIds,
        result = Result,
        reason = Reason
    }.

get_post_publish_iq(PostId, Uid, Payload, EncPayload, AudienceType, AudienceUids, SenderStateBundles) ->
    Audience = create_audience_list_st(AudienceType, AudienceUids),
    Post = create_post_st(PostId, Uid, Payload, EncPayload, <<>>, Audience),
    FeedStanza = create_feed_stanza(publish, Post, [], SenderStateBundles),
    #pb_iq{
        from_uid = Uid,
        type = set,
        payload = FeedStanza
    }.

get_post_publish_iq_result(PostId, Uid, Payload, EncPayload, AudienceType, Timestamp) ->
    Audience = create_audience_list_st(AudienceType, []),
    Post = create_post_st(PostId, Uid, Payload, EncPayload, Timestamp, Audience),
    FeedStanza = create_feed_stanza(publish, Post, [], []),
    #pb_iq{
        type = result,
        to_uid = Uid,
        payload = FeedStanza
    }.

get_comment_publish_iq(CommentId, PostId, Uid, ParentCommentId, Payload, EncPayload) ->
    Comment = create_comment_st(CommentId, PostId, Uid, <<>>, ParentCommentId, Payload, EncPayload, <<>>),
    FeedStanza = create_feed_stanza(publish, Comment, [], []),
    #pb_iq{
        from_uid = Uid,
        type = set,
        payload = FeedStanza
    }.

get_comment_publish_iq_result(CommentId, PostId, Uid, ParentCommentId, Payload, EncPayload, Timestamp) ->
    Comment = create_comment_st(CommentId, PostId, Uid, <<>>, ParentCommentId, Payload, EncPayload, Timestamp),
    FeedStanza = create_feed_stanza(publish, Comment, [], []),
    #pb_iq{
        type = result,
        to_uid = Uid,
        payload = FeedStanza
    }.

get_post_retract_iq(PostId, Uid) ->
    Post = create_post_st(PostId, Uid, <<>>, <<>>, <<>>, undefined),
    FeedStanza = create_feed_stanza(retract, Post, [], []),
    #pb_iq{
        from_uid = Uid,
        type = set,
        payload = FeedStanza
    }.

get_post_retract_iq_result(PostId, Uid, Timestamp) ->
    Post = create_post_st(PostId, Uid, <<>>, <<>>, Timestamp, undefined),
    FeedStanza = create_feed_stanza(retract, Post, [], []),
    #pb_iq{
        type = result,
        to_uid = Uid,
        payload = FeedStanza
    }.

get_comment_retract_iq(CommentId, PostId, Uid) ->
    Comment = create_comment_st(CommentId, PostId, <<>>, <<>>, <<>>, <<>>, <<>>, <<>>),
    FeedStanza = create_feed_stanza(retract, Comment, [], []),
    #pb_iq{
        from_uid = Uid,
        type = set,
        payload = FeedStanza
    }.

get_comment_retract_iq_result(CommentId, PostId, Uid, Timestamp) ->
    Comment = create_comment_st(CommentId, PostId, Uid, <<>>, <<>>, <<>>, <<>>, Timestamp),
    FeedStanza = create_feed_stanza(retract, Comment, [], []),
    #pb_iq{
        type = result,
        to_uid = Uid,
        payload = FeedStanza
    }.


get_share_iq(Uid, FriendUid, PostIds) ->
    SharePostSt = create_share_post_st(FriendUid, PostIds, <<>>, <<>>),
    FeedStanza = create_feed_stanza(share, undefined, [SharePostSt], []),
    #pb_iq{
        from_uid = Uid,
        type = set,
        payload = FeedStanza
    }.



get_share_iq_result(Uid, FriendUid) ->
    SharePostSt = create_share_post_st(FriendUid, [], <<"ok">>, <<>>),
    FeedStanza = create_feed_stanza(share, undefined, [SharePostSt], []),
    #pb_iq{
        type = result,
        to_uid = Uid,
        payload = FeedStanza
    }.


get_error_iq_result(Reason, Uid) ->
    #pb_iq{
        type = error,
        to_uid = Uid,
        payload = #pb_error_stanza{reason = Reason}
    }.


get_timestamp(#pb_iq{payload = #pb_feed_item{item = #pb_post{timestamp = Timestamp}}}) ->
    Timestamp;
get_timestamp(#pb_iq{payload = #pb_feed_item{item = #pb_comment{timestamp = Timestamp}}}) ->
    Timestamp;
get_timestamp(_) ->
    <<>>.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%%%%                        Tests                                 %%%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%


publish_post_no_audience_error_test() ->
    setup(),
    %% posting a feedpost without audience
    PublishIQ = get_post_publish_iq(?POST_ID1, ?UID1, ?PAYLOAD1, <<>>, undefined, [], undefined),
    ResultIQ = mod_feed:process_local_iq(PublishIQ),
    ExpectedResultIQ = get_error_iq_result(<<"no_audience">>, ?UID1),
    ?assertEqual(ExpectedResultIQ, ResultIQ),
    ok.


publish_post_test() ->
    setup(),

    tutil:meck_init(ejabberd_router, route,
        fun(Packet) ->
            ?assertEqual(?UID1, Packet#pb_msg.from_uid),
            ?assert(Packet#pb_msg.to_uid =:= ?UID2),
            SubEl = Packet#pb_msg.payload,
            Post = SubEl#pb_feed_item.item,
            ?assertEqual(?UID1, Post#pb_post.publisher_uid),
            ?assertEqual(?PAYLOAD1, Post#pb_post.payload),
            ?assertEqual(?ENC_PAYLOAD1, Post#pb_post.enc_payload),
            ?assertEqual(all, Post#pb_post.audience#pb_audience.type),
            ?assertNotEqual(undefined, Post#pb_post.timestamp),
            ?assert(SubEl#pb_feed_item.sender_state =:= create_sender_state(?ENC_SENDER_STATE2)),
            ok
        end),

    %% posting a feedpost.
    SenderStateBundles = create_sender_state_bundles(
        [{?UID2, ?ENC_SENDER_STATE2}, {?UID3, ?ENC_SENDER_STATE3}]),
    PublishIQ = get_post_publish_iq(?POST_ID1, ?UID1, ?PAYLOAD1, ?ENC_PAYLOAD1, all, [?UID1, ?UID2],
        SenderStateBundles),
    model_friends:add_friends(?UID1, [?UID2, ?UID3]),
    ResultIQ1 = mod_feed:process_local_iq(PublishIQ),
    Timestamp = get_timestamp(ResultIQ1),
    ExpectedResultIQ = get_post_publish_iq_result(?POST_ID1, ?UID1, ?PAYLOAD1, ?ENC_PAYLOAD1, all, Timestamp),
    ?assertEqual(ExpectedResultIQ, ResultIQ1),

    %% re-posting the same feedpost should still give the same timestamp.
    ResultIQ2 = mod_feed:process_local_iq(PublishIQ),
    ?assertEqual(ExpectedResultIQ, ResultIQ2),

    ?assertEqual(2, meck:num_calls(ejabberd_router, route, '_')),
    tutil:meck_finish(ejabberd_router),

    ok.


publish_non_existing_post_comment_test() ->
    setup(),
    %% publishing comment without post should give an error.
    PublishIQ = get_comment_publish_iq(?COMMENT_ID1, ?POST_ID1, ?UID1, <<>>, ?PAYLOAD1, ?ENC_PAYLOAD1),
    ResultIQ = mod_feed:process_local_iq(PublishIQ),
    ExpectedResultIQ = get_error_iq_result(<<"invalid_post_id">>, ?UID1),
    ?assertEqual(ExpectedResultIQ, ResultIQ),
    ok.


publish_comment_test() ->
    setup(),
    %% publish post and then comment.
    tutil:meck_init(ejabberd_router, route,
        fun(Packet) ->
            ?assertEqual(?UID1, Packet#pb_msg.from_uid),
            ?assert(Packet#pb_msg.to_uid =:= ?UID2),
            SubEl = Packet#pb_msg.payload,
            Post = SubEl#pb_feed_item.item,
            ?assertEqual(?UID1, Post#pb_comment.publisher_uid),
            ?assertEqual(?PAYLOAD1, Post#pb_comment.payload),
            ?assertEqual(?ENC_PAYLOAD1, Post#pb_comment.enc_payload),
            ?assertNotEqual(undefined, Post#pb_comment.timestamp),
            ?assert(SubEl#pb_feed_item.sender_state =:= undefined),
            ok
        end),

    model_friends:add_friends(?UID1, [?UID2, ?UID3]),
    ok = model_feed:publish_post(?POST_ID1, ?UID1, ?PAYLOAD1, empty, all, [?UID1, ?UID2], util:now_ms()),
    PublishIQ = get_comment_publish_iq(?COMMENT_ID1, ?POST_ID1, ?UID1, <<>>, ?PAYLOAD1, ?ENC_PAYLOAD1),
    ResultIQ = mod_feed:process_local_iq(PublishIQ),
    Timestamp = get_timestamp(ResultIQ),
    ExpectedResultIQ = get_comment_publish_iq_result(?COMMENT_ID1, ?POST_ID1,
            ?UID1, <<>>, ?PAYLOAD1, ?ENC_PAYLOAD1, Timestamp),
    ?assertEqual(ExpectedResultIQ, ResultIQ),

    %% reposting the same comment should still give the same timestamp.
    ResultIQ2 = mod_feed:process_local_iq(PublishIQ),
    ?assertEqual(ExpectedResultIQ, ResultIQ2),

    ?assertEqual(2, meck:num_calls(ejabberd_router, route, '_')),
    tutil:meck_finish(ejabberd_router),
    ok.


retract_non_existing_post_test() ->
    setup(),
    %% retracting a post that does not exist should give an error.
    RetractIQ = get_post_retract_iq(?POST_ID1, ?UID1),
    ResultIQ = mod_feed:process_local_iq(RetractIQ),
    Timestamp = get_timestamp(ResultIQ),
    ExpectedResultIQ = get_post_retract_iq_result(?POST_ID1, ?UID1, Timestamp),
    ?assertEqual(ExpectedResultIQ, ResultIQ),
    ok.


retract_post_test() ->
    setup(),
    %% publish post and then retract.
    tutil:meck_init(ejabberd_router, route, fun(_) -> ok end),
    ok = model_feed:publish_post(?POST_ID1, ?UID1, ?PAYLOAD1, empty, all, [?UID1, ?UID2], util:now_ms()),
    RetractIQ = get_post_retract_iq(?POST_ID1, ?UID1),
    ResultIQ = mod_feed:process_local_iq(RetractIQ),
    Timestamp = get_timestamp(ResultIQ),
    ExpectedResultIQ = get_post_retract_iq_result(?POST_ID1, ?UID1, Timestamp),
    ?assertEqual(ExpectedResultIQ, ResultIQ),
    tutil:meck_finish(ejabberd_router),
    ok.


retract_not_authorized_post_test() ->
    setup(),
    %% publish post and then retract by different user.
    ok = model_feed:publish_post(?POST_ID1, ?UID1, ?PAYLOAD1, empty, all, [?UID1, ?UID2], util:now_ms()),
    RetractIQ = get_post_retract_iq(?POST_ID1, ?UID2),
    ResultIQ = mod_feed:process_local_iq(RetractIQ),
    ExpectedResultIQ = get_error_iq_result(<<"not_authorized">>, ?UID2),
    ?assertEqual(ExpectedResultIQ, ResultIQ),
    ok.


retract_non_existing_comment_test() ->
    setup(),
    %% retracting a comment that does not exist should give an error.
    RetractIQ = get_comment_retract_iq(?COMMENT_ID1, ?POST_ID1, ?UID1),
    ResultIQ = mod_feed:process_local_iq(RetractIQ),
    ExpectedResultIQ = get_error_iq_result(<<"invalid_post_id">>, ?UID1),
    ?assertEqual(ExpectedResultIQ, ResultIQ),
    ok.


retract_comment_test() ->
    setup(),
    %% publish post and comment and then retract comment.
    tutil:meck_init(ejabberd_router, route, fun(_) -> ok end),
    ok = model_feed:publish_post(?POST_ID1, ?UID1, ?PAYLOAD1, empty, all, [?UID1, ?UID2], util:now_ms()),
    ok = model_feed:publish_comment(?COMMENT_ID1, ?POST_ID1,
            ?UID1, <<>>, ?COMMENT_PAYLOAD1, util:now_ms()),
    RetractIQ = get_comment_retract_iq(?COMMENT_ID1, ?POST_ID1, ?UID1),
    ResultIQ = mod_feed:process_local_iq(RetractIQ),
    Timestamp = get_timestamp(ResultIQ),
    ExpectedResultIQ = get_comment_retract_iq_result(?COMMENT_ID1, ?POST_ID1,
            ?UID1, Timestamp),
    ?assertEqual(ExpectedResultIQ, ResultIQ),
    tutil:meck_finish(ejabberd_router),
    ok.


retract_not_authorized_comment_test() ->
    setup(),
    %% publish post and then retract by different user.
    ok = model_feed:publish_post(?POST_ID1, ?UID1, ?PAYLOAD1, empty, all, [?UID1, ?UID2], util:now_ms()),
    ok = model_feed:publish_comment(?COMMENT_ID2, ?POST_ID1,
            ?UID2, <<>>, ?COMMENT_PAYLOAD2, util:now_ms()),
    RetractIQ = get_comment_retract_iq(?COMMENT_ID2, ?POST_ID1, ?UID1),
    ResultIQ = mod_feed:process_local_iq(RetractIQ),
    ExpectedResultIQ = get_error_iq_result(<<"not_authorized">>, ?UID1),
    ?assertEqual(ExpectedResultIQ, ResultIQ),
    ok.


share_post_non_friend_test() ->
    setup(),
    %% publish post and add non-friend
    tutil:meck_init(ejabberd_router, route, fun(_) -> ok end),
    ok = model_feed:publish_post(?POST_ID1, ?UID1, ?PAYLOAD1, empty, all, [?UID1], util:now_ms()),
    ShareIQ = get_share_iq(?UID1, ?UID2, [?POST_ID1]),
    ResultIQ = mod_feed:process_local_iq(ShareIQ),
    ExpectedResultIQ = get_share_iq_result(?UID1, ?UID2),
    ?assertEqual(ExpectedResultIQ#pb_iq.payload, ResultIQ#pb_iq.payload),
    tutil:meck_finish(ejabberd_router),
    ok.


share_post_iq_test() ->
    setup(),
    tutil:meck_init(ejabberd_router, route, fun(_) -> ok end),
    ok = model_feed:publish_post(?POST_ID1, ?UID1, ?PAYLOAD1, empty, all, [?UID1], util:now_ms()),
    model_friends:add_friend(?UID1, ?UID2),
    ShareIQ = get_share_iq(?UID1, ?UID2, [?POST_ID1]),
    ResultIQ = mod_feed:process_local_iq(ShareIQ),
    ExpectedResultIQ = get_share_iq_result(?UID1, ?UID2),
    ?assertEqual(ExpectedResultIQ, ResultIQ),
    tutil:meck_finish(ejabberd_router),
    ok.

%%====================================================================
%% Public feed tests
%%====================================================================

-define(PUBLIC_FEED_TIMESTAMP_MS, 1668124237311).

setup_public_feed_tests() ->
    CleanupInfo = tutil:setup([
        {start, stringprep},
        {redis, [redis_feed]}
    ]),
    gen_iq_handler:start(ejabberd_local),
    ejabberd_hooks:start_link(),
    mod_feed:start(?SERVER, []),
    model_feed:publish_post(?POST_ID1, ?UID1, ?PAYLOAD1, public_moment, all, [], ?PUBLIC_FEED_TIMESTAMP_MS - 1),
    model_feed:publish_post(?POST_ID2, ?UID1, ?PAYLOAD1, public_moment, all, [], ?PUBLIC_FEED_TIMESTAMP_MS - 2),
    model_feed:publish_post(?POST_ID3, ?UID1, ?PAYLOAD1, public_moment, all, [], ?PUBLIC_FEED_TIMESTAMP_MS - 3),
    CleanupInfo.


test_get_public_feed_items(_) ->
    GetPostIdsFromPost = fun({_, _, L}) -> lists:map(fun(#post{id = PostId}) -> PostId end, L) end,
    [?_assertEqual([?POST_ID1, ?POST_ID2, ?POST_ID3], GetPostIdsFromPost(
        mod_feed:get_public_moments(?UID1, undefined, ?PUBLIC_FEED_TIMESTAMP_MS, undefined, 5))),
    ?_assertOk(model_feed:retract_post(?POST_ID2, ?UID1)),
    ?_assertEqual([?POST_ID1, ?POST_ID3], GetPostIdsFromPost(
        mod_feed:get_public_moments(?UID1, undefined, ?PUBLIC_FEED_TIMESTAMP_MS, undefined, 5)))].


public_feed_test_() ->
    tutil:setup_once(fun setup_public_feed_tests/0, [
        fun test_get_public_feed_items/1
    ]).

