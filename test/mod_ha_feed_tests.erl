%%%-------------------------------------------------------------------
%%% File: mod_ha_feed_tests.erl
%%%
%%% Copyright (C) 2020, Halloapp Inc.
%%%
%%%-------------------------------------------------------------------
-module(mod_ha_feed_tests).
-author('murali').

-include("xmpp.hrl").
-include("feed.hrl").

-include_lib("eunit/include/eunit.hrl").

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

-define(SERVER, <<"s.halloapp.net">>).


setup() ->
    stringprep:start(),
    gen_iq_handler:start(ejabberd_local),
    ejabberd_hooks:start_link(),
    mod_redis:start(undefined, []),
    clear(),
    ok.


clear() ->
    {ok, ok} = gen_server:call(redis_feed_client, flushdb).


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%%%%                   helper functions                           %%%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%


create_post_st(PostId, Uid, Payload, Timestamp) ->
    #post_st{
        id = PostId,
        uid = Uid,
        payload = Payload,
        timestamp = Timestamp
    }.

create_comment_st(CommentId, PostId, PublisherUid,
        PublisherName, ParentCommentId, Payload, Timestamp) ->
    #comment_st{
        id = CommentId,
        post_id = PostId,
        publisher_uid = PublisherUid,
        publisher_name = PublisherName,
        parent_comment_id = ParentCommentId,
        payload = Payload,
        timestamp = Timestamp
    }.

create_feed_stanza(Action, Posts, Comments) ->
    #feed_st{
        action = Action,
        posts = Posts,
        comments = Comments
    }.

get_post_publish_iq(PostId, Uid, Payload, Server) ->
    Post = create_post_st(PostId, Uid, Payload, <<>>),
    FeedStanza = create_feed_stanza(publish, [Post], []),
    #iq{
        from = jid:make(Uid, Server),
        type = set,
        to = jid:make(Server),
        sub_els = [FeedStanza]
    }.

get_post_publish_iq_result(PostId, Uid, Timestamp, Server) ->
    Post = create_post_st(PostId, Uid, <<>>, Timestamp),
    FeedStanza = create_feed_stanza(publish, [Post], []),
    #iq{
        from = jid:make(Server),
        type = result,
        to = jid:make(Uid, Server),
        sub_els = [FeedStanza]
    }.

get_comment_publish_iq(CommentId, PostId, Uid, ParentCommentId, Payload, Server) ->
    Comment = create_comment_st(CommentId, PostId, Uid, <<>>, ParentCommentId, Payload, <<>>),
    FeedStanza = create_feed_stanza(publish, [], [Comment]),
    #iq{
        from = jid:make(Uid, Server),
        type = set,
        to = jid:make(Server),
        sub_els = [FeedStanza]
    }.

get_comment_publish_iq_result(CommentId, PostId, Uid, ParentCommentId, Timestamp, Server) ->
    Comment = create_comment_st(CommentId, PostId, Uid, <<>>, ParentCommentId, <<>>, Timestamp),
    FeedStanza = create_feed_stanza(publish, [], [Comment]),
    #iq{
        from = jid:make(Server),
        type = result,
        to = jid:make(Uid, Server),
        sub_els = [FeedStanza]
    }.

get_post_retract_iq(PostId, Uid, Server) ->
    Post = create_post_st(PostId, Uid, <<>>, <<>>),
    FeedStanza = create_feed_stanza(retract, [Post], []),
    #iq{
        from = jid:make(Uid, Server),
        type = set,
        to = jid:make(Server),
        sub_els = [FeedStanza]
    }.

get_post_retract_iq_result(PostId, Uid, Timestamp, Server) ->
    Post = create_post_st(PostId, Uid, <<>>, Timestamp),
    FeedStanza = create_feed_stanza(retract, [Post], []),
    #iq{
        from = jid:make(Server),
        type = result,
        to = jid:make(Uid, Server),
        sub_els = [FeedStanza]
    }.

get_comment_retract_iq(CommentId, PostId, Uid, Server) ->
    Comment = create_comment_st(CommentId, PostId, <<>>, <<>>, <<>>, <<>>, <<>>),
    FeedStanza = create_feed_stanza(retract, [], [Comment]),
    #iq{
        from = jid:make(Uid, Server),
        type = set,
        to = jid:make(Server),
        sub_els = [FeedStanza]
    }.

get_comment_retract_iq_result(CommentId, PostId, Uid, Timestamp, Server) ->
    Comment = create_comment_st(CommentId, PostId, Uid, <<>>, <<>>, <<>>, Timestamp),
    FeedStanza = create_feed_stanza(retract, [], [Comment]),
    #iq{
        from = jid:make(Server),
        type = result,
        to = jid:make(Uid, Server),
        sub_els = [FeedStanza]
    }.


get_error_iq_result(Reason, Uid, Server) ->
    #iq{
        from = jid:make(Server),
        type = error,
        to = jid:make(Uid, Server),
        sub_els = [#stanza_error{reason = Reason}]
    }.


get_timestamp(#iq{sub_els = [#feed_st{posts = [#post_st{timestamp = Timestamp}]}]}) ->
    Timestamp;
get_timestamp(#iq{sub_els = [#feed_st{comments = [#comment_st{timestamp = Timestamp}]}]}) ->
    Timestamp;
get_timestamp(_) ->
    <<>>.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%%%%                        Tests                                 %%%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%


publish_post_test() ->
    setup(),
    %% posting a feedpost.
    PublishIQ = get_post_publish_iq(?POST_ID1, ?UID1, ?PAYLOAD1, ?SERVER),
    ResultIQ1 = mod_ha_feed:process_local_iq(PublishIQ),
    Timestamp = get_timestamp(ResultIQ1),
    ExpectedResultIQ = get_post_publish_iq_result(?POST_ID1, ?UID1, Timestamp, ?SERVER),
    ?assertEqual(ExpectedResultIQ, ResultIQ1),

    %% re-posting the same feedpost should still give the same timestamp.
    ResultIQ2 = mod_ha_feed:process_local_iq(PublishIQ),
    ?assertEqual(ExpectedResultIQ, ResultIQ2),
    ok.


publish_non_existing_post_comment_test() ->
    setup(),
    %% publishing comment without post should give an error.
    PublishIQ = get_comment_publish_iq(?COMMENT_ID1, ?POST_ID1, ?UID1, <<>>, ?PAYLOAD1, ?SERVER),
    ResultIQ = mod_ha_feed:process_local_iq(PublishIQ),
    ExpectedResultIQ = get_error_iq_result(invalid_post_id, ?UID1, ?SERVER),
    ?assertEqual(ExpectedResultIQ, ResultIQ),
    ok.


publish_comment_test() ->
    setup(),
    %% publish post and then comment.
    ok = model_feed:publish_post(?POST_ID1, ?UID1, ?PAYLOAD1, util:now_ms()),
    PublishIQ = get_comment_publish_iq(?COMMENT_ID1, ?POST_ID1, ?UID1, <<>>, ?PAYLOAD1, ?SERVER),
    ResultIQ = mod_ha_feed:process_local_iq(PublishIQ),
    Timestamp = get_timestamp(ResultIQ),
    ExpectedResultIQ = get_comment_publish_iq_result(?COMMENT_ID1, ?POST_ID1,
            ?UID1, <<>>, Timestamp, ?SERVER),
    ?assertEqual(ExpectedResultIQ, ResultIQ),

    %% reposting the same comment should still give the same timestamp.
    ResultIQ2 = mod_ha_feed:process_local_iq(PublishIQ),
    ?assertEqual(ExpectedResultIQ, ResultIQ2),
    ok.


retract_non_existing_post_test() ->
    setup(),
    %% retracting a post that does not exist should give an error.
    RetractIQ = get_post_retract_iq(?POST_ID1, ?UID1, ?SERVER),
    ResultIQ = mod_ha_feed:process_local_iq(RetractIQ),
    ExpectedResultIQ = get_error_iq_result(invalid_post_id, ?UID1, ?SERVER),
    ?assertEqual(ExpectedResultIQ, ResultIQ),
    ok.


retract_post_test() ->
    setup(),
    %% publish post and then retract.
    ok = model_feed:publish_post(?POST_ID1, ?UID1, ?PAYLOAD1, util:now_ms()),
    RetractIQ = get_post_retract_iq(?POST_ID1, ?UID1, ?SERVER),
    ResultIQ = mod_ha_feed:process_local_iq(RetractIQ),
    Timestamp = get_timestamp(ResultIQ),
    ExpectedResultIQ = get_post_retract_iq_result(?POST_ID1, ?UID1, Timestamp, ?SERVER),
    ?assertEqual(ExpectedResultIQ, ResultIQ),
    ok.


retract_not_authorized_post_test() ->
    setup(),
    %% publish post and then retract by different user.
    ok = model_feed:publish_post(?POST_ID1, ?UID1, ?PAYLOAD1, util:now_ms()),
    RetractIQ = get_post_retract_iq(?POST_ID1, ?UID2, ?SERVER),
    ResultIQ = mod_ha_feed:process_local_iq(RetractIQ),
    ExpectedResultIQ = get_error_iq_result(not_authorized, ?UID2, ?SERVER),
    ?assertEqual(ExpectedResultIQ, ResultIQ),
    ok.


retract_non_existing_comment_test() ->
    setup(),
    %% retracting a comment that does not exist should give an error.
    RetractIQ = get_comment_retract_iq(?COMMENT_ID1, ?POST_ID1, ?UID1, ?SERVER),
    ResultIQ = mod_ha_feed:process_local_iq(RetractIQ),
    ExpectedResultIQ = get_error_iq_result(invalid_post_id, ?UID1, ?SERVER),
    ?assertEqual(ExpectedResultIQ, ResultIQ),
    ok.


retract_comment_test() ->
    setup(),
    %% publish post and comment and then retract comment.
    ok = model_feed:publish_post(?POST_ID1, ?UID1, ?PAYLOAD1, util:now_ms()),
    ok = model_feed:publish_comment(?COMMENT_ID1, ?POST_ID1,
            ?UID1, <<>>, [?UID1], ?COMMENT_PAYLOAD1, util:now_ms()),
    RetractIQ = get_comment_retract_iq(?COMMENT_ID1, ?POST_ID1, ?UID1, ?SERVER),
    ResultIQ = mod_ha_feed:process_local_iq(RetractIQ),
    Timestamp = get_timestamp(ResultIQ),
    ExpectedResultIQ = get_comment_retract_iq_result(?COMMENT_ID1, ?POST_ID1,
            ?UID1, Timestamp, ?SERVER),
    ?assertEqual(ExpectedResultIQ, ResultIQ),
    ok.


retract_not_authorized_comment_test() ->
    setup(),
    %% publish post and then retract by different user.
    ok = model_feed:publish_post(?POST_ID1, ?UID1, ?PAYLOAD1, util:now_ms()),
    ok = model_feed:publish_comment(?COMMENT_ID2, ?POST_ID1,
            ?UID2, <<>>, [?UID1, ?UID2], ?COMMENT_PAYLOAD2, util:now_ms()),
    RetractIQ = get_comment_retract_iq(?COMMENT_ID2, ?POST_ID1, ?UID1, ?SERVER),
    ResultIQ = mod_ha_feed:process_local_iq(RetractIQ),
    ExpectedResultIQ = get_error_iq_result(not_authorized, ?UID1, ?SERVER),
    ?assertEqual(ExpectedResultIQ, ResultIQ),
    ok.

