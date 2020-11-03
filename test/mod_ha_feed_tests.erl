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
    tutil:setup(),
    stringprep:start(),
    gen_iq_handler:start(ejabberd_local),
    ejabberd_hooks:start_link(),
    mod_redis:start(undefined, []),
    mod_ha_feed:start(?SERVER, []),
    mnesia:wait_for_tables([psnode, item], 10000),
    clear(),
    ok.


setup2() ->
    tutil:setup(),
    stringprep:start(),
    gen_iq_handler:start(ejabberd_local),
    ejabberd_hooks:start_link(),
    mod_redis:start(undefined, []),
    mod_ha_feed:start(?SERVER, []),
    clear(),
    ok.



clear() ->
    tutil:cleardb(redis_feed).


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

create_feed_stanza(Action, Posts, Comments, AudienceListSt, SharePostsSt) ->
    #feed_st{
        action = Action,
        posts = Posts,
        comments = Comments,
        audience_list = AudienceListSt,
        share_posts = SharePostsSt
    }.

create_audience_list_st(undefined, _) ->
    [];
create_audience_list_st(AudienceType, AudienceList) ->
    Uids = lists:map(
        fun(Uid) ->
            #uid_element{uid = Uid}
        end, AudienceList),
    [#audience_list_st{
        type = AudienceType,
        uids = Uids
    }].

create_share_post_st(Uid, PostIds, Result, Reason) ->
    Posts = lists:map(
        fun(PostId) ->
            #post_st{id = PostId}
        end, PostIds),
    #share_posts_st{
        uid = Uid,
        posts = Posts,
        result = Result,
        reason = Reason
    }.

get_post_publish_iq(PostId, Uid, Payload, AudienceType, AudienceList, Server) ->
    Post = create_post_st(PostId, Uid, Payload, <<>>),
    AudienceListStanza = create_audience_list_st(AudienceType, AudienceList),
    FeedStanza = create_feed_stanza(publish, [Post], [], AudienceListStanza, []),
    #iq{
        from = jid:make(Uid, Server),
        type = set,
        to = jid:make(Server),
        sub_els = [FeedStanza]
    }.

get_post_publish_iq_result(PostId, Uid, Timestamp, Server) ->
    Post = create_post_st(PostId, Uid, <<>>, Timestamp),
    FeedStanza = create_feed_stanza(publish, [Post], [], [], []),
    #iq{
        from = jid:make(Server),
        type = result,
        to = jid:make(Uid, Server),
        sub_els = [FeedStanza]
    }.

get_comment_publish_iq(CommentId, PostId, Uid, ParentCommentId, Payload, Server) ->
    Comment = create_comment_st(CommentId, PostId, Uid, <<>>, ParentCommentId, Payload, <<>>),
    FeedStanza = create_feed_stanza(publish, [], [Comment], [], []),
    #iq{
        from = jid:make(Uid, Server),
        type = set,
        to = jid:make(Server),
        sub_els = [FeedStanza]
    }.

get_comment_publish_iq_result(CommentId, PostId, Uid, ParentCommentId, Timestamp, Server) ->
    Comment = create_comment_st(CommentId, PostId, Uid, <<>>, ParentCommentId, <<>>, Timestamp),
    FeedStanza = create_feed_stanza(publish, [], [Comment], [], []),
    #iq{
        from = jid:make(Server),
        type = result,
        to = jid:make(Uid, Server),
        sub_els = [FeedStanza]
    }.

get_post_retract_iq(PostId, Uid, Server) ->
    Post = create_post_st(PostId, Uid, <<>>, <<>>),
    FeedStanza = create_feed_stanza(retract, [Post], [], [], []),
    #iq{
        from = jid:make(Uid, Server),
        type = set,
        to = jid:make(Server),
        sub_els = [FeedStanza]
    }.

get_post_retract_iq_result(PostId, Uid, Timestamp, Server) ->
    Post = create_post_st(PostId, Uid, <<>>, Timestamp),
    FeedStanza = create_feed_stanza(retract, [Post], [], [], []),
    #iq{
        from = jid:make(Server),
        type = result,
        to = jid:make(Uid, Server),
        sub_els = [FeedStanza]
    }.

get_comment_retract_iq(CommentId, PostId, Uid, Server) ->
    Comment = create_comment_st(CommentId, PostId, <<>>, <<>>, <<>>, <<>>, <<>>),
    FeedStanza = create_feed_stanza(retract, [], [Comment], [], []),
    #iq{
        from = jid:make(Uid, Server),
        type = set,
        to = jid:make(Server),
        sub_els = [FeedStanza]
    }.

get_comment_retract_iq_result(CommentId, PostId, Uid, Timestamp, Server) ->
    Comment = create_comment_st(CommentId, PostId, Uid, <<>>, <<>>, <<>>, Timestamp),
    FeedStanza = create_feed_stanza(retract, [], [Comment], [], []),
    #iq{
        from = jid:make(Server),
        type = result,
        to = jid:make(Uid, Server),
        sub_els = [FeedStanza]
    }.


get_share_iq(Uid, FriendUid, PostIds, Server) ->
    SharePostSt = create_share_post_st(FriendUid, PostIds, <<>>, <<>>),
    FeedStanza = create_feed_stanza(share, [], [], [], [SharePostSt]),
    #iq{
        from = jid:make(Uid, Server),
        type = set,
        to = jid:make(Server),
        sub_els = [FeedStanza]
    }.


get_share_error_result(Uid, FriendUid, Server) ->
    SharePostSt = create_share_post_st(FriendUid, [], failed, invalid_friend_uid),
    FeedStanza = create_feed_stanza(share, [], [], [], [SharePostSt]),
    #iq{
        from = jid:make(Server),
        type = result,
        to = jid:make(Uid, Server),
        sub_els = [FeedStanza]
    }.


get_share_iq_result(Uid, FriendUid, Server) ->
    SharePostSt = create_share_post_st(FriendUid, [], ok, undefined),
    FeedStanza = create_feed_stanza(share, [], [], [], [SharePostSt]),
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
        sub_els = [#error_st{reason = Reason}]
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


publish_post_no_audience_error() ->
    setup(),
    %% posting a feedpost without audience
    PublishIQ = get_post_publish_iq(?POST_ID1, ?UID1, ?PAYLOAD1, undefined, [], ?SERVER),
    ResultIQ = mod_ha_feed:process_local_iq(PublishIQ),
    ExpectedResultIQ = get_error_iq_result(no_audience, ?UID1, ?SERVER),
    ?assertEqual(ExpectedResultIQ, ResultIQ),
    ok.

publish_post_no_audience_error_test() ->
    {timeout, 30,
        fun publish_post_no_audience_error/0}.


publish_post() ->
    setup(),
    %% posting a feedpost.
    PublishIQ = get_post_publish_iq(?POST_ID1, ?UID1, ?PAYLOAD1, all, [?UID1, ?UID2], ?SERVER),
    ResultIQ1 = mod_ha_feed:process_local_iq(PublishIQ),
    Timestamp = get_timestamp(ResultIQ1),
    ExpectedResultIQ = get_post_publish_iq_result(?POST_ID1, ?UID1, Timestamp, ?SERVER),
    ?assertEqual(ExpectedResultIQ, ResultIQ1),

    %% re-posting the same feedpost should still give the same timestamp.
    ResultIQ2 = mod_ha_feed:process_local_iq(PublishIQ),
    ?assertEqual(ExpectedResultIQ, ResultIQ2),
    ok.

publish_post_test() ->
    {timeout, 30,
        fun publish_post/0}.


publish_non_existing_post_comment() ->
    setup(),
    %% publishing comment without post should give an error.
    PublishIQ = get_comment_publish_iq(?COMMENT_ID1, ?POST_ID1, ?UID1, <<>>, ?PAYLOAD1, ?SERVER),
    ResultIQ = mod_ha_feed:process_local_iq(PublishIQ),
    ExpectedResultIQ = get_error_iq_result(invalid_post_id, ?UID1, ?SERVER),
    ?assertEqual(ExpectedResultIQ, ResultIQ),
    ok.

publish_non_existing_post_comment_test() ->
    {timeout, 30,
        fun publish_non_existing_post_comment/0}.


publish_comment() ->
    setup(),
    %% publish post and then comment.
    ok = model_feed:publish_post(?POST_ID1, ?UID1, ?PAYLOAD1, all, [?UID1, ?UID2], util:now_ms()),
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

publish_comment_test() ->
    {timeout, 30,
        fun publish_comment/0}.


retract_non_existing_post() ->
    setup(),
    %% retracting a post that does not exist should give an error.
    RetractIQ = get_post_retract_iq(?POST_ID1, ?UID1, ?SERVER),
    ResultIQ = mod_ha_feed:process_local_iq(RetractIQ),
    ExpectedResultIQ = get_error_iq_result(invalid_post_id, ?UID1, ?SERVER),
    ?assertEqual(ExpectedResultIQ, ResultIQ),
    ok.

retract_non_existing_post_test() ->
    {timeout, 30,
        fun retract_non_existing_post/0}.


retract_post() ->
    setup(),
    %% publish post and then retract.
    ok = model_feed:publish_post(?POST_ID1, ?UID1, ?PAYLOAD1, all, [?UID1, ?UID2], util:now_ms()),
    RetractIQ = get_post_retract_iq(?POST_ID1, ?UID1, ?SERVER),
    ResultIQ = mod_ha_feed:process_local_iq(RetractIQ),
    Timestamp = get_timestamp(ResultIQ),
    ExpectedResultIQ = get_post_retract_iq_result(?POST_ID1, ?UID1, Timestamp, ?SERVER),
    ?assertEqual(ExpectedResultIQ, ResultIQ),
    ok.

retract_post_test() ->
    {timeout, 30,
        fun retract_post/0}.


retract_not_authorized_post() ->
    setup(),
    %% publish post and then retract by different user.
    ok = model_feed:publish_post(?POST_ID1, ?UID1, ?PAYLOAD1, all, [?UID1, ?UID2], util:now_ms()),
    RetractIQ = get_post_retract_iq(?POST_ID1, ?UID2, ?SERVER),
    ResultIQ = mod_ha_feed:process_local_iq(RetractIQ),
    ExpectedResultIQ = get_error_iq_result(not_authorized, ?UID2, ?SERVER),
    ?assertEqual(ExpectedResultIQ, ResultIQ),
    ok.

retract_not_authorized_post_test() ->
    {timeout, 30,
        fun retract_not_authorized_post/0}.


retract_non_existing_comment() ->
    setup(),
    %% retracting a comment that does not exist should give an error.
    RetractIQ = get_comment_retract_iq(?COMMENT_ID1, ?POST_ID1, ?UID1, ?SERVER),
    ResultIQ = mod_ha_feed:process_local_iq(RetractIQ),
    ExpectedResultIQ = get_error_iq_result(invalid_post_id, ?UID1, ?SERVER),
    ?assertEqual(ExpectedResultIQ, ResultIQ),
    ok.

retract_non_existing_comment_test() ->
    {timeout, 30,
        fun retract_non_existing_comment/0}.


retract_comment() ->
    setup(),
    %% publish post and comment and then retract comment.
    ok = model_feed:publish_post(?POST_ID1, ?UID1, ?PAYLOAD1, all, [?UID1, ?UID2], util:now_ms()),
    ok = model_feed:publish_comment(?COMMENT_ID1, ?POST_ID1,
            ?UID1, <<>>, [?UID1], ?COMMENT_PAYLOAD1, util:now_ms()),
    RetractIQ = get_comment_retract_iq(?COMMENT_ID1, ?POST_ID1, ?UID1, ?SERVER),
    ResultIQ = mod_ha_feed:process_local_iq(RetractIQ),
    Timestamp = get_timestamp(ResultIQ),
    ExpectedResultIQ = get_comment_retract_iq_result(?COMMENT_ID1, ?POST_ID1,
            ?UID1, Timestamp, ?SERVER),
    ?assertEqual(ExpectedResultIQ, ResultIQ),
    ok.

retract_comment_test() ->
    {timeout, 30,
        fun retract_comment/0}.


retract_not_authorized_comment() ->
    setup(),
    %% publish post and then retract by different user.
    ok = model_feed:publish_post(?POST_ID1, ?UID1, ?PAYLOAD1, all, [?UID1, ?UID2], util:now_ms()),
    ok = model_feed:publish_comment(?COMMENT_ID2, ?POST_ID1,
            ?UID2, <<>>, [?UID1, ?UID2], ?COMMENT_PAYLOAD2, util:now_ms()),
    RetractIQ = get_comment_retract_iq(?COMMENT_ID2, ?POST_ID1, ?UID1, ?SERVER),
    ResultIQ = mod_ha_feed:process_local_iq(RetractIQ),
    ExpectedResultIQ = get_error_iq_result(not_authorized, ?UID1, ?SERVER),
    ?assertEqual(ExpectedResultIQ, ResultIQ),
    ok.

retract_not_authorized_comment_test() ->
    {timeout, 30,
        fun retract_not_authorized_comment/0}.


share_post_error() ->
    setup(),
    %% publish post and add non-friend
    ok = model_feed:publish_post(?POST_ID1, ?UID1, ?PAYLOAD1, all, [?UID1], util:now_ms()),
    ShareIQ = get_share_iq(?UID1, ?UID2, [?POST_ID1], ?SERVER),
    ResultIQ = mod_ha_feed:process_local_iq(ShareIQ),
    ExpectedResultIQ = get_share_error_result(?UID1, ?UID2, ?SERVER),
    ?assertEqual(ExpectedResultIQ#iq.sub_els, ResultIQ#iq.sub_els),
    ok.

share_post_error_test() ->
    {timeout, 30,
        fun share_post_error/0}.


share_post_iq() ->
    setup(),
    ok = model_feed:publish_post(?POST_ID1, ?UID1, ?PAYLOAD1, all, [?UID1], util:now_ms()),
    model_friends:add_friend(?UID1, ?UID2),
    ShareIQ = get_share_iq(?UID1, ?UID2, [?POST_ID1], ?SERVER),
    ResultIQ = mod_ha_feed:process_local_iq(ShareIQ),
    ExpectedResultIQ = get_share_iq_result(?UID1, ?UID2, ?SERVER),
    ?assertEqual(ExpectedResultIQ, ResultIQ),
    % TODO: the old tests are not working
    % ?assertEqual(1, 2),
    ok.

share_post_iq_test() ->
    {timeout, 30,
        fun share_post_iq/0}.


add_friend_test() ->
    setup2(),
    meck:new(ejabberd_router, [passthrough]),
    meck:expect(ejabberd_router, route, fun(P) ->
        #message {
            id = _Id,
            to = To,
            from = From,
            type = MsgType,
            sub_els = [FeedSt]
        } = P,
        ?assertEqual(jid:make(?UID2, ?SERVER), To),
        ?assertEqual(jid:make(?SERVER), From),
        ?assertEqual(normal, MsgType),
        #feed_st{
            posts = [PostSt],
            comments = []
        } = FeedSt,
        ?assertEqual(?POST_ID1, PostSt#post_st.id),
        ?assertEqual(?PAYLOAD1, PostSt#post_st.payload),
        ok
    end),
    ok = model_feed:publish_post(?POST_ID1, ?UID1, ?PAYLOAD1, all, [?UID1], util:now_ms()),
    model_friends:add_friend(?UID1, ?UID2),
    mod_ha_feed:add_friend(?UID1, ?SERVER, ?UID2),
    ?assertEqual(1, meck:num_calls(ejabberd_router, route, '_')),
    meck:unload(ejabberd_router),
    ok.

