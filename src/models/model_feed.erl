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
    publish_moment/8,
    index_post_by_user_tags/4,
    get_public_moments/4,
    get_posts_by_time_bucket/6,
    get_posts_by_geo_tag_time_bucket/7,
    split_cursor/1,
    join_cursor/4,
    publish_comment/6,
    publish_comment/7,
    retract_post/2,
    retract_comment/2,
    get_post/1,
    get_posts/1,
    get_comment/2,
    get_post_comments/1,
    get_post_and_its_comments/1,
    get_comment_data/3,
    get_post_timestamp_ms/1,
    get_7day_user_feed/1,
    get_entire_user_feed/1,
    get_7day_group_feed/1,
    get_entire_group_feed/1,
    get_psa_tag_posts/1,
    is_psa_tag_done/1,
    mark_psa_tag_done/1,
    del_psa_tag_done/1,
    get_moment_time_to_send/2,
    set_moment_time_to_send/4,
    del_moment_time_to_send/1,
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
    get_external_share_post/1,
    generate_notification_time/1 %% test
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
-define(FIELD_COMMENT_TYPE, <<"ct">>).
-define(FIELD_DELETED, <<"del">>).
-define(FIELD_GROUP_ID, <<"gid">>).
-define(FIELD_PSA_TAG, <<"pst">>).
-define(FIELD_PSA_TAG_DONE, <<"ptd">>).
-define(FIELD_MOMENT_TAG_DONE, <<"mtd">>).
-define(FIELD_NUM_TAKES, <<"nt">>).
-define(FIELD_NOTIFICATION_TIMESTAMP, <<"nts">>).
-define(FIELD_TIME_TAKEN, <<"tt">>).
-define(FIELD_MOMENT_NOTIFICATION_ID, <<"nfi">>).
-define(FIELD_MOMENT_NOTIFICATION_TYPE, <<"nft">>).


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
    publish_post_internal(PostId, Uid, Payload, PostTag, FeedAudienceType, FeedAudienceList, TimestampMs, undefined).


 -spec publish_moment(PostId :: binary(), Uid :: uid(), Payload :: binary(), PostTag :: post_tag(),
        FeedAudienceType :: atom(), FeedAudienceList :: [binary()],
        TimestampMs :: integer(), MomentInfo :: pb_moment_info()) -> ok | {error, any()}.
publish_moment(PostId, Uid, Payload, PostTag, FeedAudienceType, FeedAudienceList, TimestampMs, MomentInfo) ->
    publish_post_internal(PostId, Uid, Payload, PostTag, FeedAudienceType, FeedAudienceList, TimestampMs, MomentInfo).


 -spec publish_post_internal(PostId :: binary(), Uid :: uid(), Payload :: binary(), PostTag :: post_tag(),
        FeedAudienceType :: atom(), FeedAudienceList :: [binary()],
        TimestampMs :: integer(), MomentInfo :: maybe(pb_moment_info())) -> ok | {error, any()}.
publish_post_internal(PostId, Uid, Payload, PostTag, FeedAudienceType, FeedAudienceList, TimestampMs, MomentInfo) ->
    {NumTakesBin, NotificationTimestampBin, TimeTakenBin} = encode_moment_info(MomentInfo),
    C1 = [["HSET", post_key(PostId),
        ?FIELD_UID, Uid,
        ?FIELD_PAYLOAD, Payload,
        ?FIELD_TAG, encode_post_tag(PostTag),
        ?FIELD_AUDIENCE_TYPE, encode_audience_type(FeedAudienceType),
        ?FIELD_TIMESTAMP_MS, integer_to_binary(TimestampMs),
        ?FIELD_NUM_TAKES, NumTakesBin,
        ?FIELD_NOTIFICATION_TIMESTAMP, NotificationTimestampBin,
        ?FIELD_TIME_TAKEN, TimeTakenBin]],
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
    index_post_by_user_tags(PostId, Uid, PostTag, TimestampMs),
    ok.


%% Indexes post-id by a specific geotag if the post-tag matches public content.
-spec index_post_by_user_tags(PostId :: binary(), Uid :: uid(), PostTag :: post_tag(), TimestampMs :: integer()) -> ok.
index_post_by_user_tags(PostId, Uid, PostTag, TimestampMs) ->
    try
        %% Index public content - only moments for now.
        %% Ignore posts for now.
        case PostTag =:= public_moment of
            true ->
                %% We could obtain other user info here like lang-id or cc etc and index by them as well.
                %% Obtain geo tag.
                GeoTag = model_accounts:get_latest_geo_tag(Uid),
                case GeoTag =:= undefined of
                    true ->
                        %% If GeoTag of the user is empty then index this post into other buckets
                        %% TODO: Extend this to other time buckets as well like country or language id.
                        %% Index onto time buckets only for now.
                        [{ok, _}, {ok, _}] = qp([
                            ["ZADD", time_bucket_key(TimestampMs), TimestampMs, PostId],
                            ["EXPIRE", time_bucket_key(TimestampMs), ?MOMENT_EXPIRATION]]),
                        ok;
                    false ->
                        %% Index onto geo-tag and time buckets.
                        [{ok, _}, {ok, _}] = qp([
                            ["ZADD", geo_tag_time_bucket_key(GeoTag, TimestampMs), TimestampMs, PostId],
                            ["EXPIRE", geo_tag_time_bucket_key(GeoTag, TimestampMs), ?MOMENT_EXPIRATION]]),
                        ok
                end;
            false -> ok
        end,
        ok
    catch
        _:_ ->
            ok
    end,
    ok.


-spec get_public_moments(GeoTag :: maybe(binary()), TimestampMs :: integer(), Cursor :: maybe(binary()), Limit :: integer()) -> [binary()].
get_public_moments(GeoTag, TimestampMs, Cursor, Limit) ->
    case GeoTag =:= undefined orelse GeoTag =:= <<>> of
        true ->
            case split_cursor(Cursor) of
                {undefined, undefined, undefined, undefined} ->
                    TimestampHr = floor(TimestampMs / ?HOURS_MS),
                    get_posts_by_time_bucket(TimestampHr, TimestampHr, undefined, Limit, Limit, []);
                {_, _, CursorPostId, CursorTimestampMs} ->
                    CursorTimestampHr = floor(CursorTimestampMs / ?HOURS_MS),
                    get_posts_by_time_bucket(CursorTimestampHr, CursorTimestampHr, CursorPostId, Limit, Limit, [])
            end;
        false ->
            case split_cursor(Cursor) of
                {undefined, undefined, undefined, undefined} ->
                    TimestampHr = floor(TimestampMs / ?HOURS_MS),
                    get_posts_by_geo_tag_time_bucket(GeoTag, TimestampHr, TimestampHr, undefined, Limit, Limit, []);
                {_, _, CursorPostId, CursorTimestampMs} ->
                    CursorTimestampHr = floor(CursorTimestampMs / ?HOURS_MS),
                    get_posts_by_geo_tag_time_bucket(GeoTag, CursorTimestampHr, CursorTimestampHr, CursorPostId, Limit, Limit, [])
            end
    end.


-spec get_posts_by_time_bucket(StartTimestampHr :: integer(), CurTimestampHr :: integer(),
        CursorPostId :: maybe(binary()), CurLimit :: integer(), Limit :: integer(), ResultPostIds :: [binary()]) -> [binary()].
get_posts_by_time_bucket(StartTimestampHr, CurTimestampHr,
        _CursorPostId, _CurLimit, _Limit, ResultPostIds)
        when StartTimestampHr - CurTimestampHr >= 24 ->
    ResultPostIds;
get_posts_by_time_bucket(StartTimestampHr, CurTimestampHr,
        CursorPostId, CurLimit, Limit, ResultPostIds) ->
    {ok, PostIds} = q(["ZREVRANGEBYSCORE", time_bucket_key_hr(CurTimestampHr), "+inf", "-inf"]),
    FinalResultPostIds = case util:index_of(CursorPostId, PostIds) of
        undefined ->
            ResultPostIds ++ lists:sublist(PostIds, CurLimit);
        Index ->
            ResultPostIds ++ lists:sublist(PostIds, Index+1, CurLimit)
    end,
    case length(FinalResultPostIds) >= Limit of
        true -> FinalResultPostIds;
        false ->
            NewLimit = Limit - length(FinalResultPostIds),
            get_posts_by_time_bucket(StartTimestampHr, CurTimestampHr-1,
                CursorPostId, NewLimit, Limit, FinalResultPostIds)
    end.


-spec get_posts_by_geo_tag_time_bucket(GeoTag :: binary(), StartTimestampHr :: integer(), CurTimestampHr :: integer(),
        CursorPostId :: maybe(binary()), CurLimit :: integer(), Limit :: integer(), ResultPostIds :: [binary()]) -> [binary()].
get_posts_by_geo_tag_time_bucket(_GeoTag, StartTimestampHr, CurTimestampHr,
        _CursorPostId, _CurLimit, _Limit, ResultPostIds)
        when StartTimestampHr - CurTimestampHr >= 24 ->
    ResultPostIds;
get_posts_by_geo_tag_time_bucket(GeoTag, StartTimestampHr, CurTimestampHr,
        CursorPostId, CurLimit, Limit, ResultPostIds) ->
    {ok, PostIds} = q(["ZREVRANGEBYSCORE", geo_tag_time_bucket_key_hr(GeoTag, CurTimestampHr), "+inf", "-inf"]),
    FinalResultPostIds = case util:index_of(CursorPostId, PostIds) of
        undefined ->
            ResultPostIds ++ lists:sublist(PostIds, CurLimit);
        Index ->
            ResultPostIds ++ lists:sublist(PostIds, Index+1, CurLimit)
    end,
    case length(FinalResultPostIds) >= Limit of
        true -> FinalResultPostIds;
        false ->
            NewLimit = Limit - length(FinalResultPostIds),
            get_posts_by_geo_tag_time_bucket(GeoTag, StartTimestampHr, CurTimestampHr-1,
                CursorPostId, NewLimit, Limit, FinalResultPostIds)
    end.


-spec split_cursor(Cursor :: binary()) -> {maybe(binary()), maybe(integer()), maybe(binary()), maybe(integer())}.
split_cursor(undefined) -> {undefined, undefined, undefined, undefined};
split_cursor(<<>>) -> {undefined, undefined, undefined, undefined};
split_cursor(Cursor) ->
    try
        [CursorVersion, RequestTimestampMsBin, CursorPostId, CursorTimestampMsBin] = re:split(Cursor, "::"),
        case RequestTimestampMsBin =:= <<>> orelse CursorPostId =:= <<>> orelse CursorTimestampMsBin =:= <<>> of
            true -> {undefined, undefined, undefined, undefined};
            false -> {CursorVersion, util:to_integer(RequestTimestampMsBin), CursorPostId, util:to_integer(CursorTimestampMsBin)}
        end
    catch
        _:_ ->
            ?ERROR("Failed to split cursor: ~p", [Cursor]),
            {undefined, undefined, undefined, undefined}
    end.


-spec join_cursor(VersionBin :: binary(), RequestTimestampMs :: integer(), CursorPostId :: binary(), CursorTimestampMs :: integer()) -> binary().
join_cursor(VersionBin, RequestTimestampMs, CursorPostId, CursorTimestampMs) ->
    RequestTimestampMsBin = util:to_binary(RequestTimestampMs),
    CursorTimestampMsBin = util:to_binary(CursorTimestampMs),
    <<VersionBin/binary, RequestTimestampMsBin/binary, "::", CursorPostId/binary, "::", CursorTimestampMsBin/binary>>.


-spec publish_comment(CommentId :: binary(), PostId :: binary(),
        PublisherUid :: uid(), ParentCommentId :: binary(),
        Payload :: binary(), TimestampMs :: integer()) -> ok | {error, any()}.
publish_comment(CommentId, PostId, PublisherUid, ParentCommentId, Payload, TimestampMs) ->
    publish_comment(CommentId, PostId, PublisherUid, ParentCommentId, comment, Payload, TimestampMs).


%% TODO(murali@): Write lua scripts for some functions in this module.
-spec publish_comment(CommentId :: binary(), PostId :: binary(),
        PublisherUid :: uid(), ParentCommentId :: binary(), CommentType :: comment_type(),
        Payload :: binary(), TimestampMs :: integer()) -> ok | {error, any()}.
publish_comment(CommentId, PostId, PublisherUid, ParentCommentId, CommentType, Payload, TimestampMs) ->
    {ok, TTL} = q(["TTL", post_key(PostId)]),
    ParentCommentIdValue = util_redis:encode_maybe_binary(ParentCommentId),
    [{ok, _}, {ok, _}] = qp([
            ["HSET", comment_key(CommentId, PostId),
                ?FIELD_PUBLISHER_UID, PublisherUid,
                ?FIELD_PARENT_COMMENT_ID, ParentCommentIdValue,
                ?FIELD_COMMENT_TYPE, encode_comment_type(CommentType),
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
        {ok, [Uid, Payload, PostTag, AudienceType, TimestampMs, Gid, PSATag, IsDeletedBin,
            NotificationTimestampBin, NumTakesBin, TimeTakenBin]},
        {ok, AudienceList}] = qp([
            ["HMGET", post_key(PostId),
                ?FIELD_UID, ?FIELD_PAYLOAD, ?FIELD_TAG, ?FIELD_AUDIENCE_TYPE, ?FIELD_TIMESTAMP_MS,
                ?FIELD_GROUP_ID, ?FIELD_PSA_TAG, ?FIELD_DELETED, ?FIELD_NOTIFICATION_TIMESTAMP,
                ?FIELD_NUM_TAKES, ?FIELD_TIME_TAKEN],
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
                psa_tag = PSATag,
                moment_info = decode_moment_info(NotificationTimestampBin, NumTakesBin, TimeTakenBin)
            }}
    end.


-spec get_comment(CommentId :: binary(), PostId :: binary()) -> {ok, comment()} | {error, any()}.
get_comment(CommentId, PostId) ->
    {ok, [PublisherUid, ParentCommentId, CommentTypeBin, Payload, TimestampMs, IsDeletedBin]} = q(
        ["HMGET", comment_key(CommentId, PostId),
            ?FIELD_PUBLISHER_UID, ?FIELD_PARENT_COMMENT_ID, ?FIELD_COMMENT_TYPE, ?FIELD_PAYLOAD, ?FIELD_TIMESTAMP_MS, ?FIELD_DELETED]),
    process_comment(CommentId, PostId, PublisherUid, ParentCommentId, CommentTypeBin, Payload, TimestampMs, IsDeletedBin).


-spec get_comments(CommentIds :: [binary()], PostId :: binary()) -> [{ok, comment()} | {error, any()}].
get_comments(CommentIds, PostId) ->
    Commands = lists:map(
        fun(CommentId) ->
            ["HMGET", comment_key(CommentId, PostId),
            ?FIELD_PUBLISHER_UID, ?FIELD_PARENT_COMMENT_ID, ?FIELD_COMMENT_TYPE, ?FIELD_PAYLOAD, ?FIELD_TIMESTAMP_MS, ?FIELD_DELETED]
        end, CommentIds),
    AllComments = qmn(Commands),
    Comments = lists:zipwith(
        fun(Comment, CommentId) ->
            {ok, [PublisherUid, ParentCommentId, CommentTypeBin, Payload, TimestampMs, IsDeletedBin]} = Comment,
            process_comment(CommentId, PostId, PublisherUid, ParentCommentId, CommentTypeBin, Payload, TimestampMs, IsDeletedBin)
        end, AllComments, CommentIds),
    Comments.


-spec process_comment(CommentId :: binary(), PostId :: binary(), PublisherUid :: binary(),
        ParentCommentId :: binary(), CommentTypeBin :: binary(), Payload :: binary(), TimestampMs :: binary(),
        IsDeletedBin :: binary()) -> {ok, comment()} | {error, any()}.
process_comment(CommentId, PostId, PublisherUid, ParentCommentId, CommentTypeBin, Payload, TimestampMs, IsDeletedBin) ->
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
            comment_type = decode_comment_type(CommentTypeBin),
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
                ?FIELD_AUDIENCE_TYPE, ?FIELD_TIMESTAMP_MS, ?FIELD_DELETED, ?FIELD_NOTIFICATION_TIMESTAMP,
                ?FIELD_NUM_TAKES, ?FIELD_TIME_TAKEN],
        ["SMEMBERS", post_audience_key(PostId)],
        ["HMGET", comment_key(CommentId, PostId), ?FIELD_PUBLISHER_UID, ?FIELD_PARENT_COMMENT_ID, ?FIELD_COMMENT_TYPE,
                ?FIELD_PAYLOAD, ?FIELD_TIMESTAMP_MS, ?FIELD_DELETED]]),
    [PostUid, PostPayload, PostTag, AudienceType, PostTsMs, IsPostDeletedBin, NotificationTimestampBin, NumTakesBin, TimeTakenBin] = Res1,
    AudienceList = Res2,
    [CommentPublisherUid, ParentCommentId, CommentTypeBin, CommentPayload, CommentTsMs, IsCommentDeletedBin] = Res3,
    
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
                ts_ms = util_redis:decode_ts(PostTsMs),
                moment_info = decode_moment_info(NotificationTimestampBin, NumTakesBin, TimeTakenBin)
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
                comment_type = decode_comment_type(CommentTypeBin),
                payload = CommentPayload,
                ts_ms = util_redis:decode_ts(CommentTsMs)
            },
            {ok, Comment}
    end,

    {PostRet, CommentRet, PushRet}.


-spec get_post_timestamp_ms(binary()) -> pos_integer().
get_post_timestamp_ms(PostId) ->
    {ok, Res} = q(["HGET", post_key(PostId), ?FIELD_TIMESTAMP_MS]),
    util_redis:decode_int(Res).


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

-spec get_moment_time_to_send(Tag :: integer(), DateTimeSecs :: integer()) -> {integer(), integer(), integer()}.
get_moment_time_to_send(Tag, DateTimeSecs) ->
    [{ok, Payload1}, {ok, Payload2}, {ok, Payload3}] =
        qp([["GET", moment_time_to_send_key(Tag)],
            ["HGET", moment_time_to_send_key2(Tag), ?FIELD_MOMENT_NOTIFICATION_ID],
            ["HGET", moment_time_to_send_key2(Tag), ?FIELD_MOMENT_NOTIFICATION_TYPE]]),
    case Payload1 of
        undefined ->
            Time = generate_notification_time(DateTimeSecs),
            %% NotificationType
            Type = rand:uniform(3),
            case set_moment_time_to_send(Time, DateTimeSecs, Type, Tag) of
                true -> {Time, DateTimeSecs, Type};
                false -> get_moment_time_to_send(Tag, DateTimeSecs)
            end;
        _ ->
            case Payload2 of
                undefined -> {binary_to_integer(Payload1), 0, 0};
                _ -> {binary_to_integer(Payload1), binary_to_integer(Payload2), binary_to_integer(Payload3)}
            end
    end.

generate_notification_time(DateTimeSecs) ->
    {Date, {_,_,_}} = calendar:system_time_to_universal_time(DateTimeSecs, second),
    DayOfWeek = calendar:day_of_the_week(Date),
    case DayOfWeek =:= 6 orelse DayOfWeek =:= 7 of
        true ->
            %% Weekend 9am to 9pm
            9*60 + rand:uniform(12*60);
        false ->
            %% from 12 to 1pm or from 3pm to 9pm local time.
            RandTime = 14*60 + rand:uniform(7*60),
            case RandTime < 15*60 of
                true -> RandTime - 2 * 60;
                false -> RandTime
            end
    end.
 
-spec set_moment_time_to_send(Time :: integer(), Id :: integer(), Type :: integer(), Tag :: integer()) -> boolean().
set_moment_time_to_send(Time, Id, Type, Tag) ->
    {ok, Payload} = q(["SET", moment_time_to_send_key(Tag), util:to_binary(Time),
                      "EX", ?MOMENT_TAG_EXPIRATION, "NX"]),
    case Payload =:= <<"OK">> of
        true ->
            qp([["HSET", moment_time_to_send_key2(Tag), ?FIELD_MOMENT_NOTIFICATION_ID, util:to_binary(Id)],
                ["HSET", moment_time_to_send_key2(Tag), ?FIELD_MOMENT_NOTIFICATION_TYPE, util:to_binary(Type)],
                ["EXPIRE", moment_time_to_send_key2(Tag), ?MOMENT_TAG_EXPIRATION]]),
            true;
        false -> false
    end.
                

-spec del_moment_time_to_send(Tag :: integer()) -> ok.
del_moment_time_to_send(Tag) ->
    util_redis:verify_ok(qp([["DEL", moment_time_to_send_key(Tag)], ["DEL", moment_time_to_send_key2(Tag)]])).

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
encode_post_tag(moment) -> <<"s">>;
encode_post_tag(public_post) -> <<"pp">>;
encode_post_tag(public_moment) -> <<"pm">>.

decode_post_tag(<<"s">>) -> moment;
decode_post_tag(<<"e">>) -> empty;
decode_post_tag(<<"pp">>) -> public_post;
decode_post_tag(<<"pm">>) -> public_moment;
decode_post_tag(_) -> undefined.


encode_moment_info(undefined) -> {<<>>, <<>>, <<>>};
encode_moment_info(#pb_moment_info{notification_timestamp = NotifTs, num_takes = NumTakes, time_taken = TimeTaken}) ->
    NotificationTimestampBin = case NotifTs of
        undefined -> <<>>;
        0 -> <<>>;
        _ -> util:to_binary(NotifTs)
    end,
    NumTakesBin = case NumTakes of
        undefined -> <<>>;
        0 -> <<>>;
        _ -> util:to_integer(NumTakes)
    end,
    TimeTakenBin = case TimeTaken of
        undefined -> <<>>;
        0 -> <<>>;
        _ -> util:to_integer(TimeTaken)
    end,
    {NotificationTimestampBin, NumTakesBin, TimeTakenBin}.


decode_moment_info(NotificationTimestampBin, NumTakesBin, TimeTakenBin) ->
    NotifTs = case NotificationTimestampBin of
        undefined -> 0;
        <<>> -> 0;
        _ -> util:to_integer(NotificationTimestampBin)
    end,
    NumTakes = case NumTakesBin of
        undefined -> 0;
        <<>> -> 0;
        _ -> util:to_integer(NumTakesBin)
    end,
    TimeTaken = case TimeTakenBin of
        undefined -> 0;
        <<>> -> 0;
        _ -> util:to_integer(TimeTakenBin)
    end,
    case NotifTs =:= 0 andalso NumTakes =:= 0 andalso TimeTaken =:= 0 of
        true -> undefined;
        false ->
            #pb_moment_info{
                notification_timestamp = NotifTs,
                num_takes = NumTakes,
                time_taken = TimeTaken
            }
    end.


encode_comment_type(comment) -> <<"c">>;
encode_comment_type(comment_reaction) -> <<"cr">>;
encode_comment_type(post_reaction) -> <<"pr">>.


decode_comment_type(<<"c">>) -> comment;
decode_comment_type(<<"cr">>) -> comment_reaction;
decode_comment_type(<<"pr">>) -> post_reaction.


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

-spec moment_time_to_send_key2(Tag :: integer()) -> binary().
moment_time_to_send_key2(Tag) ->
    TagBin = util:to_binary(Tag),
    <<?MOMENT_TIME_TO_SEND_KEY2/binary, "{", TagBin/binary, "}">>.

-spec moment_time_to_send_key(Tag :: integer()) -> binary().
moment_time_to_send_key(Tag) ->
    TagBin = util:to_binary(Tag),
    <<?MOMENT_TIME_TO_SEND_KEY/binary, "{", TagBin/binary, "}">>.

-spec moment_tag_key(Tag :: binary()) -> binary().
moment_tag_key(Tag) ->
    <<?MOMENT_TAG_KEY/binary, "{", Tag/binary, "}">>.

-spec reverse_comment_key(Uid :: uid()) -> binary().
reverse_comment_key(Uid) ->
    <<?REVERSE_COMMENT_KEY/binary, "{", Uid/binary, "}">>.

-spec external_share_post_key(BlobId :: binary()) -> binary().
external_share_post_key(BlobId) ->
    <<?SHARE_POST_KEY/binary, "{", BlobId/binary, "}">>.

-spec time_bucket_key(TimestampMs :: integer()) -> binary().
time_bucket_key(TimestampMs) ->
    TimestampHr = floor(TimestampMs / (1 * ?HOURS_MS)),
    time_bucket_key_hr(TimestampHr).


-spec time_bucket_key_hr(TimestampHr :: integer()) -> binary().
time_bucket_key_hr(TimestampHr) ->
    TimestampHrBin = util:to_binary(TimestampHr),
    <<?TIME_BUCKET_KEY/binary, "{", TimestampHrBin/binary, "}">>.


-spec geo_tag_time_bucket_key(GeoTag :: atom(), TimestampMs :: integer()) -> binary().
geo_tag_time_bucket_key(GeoTag, TimestampMs) ->
    TimestampHr = floor(TimestampMs / (1 * ?HOURS_MS)),
    GeoTagBin = util:to_binary(GeoTag),
    geo_tag_time_bucket_key_hr(GeoTagBin, TimestampHr).


-spec geo_tag_time_bucket_key_hr(GeoTag :: binary(), TimestampHr :: integer()) -> binary().
geo_tag_time_bucket_key_hr(GeoTag, TimestampHr) ->
    GeoTagBin = util:to_binary(GeoTag),
    TimestampHrBin = util:to_binary(TimestampHr),
    <<?GEO_TAG_TIME_BUCKET_KEY/binary, ":", GeoTagBin/binary, "{", TimestampHrBin/binary, "}">>.

