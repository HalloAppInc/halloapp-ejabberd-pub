%%%------------------------------------------------------------------------------------
%%% File: model_feed.erl
%%% Copyright (C) 2020, HalloApp, Inc.
%%%
%%% This model handles all the redis queries related to feedposts and comments.
%%%
%%% There could be some race conditions when requests occur on separate c2s processes.
%%% - When 2 requests simultaneously arrive to delete a post and publish a comment.
%%% To delete a post, We first check if the post exists and then delete it.
%%% To publish a comment, we first check if post and comment exist (get_post_and_comment)
%%%  and then publish it.
%%% It is possible that at the end: comment be inserted into the redis and the post be deleted.
%%% Data wont be accumulated: since all this data will anyways expire.
%%% But we should fix these issues later.
%%%
%%%------------------------------------------------------------------------------------
-module(model_feed).
-author('murali').

-include("logger.hrl").
-include("redis_keys.hrl").
-include("feed.hrl").

-ifdef(TEST).
-export([
    post_audience_key/1,
    get_comment_push_data/2,
    cleanup_reverse_index/1,
    cleanup_group_reverse_index/1,
    reverse_group_post_key/1,
    psa_tag_key/1
    ]).
-endif.

-export([post_key/1, comment_key/2, post_comments_key/1, reverse_post_key/1]).


%% API
-export([
    publish_post/8,
    publish_psa_post/6,
    publish_post/7,
    publish_comment/6,
    retract_post/2,
    retract_comment/2,
    get_post/1,
    get_posts/1,
    get_comment/2,
    get_post_and_its_comments/1,
    get_comment_data/3,
    get_7day_user_feed/1,
    get_entire_user_feed/1,
    get_7day_group_feed/1,
    get_entire_group_feed/1,
    get_psa_tag_posts/1,
    is_psa_tag_done/1,
    mark_psa_tag_done/1,
    del_psa_tag_done/1,
    get_moment_time_to_send/1,
    set_moment_time_to_send/2,
    is_moment_tag_done/1,
    mark_moment_tag_done/1,
    del_moment_tag_done/1,
    is_post_owner/2,
    get_post_tag/1,
    add_uid_to_audience/2,
    remove_all_user_posts/1,    %% test.
    is_post_deleted/1,    %% test.
    is_comment_deleted/2,    %% test.
    remove_user/1,
    store_external_share_post/3,
    delete_external_share_post/1,
    get_external_share_post/1
]).

%% TODO(murali@): expose more apis specific to posts and comments only if necessary.

%%====================================================================
%% API
%%====================================================================

-define(FIELD_UID, <<"uid">>).
-define(FIELD_PAYLOAD, <<"pl">>).
-define(FIELD_TAG, <<"pt">>).
-define(FIELD_AUDIENCE_TYPE, <<"fa">>).
-define(FIELD_TIMESTAMP_MS, <<"ts">>).
-define(FIELD_PUBLISHER_UID, <<"pbu">>).
-define(FIELD_PARENT_COMMENT_ID, <<"pc">>).
-define(FIELD_DELETED, <<"del">>).
-define(FIELD_GROUP_ID, <<"gid">>).
-define(FIELD_PSA_TAG, <<"pst">>).
-define(FIELD_PSA_TAG_DONE, <<"ptd">>).
-define(FIELD_MOMENT_TAG_DONE, <<"mtd">>).


-spec publish_post(PostId :: binary(), Uid :: uid(), Payload :: binary(), PostTag :: post_tag(),
        FeedAudienceType :: atom(), FeedAudienceList :: [binary()],
        TimestampMs :: integer(), Gid :: gid()) -> ok | {error, any()}.
publish_post(PostId, Uid, Payload, PostTag, FeedAudienceType, FeedAudienceList, TimestampMs, Gid)
    when is_binary(Gid), Gid =/= <<>> ->
    ok = publish_post(PostId, Uid, Payload, PostTag, FeedAudienceType, FeedAudienceList, TimestampMs),
    %% Set group_id
    {ok, _} = q(["HSET", post_key(PostId), ?FIELD_GROUP_ID, Gid]),
    %% Add post to reverse index of group_id
    [{ok, _}, {ok, _}] = qp([
            ["ZADD", reverse_group_post_key(Gid), TimestampMs, PostId],
            ["EXPIRE", reverse_group_post_key(Gid), ?POST_EXPIRATION]]),
    %% Cleanup reverse index of group_id
    ok = cleanup_group_reverse_index(Gid),
    ok.


-spec publish_psa_post(PostId :: binary(), Uid :: uid(), Payload :: binary(), PostTag :: post_tag(),
        PSATag :: binary(), TimestampMs :: integer()) -> ok | {error, any()}.
publish_psa_post(PostId, Uid, Payload, PostTag, PSATag, TimestampMs)
    when is_binary(PSATag), PSATag =/= <<>> ->
    ok = publish_post(PostId, Uid, Payload, PostTag, all, [], TimestampMs),

    %% Set psa tag
    {ok, _} = q(["HSET", post_key(PostId), ?FIELD_PSA_TAG, PSATag]),
    %% Add post to reverse index of psa_tag
    [{ok, _}, {ok, _}] = qp([
            ["ZADD", reverse_psa_tag_key(PSATag), TimestampMs, PostId],
            ["EXPIRE", reverse_psa_tag_key(PSATag), ?POST_EXPIRATION]]),
    %% Cleanup reverse index of psa_tag
    ok = cleanup_psa_tag_reverse_index(PSATag),
    ok.


 -spec publish_post(PostId :: binary(), Uid :: uid(), Payload :: binary(), PostTag :: post_tag(),
        FeedAudienceType :: atom(), FeedAudienceList :: [binary()],
        TimestampMs :: integer()) -> ok | {error, any()}.
publish_post(PostId, Uid, Payload, PostTag, FeedAudienceType, FeedAudienceList, TimestampMs) ->
    C1 = [["HSET", post_key(PostId),
        ?FIELD_UID, Uid,
        ?FIELD_PAYLOAD, Payload,
        ?FIELD_TAG, encode_post_tag(PostTag),
        ?FIELD_AUDIENCE_TYPE, encode_audience_type(FeedAudienceType),
        ?FIELD_TIMESTAMP_MS, integer_to_binary(TimestampMs)]],
    C2 = case FeedAudienceList of
        [] -> [];
        _ -> [["SADD", post_audience_key(PostId) | FeedAudienceList]]
    end,
    C3 = [["EXPIRE", post_key(PostId), ?POST_EXPIRATION],
            ["EXPIRE", post_audience_key(PostId), ?POST_EXPIRATION]],
    _Results = qp(C1 ++ C2 ++ C3),
    [{ok, _}, {ok, _}] = qp([
            ["ZADD", reverse_post_key(Uid), TimestampMs, PostId],
            ["EXPIRE", reverse_post_key(Uid), ?POST_EXPIRATION]]),
    ok = cleanup_reverse_index(Uid),
    ok.


%% TODO(murali@): Write lua scripts for some functions in this module.
-spec publish_comment(CommentId :: binary(), PostId :: binary(),
        PublisherUid :: uid(), ParentCommentId :: binary(),
        Payload :: binary(), TimestampMs :: integer()) -> ok | {error, any()}.
publish_comment(CommentId, PostId, PublisherUid,
        ParentCommentId, Payload, TimestampMs) ->
    {ok, TTL} = q(["TTL", post_key(PostId)]),
    ParentCommentIdValue = util_redis:encode_maybe_binary(ParentCommentId),
    [{ok, _}, {ok, _}] = qp([
            ["HSET", comment_key(CommentId, PostId),
                ?FIELD_PUBLISHER_UID, PublisherUid,
                ?FIELD_PARENT_COMMENT_ID, ParentCommentIdValue,
                ?FIELD_PAYLOAD, Payload,
                ?FIELD_TIMESTAMP_MS, integer_to_binary(TimestampMs)],
            ["EXPIRE", comment_key(CommentId, PostId), TTL]]),
    [{ok, _}, {ok, _}] = qp([
            ["ZADD", post_comments_key(PostId), TimestampMs, CommentId],
            ["EXPIRE", post_comments_key(PostId), TTL]]),
    {ok, _} = q(
            ["ZADD", reverse_comment_key(PublisherUid), TimestampMs, comment_key(CommentId, PostId)]),
    ok = cleanup_reverse_index(PublisherUid),
    ok.


-spec is_post_owner(PostId :: binary(), Uid :: uid()) -> {ok, boolean()}.
is_post_owner(PostId, Uid) ->
    {ok, OwnerUid} = q(["HGET", post_key(PostId), ?FIELD_UID]),
    Result = OwnerUid =:= Uid,
    {ok, Result}.


-spec get_post_tag(PostId :: binary()) -> {ok, post_tag()} | {error, any()}.
get_post_tag(PostId) ->
    case q(["HGET", post_key(PostId), ?FIELD_TAG]) of
        {ok, PostTag} ->
            Result = decode_post_tag(PostTag),
            {ok, Result};
        Error -> Error
    end.


%% We should do the check if Uid is the owner of PostId.
-spec retract_post(PostId :: binary(), Uid :: uid()) -> ok | {error, any()}.
retract_post(PostId, Uid) ->
    ok = cleanup_reverse_index(Uid),
    delete_post(PostId, Uid),
    ok.


-spec delete_post(PostId :: binary(), Uid :: uid()) -> ok | {error, any()}.
delete_post(PostId, _Uid) ->
    {ok, CommentIds} = q(["ZRANGEBYSCORE", post_comments_key(PostId), "-inf", "+inf"]),

    %% Delete all comments content and leave tombstone.
    CommentDeleteCommands = lists:foldl(
            fun(CommentId, Acc) ->
                [
                ["HDEL", comment_key(CommentId, PostId), ?FIELD_PAYLOAD],
                ["HSET", comment_key(CommentId, PostId), ?FIELD_DELETED, 1]
                | Acc]
            end, [], CommentIds),
    qp(CommentDeleteCommands),

    %% Delete content in post and leave a tombstone for the post.
    %% Leave the post's reference to its own comments, i.e. post_comments_key
    [{ok, _}, {ok, _}, {ok, _}] = qp([
            ["DEL", post_audience_key(PostId)],
            ["HDEL", post_key(PostId), ?FIELD_PAYLOAD, ?FIELD_AUDIENCE_TYPE],
            ["HSET", post_key(PostId), ?FIELD_DELETED, 1]]),
    ok.


-spec is_post_deleted(PostId :: binary()) -> boolean().
is_post_deleted(PostId) ->
    {ok, Res} = q(["HGET", post_key(PostId), ?FIELD_DELETED]),
    util_redis:decode_boolean(Res, false).


-spec is_comment_deleted(CommentId :: binary(), PostId :: binary()) -> boolean().
is_comment_deleted(CommentId, PostId) ->
    {ok, Res} = q(["HGET", comment_key(CommentId, PostId), ?FIELD_DELETED]),
    util_redis:decode_boolean(Res, false).


-spec retract_comment(CommentId :: binary(), PostId :: binary()) -> ok | {error, any()}.
retract_comment(CommentId, PostId) ->
    [{ok, _}, {ok, _}] = qp([
            ["HDEL", comment_key(CommentId, PostId), ?FIELD_PAYLOAD],
            ["HSET", comment_key(CommentId, PostId), ?FIELD_DELETED, 1]]),
    ok.


-spec remove_all_user_posts(Uid :: uid()) -> ok.
remove_all_user_posts(Uid) ->
    {ok, PostIds} = q(["ZRANGEBYSCORE", reverse_post_key(Uid), "-inf", "+inf"]),
    lists:foreach(fun(PostId) -> ok = delete_post(PostId, Uid) end, PostIds),
    {ok, _} = q(["DEL", reverse_post_key(Uid)]),
    ok.


-spec get_post(PostId :: binary()) -> {ok, post()} | {error, any()}.
get_post(PostId) ->
    [
        {ok, [Uid, Payload, PostTag, AudienceType, TimestampMs, Gid, PSATag, IsDeletedBin]},
        {ok, AudienceList}] = qp([
            ["HMGET", post_key(PostId),
                ?FIELD_UID, ?FIELD_PAYLOAD, ?FIELD_TAG, ?FIELD_AUDIENCE_TYPE, ?FIELD_TIMESTAMP_MS,
                ?FIELD_GROUP_ID, ?FIELD_PSA_TAG, ?FIELD_DELETED],
            ["SMEMBERS", post_audience_key(PostId)]]),
    IsDeleted = util_redis:decode_boolean(IsDeletedBin, false),
    case Uid =:= undefined orelse IsDeleted =:= true of
        true -> {error, missing};
        false ->
            {ok, #post{
                id = PostId,
                uid = Uid,
                tag = decode_post_tag(PostTag),
                audience_type = decode_audience_type(AudienceType),
                audience_list = AudienceList,
                payload = Payload,
                ts_ms = util_redis:decode_ts(TimestampMs),
                gid = Gid,
                psa_tag = PSATag
            }}
    end.


-spec get_comment(CommentId :: binary(), PostId :: binary()) -> {ok, comment()} | {error, any()}.
get_comment(CommentId, PostId) ->
    {ok, [PublisherUid, ParentCommentId, Payload, TimestampMs, IsDeletedBin]} = q(
        ["HMGET", comment_key(CommentId, PostId),
            ?FIELD_PUBLISHER_UID, ?FIELD_PARENT_COMMENT_ID, ?FIELD_PAYLOAD, ?FIELD_TIMESTAMP_MS, ?FIELD_DELETED]),
    process_comment(CommentId, PostId, PublisherUid, ParentCommentId, Payload, TimestampMs, IsDeletedBin).


-spec get_comments(CommentIds :: [binary()], PostId :: binary()) -> [{ok, comment()} | {error, any()}].
get_comments(CommentIds, PostId) ->
    Commands = lists:map(
        fun(CommentId) ->
            ["HMGET", comment_key(CommentId, PostId),
            ?FIELD_PUBLISHER_UID, ?FIELD_PARENT_COMMENT_ID, ?FIELD_PAYLOAD, ?FIELD_TIMESTAMP_MS, ?FIELD_DELETED]
        end, CommentIds),
    AllComments = qmn(Commands),
    Comments = lists:zipwith(
        fun(Comment, CommentId) ->
            {ok, [PublisherUid, ParentCommentId, Payload, TimestampMs, IsDeletedBin]} = Comment,
            process_comment(CommentId, PostId, PublisherUid,ParentCommentId,Payload, TimestampMs, IsDeletedBin)
        end, AllComments, CommentIds),
    Comments.


-spec process_comment(CommentId :: binary(), PostId :: binary(), PublisherUid :: binary(),
        ParentCommentId :: binary(), Payload :: binary(), TimestampMs :: binary(),
        IsDeletedBin :: binary()) -> {ok, comment()} | {error, any()}.
process_comment(CommentId, PostId, PublisherUid, ParentCommentId, Payload, TimestampMs, IsDeletedBin) ->
    IsDeleted = util_redis:decode_boolean(IsDeletedBin, false),
    case PublisherUid =:= undefined orelse IsDeleted =:= true of
        true ->
            ?DEBUG("Unable to get_comment, commentid: ~p, postid: ~p", [CommentId, PostId]),
            {error, missing};
        false -> {ok, #comment{
            id = CommentId,
            post_id = PostId,
            publisher_uid = PublisherUid,
            parent_id = util_redis:decode_maybe_binary(ParentCommentId),
            payload = Payload,
            ts_ms = util_redis:decode_ts(TimestampMs)}}
    end.


%% TODO(murali@): optimize redis queries to fetch all posts and comments.
-spec get_post_and_its_comments(PostId :: binary()) -> {ok, {post(), [comment()]}} | {error, any()}.
get_post_and_its_comments(PostId) when is_binary(PostId) ->
    case get_post(PostId) of
        {ok, Post} ->
            {ok, Comments} = get_post_comments(PostId),
            {ok, {Post, Comments}};
        {error, missing} ->
            {error, missing}
    end.


%% We dont check if the given ParentId here is correct or not.
%% We only use it to fetch the PushList of uids.
-spec get_comment_data(PostId :: binary(), CommentId :: binary(),ParentId :: maybe(binary())) ->
    {{ok, feed_item()} | {error, any()}, {ok, feed_item()} | {error, any()}, {ok, [binary()]}} | {error, any()}.
get_comment_data(PostId, CommentId, ParentId) ->
    [{ok, Res1}, {ok, Res2}, {ok, Res3}] = qp([
        ["HMGET", post_key(PostId), ?FIELD_UID, ?FIELD_PAYLOAD, ?FIELD_TAG,
                ?FIELD_AUDIENCE_TYPE, ?FIELD_TIMESTAMP_MS, ?FIELD_DELETED],
        ["SMEMBERS", post_audience_key(PostId)],
        ["HMGET", comment_key(CommentId, PostId), ?FIELD_PUBLISHER_UID, ?FIELD_PARENT_COMMENT_ID,
                ?FIELD_PAYLOAD, ?FIELD_TIMESTAMP_MS, ?FIELD_DELETED]]),
    [PostUid, PostPayload, PostTag, AudienceType, PostTsMs, IsPostDeletedBin] = Res1,
    AudienceList = Res2,
    [CommentPublisherUid, ParentCommentId, CommentPayload, CommentTsMs, IsCommentDeletedBin] = Res3,
    
    IsPostMissing = PostUid =:= undefined orelse util_redis:decode_boolean(IsPostDeletedBin, false),
    IsCommentMissing = CommentPublisherUid =:= undefined orelse
            util_redis:decode_boolean(IsCommentDeletedBin, false),

    {PostRet, PushRet} = case IsPostMissing of 
        true -> {{error, missing}, {error, missing}};
        false ->
            Post = #post{
                id = PostId,
                uid = PostUid,
                audience_type = decode_audience_type(AudienceType),
                audience_list = AudienceList,
                payload = PostPayload,
                tag = decode_post_tag(PostTag),
                ts_ms = util_redis:decode_ts(PostTsMs)
            },
            %% Fetch push data.
            ParentPushList = lists:usort(get_comment_push_data(ParentId, PostId)),
            {{ok, Post}, {ok, ParentPushList}}
    end,
    CommentRet = case IsCommentMissing of
        true -> {error, missing};
        false ->
            Comment = #comment{
                id = CommentId,
                post_id = PostId,
                publisher_uid = CommentPublisherUid,
                parent_id = util_redis:decode_maybe_binary(ParentCommentId),
                payload = CommentPayload,
                ts_ms = util_redis:decode_ts(CommentTsMs)
            },
            {ok, Comment}
    end,

    {PostRet, CommentRet, PushRet}.


%% Returns a list of uids to send a push notification for when replying to commentId on postId.
-spec get_comment_push_data(CommentId :: maybe(binary()), PostId :: binary()) -> [binary()].
get_comment_push_data(undefined, PostId) ->
    {ok, PostUid} = q(["HGET", post_key(PostId), ?FIELD_UID]),
    [PostUid];
get_comment_push_data(CommentId, PostId) ->
    {ok, [CommentPublisherUid, ParentCommentId]} = q(
        ["HMGET", comment_key(CommentId, PostId), ?FIELD_PUBLISHER_UID, ?FIELD_PARENT_COMMENT_ID]),
    ParentCommentIdValue = util_redis:decode_maybe_binary(ParentCommentId),
    ParentCommentPushData = get_comment_push_data(ParentCommentIdValue, PostId),
    [CommentPublisherUid | ParentCommentPushData].


-spec get_post_comments(PostId :: binary()) -> {ok, [comment()]} | {error, any()}.
get_post_comments(PostId) when is_binary(PostId) ->
    {ok, CommentIds} = q(["ZRANGEBYSCORE", post_comments_key(PostId), "-inf", "+inf"]),
    AllCommentsInfo = get_comments(CommentIds, PostId),
    Comments = lists:filtermap(
        fun(Comment) ->
            case Comment of
                {ok, CommentInfo} -> {true, CommentInfo};
                _ -> false
            end
        end, AllCommentsInfo),
    {ok, Comments}.


-spec add_uid_to_audience(Uid :: uid(), PostIds :: [binary()]) -> ok | {error, any()}.
add_uid_to_audience(Uid, PostIds) ->
    lists:foreach(fun(PostId) -> add_uid_to_audience_for_post(Uid, PostId) end, PostIds),
    ok.


-spec add_uid_to_audience_for_post(Uid :: uid(), PostId :: binary()) -> ok | {error, any()}.
add_uid_to_audience_for_post(Uid, PostId) ->
    {ok, _} = q(["SADD", post_audience_key(PostId), Uid]),
    ok.


-spec get_7day_user_feed(Uid :: uid()) -> {ok, [feed_item()]} | {error, any()}.
get_7day_user_feed(Uid) ->
    NowMs = util:now_ms(),
    DeadlineMs = NowMs - ?WEEKS_MS,
    get_user_feed(Uid, DeadlineMs).


-spec get_entire_user_feed(Uid :: uid()) -> {ok, [feed_item()]} | {error, any()}.
get_entire_user_feed(Uid) ->
    NowMs = util:now_ms(),
    DeadlineMs = NowMs - ?POST_TTL_MS,
    get_user_feed(Uid, DeadlineMs).


-spec get_7day_group_feed(Gid :: gid()) -> {ok, [feed_item()]} | {error, any()}.
get_7day_group_feed(Gid) ->
    NowMs = util:now_ms(),
    DeadlineMs = NowMs - ?WEEKS_MS,
    get_group_feed(Gid, DeadlineMs).


-spec get_entire_group_feed(Gid :: gid()) -> {ok, [feed_item()]} | {error, any()}.
get_entire_group_feed(Gid) ->
    NowMs = util:now_ms(),
    DeadlineMs = NowMs - ?POST_TTL_MS,
    get_group_feed(Gid, DeadlineMs).

-spec is_psa_tag_done(PSATag :: binary()) -> boolean().
is_psa_tag_done(PSATag) ->
    {ok, Value} = q(["HGET", psa_tag_key(PSATag), ?FIELD_PSA_TAG_DONE]),
    Value =:= <<"1">>.

-spec mark_psa_tag_done(PSATag :: binary()) -> ok.
mark_psa_tag_done(PSATag) ->
    [{ok, _}, {ok, _}] = qp([
        ["HSET", psa_tag_key(PSATag), ?FIELD_PSA_TAG_DONE, 1],
        ["EXPIRE", psa_tag_key(PSATag), ?POST_EXPIRATION]]),
    ok.

-spec del_psa_tag_done(PSATag :: binary()) -> boolean().
del_psa_tag_done(PSATag) ->
    {ok, Value} = q(["HDEL", psa_tag_key(PSATag), ?FIELD_PSA_TAG_DONE]),
    Value =:= <<"1">>.

-spec get_moment_time_to_send(Tag :: binary()) -> integer().
get_moment_time_to_send(Tag) ->
    {ok, Payload} = q(["GET", moment_time_to_send_key(Tag)]),
    case Payload of
        undefined ->
            %% from 3pm to 9pm local time.
            Rand = 15 + random:uniform(6),
            case set_moment_time_to_send(Rand, Tag) of
                true -> Rand;
                false -> get_moment_time_to_send(Tag)
            end;
        _ -> binary_to_integer(Payload)
    end.


-spec set_moment_time_to_send(Hr :: integer(), Tag :: binary()) -> boolean().
set_moment_time_to_send(Hr, Tag) ->
    {ok, Payload} = q(["SET", moment_time_to_send_key(Tag), util:to_binary(Hr),
                      "EX", ?MOMENT_TAG_EXPIRATION, "NX"]),
    Payload =:= <<"OK">>.

-spec is_moment_tag_done(Tag :: binary()) -> boolean().
is_moment_tag_done(Tag) ->
    {ok, Value} = q(["HGET", moment_tag_key(Tag), ?FIELD_MOMENT_TAG_DONE]),
    Value =:= <<"1">>.

-spec mark_moment_tag_done(Tag :: binary()) -> ok.
mark_moment_tag_done(Tag) ->
    [{ok, _}, {ok, _}] = qp([
        ["HSET", moment_tag_key(Tag), ?FIELD_MOMENT_TAG_DONE, 1],
        ["EXPIRE", moment_tag_key(Tag), ?MOMENT_TAG_EXPIRATION]]),
    ok.

-spec del_moment_tag_done(Tag :: binary()) -> boolean().
del_moment_tag_done(Tag) ->
    {ok, Value} = q(["HDEL", moment_tag_key(Tag), ?FIELD_MOMENT_TAG_DONE]),
    Value =:= <<"1">>.

-spec get_psa_tag_posts(PSATag :: binary()) -> {ok, [feed_item()]} | {error, any()}.
get_psa_tag_posts(PSATag) ->
    NowMs = util:now_ms(),
    DeadlineMs = NowMs - ?POST_TTL_MS,
    get_psa_tag_posts(PSATag, DeadlineMs).


-spec get_user_feed(Uid :: uid(), DeadlineMs :: integer()) -> {ok, [feed_item()]} | {error, any()}.
get_user_feed(Uid, DeadlineMs) ->
    {ok, AllPostIds} = q(["ZRANGEBYSCORE", reverse_post_key(Uid), integer_to_binary(DeadlineMs), "+inf"]),
    Posts = get_user_feed_posts(AllPostIds),
    PostIds = [PostId || #post{id = PostId} <- Posts],
    Comments = get_posts_comments(PostIds),
    {ok, lists:append(Posts, Comments)}.


-spec get_group_feed(Uid :: uid(), DeadlineMs :: integer()) -> {ok, [feed_item()]} | {error, any()}.
get_group_feed(Gid, DeadlineMs) ->
    {ok, AllPostIds} = q(["ZRANGEBYSCORE", reverse_group_post_key(Gid), integer_to_binary(DeadlineMs), "+inf"]),
    Posts = get_group_feed_posts(AllPostIds),
    PostIds = [PostId || #post{id = PostId} <- Posts],
    Comments = get_posts_comments(PostIds),
    {ok, lists:append(Posts, Comments)}.


-spec get_psa_tag_posts(PSATag :: binary(), DeadlineMs :: integer()) -> {ok, [feed_item()]} | {error, any()}.
get_psa_tag_posts(PSATag, DeadlineMs) ->
    {ok, AllPostIds} = q(["ZRANGEBYSCORE", reverse_psa_tag_key(PSATag), integer_to_binary(DeadlineMs), "+inf"]),
    FilterFun = fun (X) -> X =/= undefined end,
    {ok, get_posts(AllPostIds, FilterFun)}.


-spec cleanup_reverse_index(Uid :: uid()) -> ok.
cleanup_reverse_index(Uid) ->
    NowMs = util:now_ms(),
    DeadlineMs = NowMs - ?POST_TTL_MS,
    CleanupKeys = [reverse_post_key(Uid), reverse_comment_key(Uid)],
    CleanupCommands = get_cleanup_commands(CleanupKeys, DeadlineMs),
    [{ok, _}, {ok, _}] = qp(CleanupCommands),
    ok.


-spec cleanup_group_reverse_index(Gid :: gid()) -> ok.
cleanup_group_reverse_index(Gid) ->
    NowMs = util:now_ms(),
    DeadlineMs = NowMs - ?POST_TTL_MS,
    CleanupKeys = [reverse_group_post_key(Gid)],
    CleanupCommands = get_cleanup_commands(CleanupKeys, DeadlineMs),
    [{ok, _}] = qp(CleanupCommands),
    ok.

-spec cleanup_psa_tag_reverse_index(PSATag :: binary()) -> ok.
cleanup_psa_tag_reverse_index(PSATag) ->
    NowMs = util:now_ms(),
    DeadlineMs = NowMs - ?POST_TTL_MS,
    CleanupKeys = [reverse_psa_tag_key(PSATag)],
    CleanupCommands = get_cleanup_commands(CleanupKeys, DeadlineMs),
    [{ok, _}] = qp(CleanupCommands),
    ok.


-spec get_cleanup_commands(Keys :: [binary()], DeadlineMs :: integer()) -> [iodata()].
get_cleanup_commands(Keys, DeadlineMs) ->
    [["ZREMRANGEBYSCORE", Key, "-inf", integer_to_binary(DeadlineMs)] || Key <- Keys].


-spec get_posts(PostIds :: [binary()]) -> [post()].
get_posts(PostIds) ->
    FilterFun = fun (X) -> X =/= undefined end,
    get_posts(PostIds, FilterFun).


-spec get_user_feed_posts(PostIds :: [binary()]) -> [post()].
get_user_feed_posts(PostIds) ->
    FilterFun = fun (undefined) -> false;
            (#post{gid = undefined}) -> true;
            (_) -> false
        end,
    get_posts(PostIds, FilterFun).


-spec get_group_feed_posts(PostIds :: [binary()]) -> [post()].
get_group_feed_posts(PostIds) ->
    FilterFun = fun (undefined) -> false;
            (#post{gid = undefined}) -> false;
            (_) -> true
        end,
    get_posts(PostIds, FilterFun).


-spec get_posts(PostIds :: [binary()], FilterFun :: fun()) -> [post()].
get_posts(PostIds, FilterFun) ->
    Results = lists:map(
        fun (PostId) ->
            case get_post(PostId) of
                {ok, Post} -> Post;
                {error, missing} -> undefined
             end
        end,
        PostIds),
    lists:filter(FilterFun, Results).


-spec get_posts_comments(PostIds :: [binary()]) -> [comment()].
get_posts_comments(PostIds) ->
    Results = lists:map(
        fun (PostId) ->
            {ok, Comments} = get_post_comments(PostId),
            Comments
        end,
        PostIds),
    lists:flatten(Results).


-spec remove_user(Uid :: binary()) -> ok.
remove_user(Uid) ->
    {ok, PostIds} = q(["ZRANGEBYSCORE", reverse_post_key(Uid), "-inf", "+inf"]),
    {ok, CommentKeys} = q(["ZRANGEBYSCORE", reverse_comment_key(Uid), "-inf", "+inf"]),
    %% Delete all posts and their uid fields too.
    lists:foreach(fun(PostId) -> ok = delete_post(PostId, Uid) end, PostIds),
    %% Delete all comments and their publisher_uid fields too.
    lists:foreach(
        fun(CommentKey) ->
            {CommentId, PostId} = decode_comment_key(CommentKey),
            ok = retract_comment(CommentId, PostId)
        end, CommentKeys),
    %% Delete reverse indexes to them from uid related keys.
    [{ok, _}, {ok, _}] = qp([
        ["DEL", reverse_comment_key(Uid)],
        ["DEL", reverse_post_key(Uid)]]),
    ok.

-spec store_external_share_post(BlobId :: uid(), Payload :: binary(), ExpireIn :: integer()) -> boolean().
store_external_share_post(BlobId, Payload, ExpireIn) ->
    {ok, SetRes} = q(["SET", external_share_post_key(BlobId), Payload, "EX", ExpireIn, "NX"]),
    SetRes =:= <<"OK">>.

-spec delete_external_share_post(BlobId :: uid()) -> ok | {error, any()}.
delete_external_share_post(BlobId) ->
    util_redis:verify_ok(q(["DEL", external_share_post_key(BlobId)])).

-spec get_external_share_post(BlobId :: uid()) -> {ok, maybe(binary())} | {error, any()}.
get_external_share_post(BlobId) ->
    {ok, Payload} = q(["GET", external_share_post_key(BlobId)]),
    {ok, Payload}.
    

%%====================================================================
%% Internal functions
%%====================================================================

%% encode function should not allow any other values and crash here.
encode_audience_type(all) -> <<"a">>;
encode_audience_type(except) -> <<"e">>;
encode_audience_type(only) -> <<"o">>;
encode_audience_type(group) -> <<"g">>.

%% decode function should be able to handle undefined, since post need not exist.
decode_audience_type(<<"a">>) -> all;
decode_audience_type(<<"e">>) -> except;
decode_audience_type(<<"o">>) -> only;
decode_audience_type(<<"g">>) -> group;
decode_audience_type(_) -> undefined.


encode_post_tag(empty) -> <<"e">>;
encode_post_tag(secret_post) -> <<"s">>.

decode_post_tag(<<"s">>) -> secret_post;
decode_post_tag(<<"e">>) -> empty;
decode_post_tag(_) -> undefined.


decode_comment_key(CommentKey) ->
    [Part1, Part2] = re:split(CommentKey, "}:"),
    CommentKeyPrefix = ?COMMENT_KEY,
    %% this is not nice?
    <<CommentKeyPrefix:3/binary, "{", PostId/binary>> = Part1,
    CommentId = Part2,
    {CommentId, PostId}.


q(Command) -> ecredis:q(ecredis_feed, Command).
qp(Commands) -> ecredis:qp(ecredis_feed, Commands).
qmn(Commands) -> util_redis:run_qmn(ecredis_feed, Commands).


-spec post_key(PostId :: binary()) -> binary().
post_key(PostId) ->
    <<?POST_KEY/binary, "{", PostId/binary, "}">>.


-spec post_audience_key(PostId :: binary()) -> binary().
post_audience_key(PostId) ->
    <<?POST_AUDIENCE_KEY/binary, "{", PostId/binary, "}">>.


-spec comment_key(CommentId :: binary(), PostId :: binary()) -> binary().
comment_key(CommentId, PostId) ->
    <<?COMMENT_KEY/binary, "{", PostId/binary, "}:", CommentId/binary>>.


-spec post_comments_key(PostId :: binary()) -> binary().
post_comments_key(PostId) ->
    <<?POST_COMMENTS_KEY/binary, "{", PostId/binary, "}">>.


-spec reverse_post_key(Uid :: uid()) -> binary().
reverse_post_key(Uid) ->
    <<?REVERSE_POST_KEY/binary, "{", Uid/binary, "}">>.


-spec reverse_group_post_key(Gid :: uid()) -> binary().
reverse_group_post_key(Gid) ->
    <<?REVERSE_GROUP_POST_KEY/binary, "{", Gid/binary, "}">>.

-spec psa_tag_key(PSATag :: binary()) -> binary().
psa_tag_key(PSATag) ->
    <<?PSA_TAG_KEY/binary, "{", PSATag/binary, "}">>.

-spec reverse_psa_tag_key(PSATag :: binary()) -> binary().
reverse_psa_tag_key(PSATag) ->
    <<?REVERSE_PSA_TAG_KEY/binary, "{", PSATag/binary, "}">>.


-spec moment_time_to_send_key(Tag :: binary()) -> binary().
moment_time_to_send_key(Tag) ->
    <<?MOMENT_TIME_TO_SEND_KEY/binary, "{", Tag/binary, "}">>.

-spec moment_tag_key(Tag :: binary()) -> binary().
moment_tag_key(Tag) ->
    <<?MOMENT_TAG_KEY/binary, "{", Tag/binary, "}">>.

-spec reverse_comment_key(Uid :: uid()) -> binary().
reverse_comment_key(Uid) ->
    <<?REVERSE_COMMENT_KEY/binary, "{", Uid/binary, "}">>.

-spec external_share_post_key(BlobId :: binary()) -> binary().
external_share_post_key(BlobId) ->
    <<?SHARE_POST_KEY/binary, "{", BlobId/binary, "}">>.

