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
-behavior(gen_mod).

-include("logger.hrl").
-include("redis_keys.hrl").
-include("feed.hrl").

%% Export all functions for unit tests
-ifdef(TEST).
-compile(export_all).
-endif.

%% gen_mod callbacks
-export([start/2, stop/1, depends/2, mod_options/1]).

-export([post_key/1, comment_key/2, post_comments_key/1, reverse_post_key/1]).


%% API
-export([
    publish_post/6,
    publish_comment/7,
    retract_post/2,
    retract_comment/2,
    get_post/1,
    get_comment/2,
    get_post_and_its_comments/1,
    get_comment_data/3,
    get_7day_user_feed/1,
    get_entire_user_feed/1,
    is_post_owner/2,
    remove_all_user_posts/1,
    add_uid_to_audience/2,
    is_post_deleted/1    %% test.
]).

%% TODO(murali@): expose more apis specific to posts and comments only if necessary.

%%====================================================================
%% gen_mod callbacks
%%====================================================================


start(_Host, _Opts) ->
    ?INFO("start ~w", [?MODULE]),
    ok.

stop(_Host) ->
    ?INFO("start ~w", [?MODULE]),
    ok.

depends(_Host, _Opts) ->
    [{mod_redis, hard}].

mod_options(_Host) ->
    [].


%%====================================================================
%% API
%%====================================================================

-define(FIELD_UID, <<"uid">>).
-define(FIELD_PAYLOAD, <<"pl">>).
-define(FIELD_AUDIENCE_TYPE, <<"fa">>).
-define(FIELD_TIMESTAMP_MS, <<"ts">>).
-define(FIELD_PUBLISHER_UID, <<"pbu">>).
-define(FIELD_PARENT_COMMENT_ID, <<"pc">>).

-spec publish_post(PostId :: binary(), Uid :: uid(), Payload :: binary(),
        FeedAudienceType :: atom(), FeedAudienceList :: [binary()],
        TimestampMs :: integer()) -> ok | {error, any()}.
publish_post(PostId, Uid, Payload, FeedAudienceType, FeedAudienceList, TimestampMs) ->
    DeadlineMs = TimestampMs - ?POST_TTL_MS,
    [{ok, _}, {ok, _}, {ok, _}, {ok, _}] = qp([
            ["HSET", post_key(PostId),
                ?FIELD_UID, Uid,
                ?FIELD_PAYLOAD, Payload,
                ?FIELD_AUDIENCE_TYPE, encode_audience_type(FeedAudienceType),
                ?FIELD_TIMESTAMP_MS, integer_to_binary(TimestampMs)],
            ["SADD", post_audience_key(PostId) | FeedAudienceList],
            ["EXPIRE", post_key(PostId), ?POST_EXPIRATION],
            ["EXPIRE", post_audience_key(PostId), ?POST_EXPIRATION]]),
    [{ok, _}, {ok, _}] = qp([
            ["ZADD", reverse_post_key(Uid), TimestampMs, PostId],
            ["EXPIRE", reverse_post_key(Uid), ?POST_EXPIRATION]]),
    CleanupCommands = get_cleanup_commands(Uid, DeadlineMs),
    [{ok, _}, {ok, _}] = qp(CleanupCommands),
    ok.


%% TODO(murali@): Write lua scripts for some functions in this module.
-spec publish_comment(CommentId :: binary(), PostId :: binary(),
        PublisherUid :: uid(), ParentCommentId :: binary(), PushList :: [binary()],
        Payload :: binary(), TimestampMs :: integer()) -> ok | {error, any()}.
publish_comment(CommentId, PostId, PublisherUid,
        ParentCommentId, PushList, Payload, TimestampMs) ->
    DeadlineMs = TimestampMs - ?POST_TTL_MS,
    {ok, TTL} = q(["TTL", post_key(PostId)]),
    [{ok, _}, {ok, _}, {ok, _}, {ok, _}] = qp([
            ["HSET", comment_key(CommentId, PostId),
                ?FIELD_PUBLISHER_UID, PublisherUid,
                ?FIELD_PARENT_COMMENT_ID, ParentCommentId,
                ?FIELD_PAYLOAD, Payload,
                ?FIELD_TIMESTAMP_MS, integer_to_binary(TimestampMs)],
            ["SADD", comment_push_list_key(CommentId, PostId) | PushList],
            ["EXPIRE", comment_push_list_key(CommentId, PostId), TTL],
            ["EXPIRE", comment_key(CommentId, PostId), TTL]]),
    [{ok, _}, {ok, _}] = qp([
            ["ZADD", post_comments_key(PostId), TimestampMs, CommentId],
            ["EXPIRE", post_comments_key(PostId), TTL]]),
    {ok, _} = q(
            ["ZADD", reverse_comment_key(PublisherUid), TimestampMs, comment_key(CommentId, PostId)]),
    CleanupCommands = get_cleanup_commands(PublisherUid, DeadlineMs),
    [{ok, _}, {ok, _}] = qp(CleanupCommands),
    ok.


-spec is_post_owner(PostId :: binary(), Uid :: uid()) -> {ok, boolean()}.
is_post_owner(PostId, Uid) ->
    {ok, OwnerUid} = q(["HGET", post_key(PostId), ?FIELD_UID]),
    Result = OwnerUid =:= Uid,
    {ok, Result}.


%% We should do the check if Uid is the owner of PostId.
-spec retract_post(PostId :: binary(), Uid :: uid()) -> ok | {error, any()}.
retract_post(PostId, Uid) ->
    ok = cleanup_old_posts(Uid),
    delete_post(PostId, Uid),
    ok.


-spec delete_post(PostId :: binary(), Uid :: uid()) -> ok | {error, any()}.
delete_post(PostId, Uid) ->
    {ok, CommentIds} = q(["ZRANGEBYSCORE", post_comments_key(PostId), "-inf", "+inf"]),

    %% Get all comment keys.
    CommentKeys = [[comment_key(CommentId, PostId), comment_push_list_key(CommentId, PostId)] || CommentId <- CommentIds],
    FinalKeys = lists:flatten(CommentKeys),

    %% Cleanup reverse index of comments.
    %% TODO(murali@): remove this cleanup after adding the deleted field for comments.
    Results = qp([
            ["HGET", comment_key(CommentId, PostId), ?FIELD_PUBLISHER_UID] || CommentId <- CommentIds]),
    ZippedResults = lists:zip(Results, CommentIds),
    CleanupCommands = [["ZREM", reverse_comment_key(Uid), comment_key(CommentId, PostId)]
            || {{ok, PublisherUid}, CommentId} <- ZippedResults, PublisherUid =/= undefined],
    lists:foreach(fun(CleanupCommand) -> {ok, _} = q(CleanupCommand) end, CleanupCommands),

    %% Delete content in post, delete all comments, leave a tombstone for the post.
    [{ok, _}, {ok, _}, {ok, _}] = qp([
            ["DEL", post_audience_key(PostId), post_comments_key(PostId) | FinalKeys],
            ["HDEL", post_key(PostId), ?FIELD_PAYLOAD, ?FIELD_AUDIENCE_TYPE],
            ["RENAME", post_key(PostId), deleted_post_key(PostId)]]),

    %% Cleanup reverse index for posts.
    %% TODO(murali@): remove this cleanup after adding the deleted field.
    {ok, _} = q(["ZREM", reverse_post_key(Uid), PostId]),
    ok.


-spec is_post_deleted(PostId :: binary()) -> boolean().
is_post_deleted(PostId) ->
    {ok, Res} = q(["EXISTS", deleted_post_key(PostId)]),
    binary_to_integer(Res) == 1.


-spec retract_comment(CommentId :: binary(), PostId :: binary()) -> ok | {error, any()}.
retract_comment(CommentId, PostId) ->
    {ok, PublisherUid} = q(["HGET", comment_key(CommentId, PostId), ?FIELD_PUBLISHER_UID]),
    [{ok, _}, {ok, _}, {ok, _}] = qp([
            ["DEL", comment_key(CommentId, PostId)],
            ["DEL", comment_push_list_key(CommentId, PostId)],
            ["ZREM", post_comments_key(PostId), CommentId]]),
    %% Cleanup reverse index for commentId
    %% TODO(murali@): remove this cleanup after adding the deleted field.
    {ok, _} = q(["ZREM", reverse_comment_key(PublisherUid), comment_key(CommentId, PostId)]),
    ok.


-spec remove_all_user_posts(Uid :: uid()) -> ok.
remove_all_user_posts(Uid) ->
    {ok, PostIds} = q(["ZRANGEBYSCORE", reverse_post_key(Uid), "-inf", "+inf"]),
    lists:foreach(fun(PostId) -> ok = delete_post(PostId, Uid) end, PostIds),
    ok.


-spec get_post(PostId :: binary()) -> {ok, post()} | {error, any()}.
get_post(PostId) ->
    [{ok, [Uid, Payload, AudienceType, TimestampMs]}, {ok, AudienceList}] = qp([
            ["HMGET", post_key(PostId),
                ?FIELD_UID, ?FIELD_PAYLOAD, ?FIELD_AUDIENCE_TYPE, ?FIELD_TIMESTAMP_MS],
            ["SMEMBERS", post_audience_key(PostId)]]),
    case Uid =:= undefined orelse Payload =:= undefined orelse TimestampMs =:= undefined of
        true -> {error, missing};
        false ->
            {ok, #post{
                id = PostId,
                uid = Uid,
                audience_type = decode_audience_type(AudienceType),
                audience_list = AudienceList,
                payload = Payload,
                ts_ms = util_redis:decode_ts(TimestampMs)}}
    end.


-spec get_comment(CommentId :: binary(), PostId :: binary()) -> {ok, comment()} | {error, any()}.
get_comment(CommentId, PostId) ->
    {ok, [PublisherUid, ParentCommentId, Payload, TimestampMs]} = q(
        ["HMGET", comment_key(CommentId, PostId),
            ?FIELD_PUBLISHER_UID, ?FIELD_PARENT_COMMENT_ID, ?FIELD_PAYLOAD, ?FIELD_TIMESTAMP_MS]),
    case PublisherUid =:= undefined orelse Payload =:= undefined orelse TimestampMs =:= undefined of
        true -> {error, missing};
        false -> {ok, #comment{
            id = CommentId,
            post_id = PostId,
            publisher_uid = PublisherUid, parent_id = ParentCommentId,
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
-spec get_comment_data(PostId :: binary(), CommentId :: binary(),
        ParentId :: binary()) -> [{ok, feed_item()}] | {error, any()}.
get_comment_data(PostId, CommentId, ParentId) ->
    PushListCommands = case ParentId of
        <<>> -> [];
        _ -> [["SMEMBERS", comment_push_list_key(ParentId, PostId)]]
    end,
    [{ok, Res1}, {ok, Res2}, {ok, Res3} | Rest] = qp([
        ["HMGET", post_key(PostId), ?FIELD_UID, ?FIELD_PAYLOAD, ?FIELD_AUDIENCE_TYPE, ?FIELD_TIMESTAMP_MS],
        ["SMEMBERS", post_audience_key(PostId)],
        ["HMGET", comment_key(CommentId, PostId), ?FIELD_PUBLISHER_UID, ?FIELD_PARENT_COMMENT_ID,
                ?FIELD_PAYLOAD, ?FIELD_TIMESTAMP_MS] | PushListCommands]),
    [PostUid, PostPayload, AudienceType, PostTsMs] = Res1,
    AudienceList = Res2,
    [CommentPublisherUid, ParentCommentId, CommentPayload, CommentTsMs] = Res3,
    ParentPushList = case PushListCommands of
        [] -> [];
        _ ->
            [{ok, Res4}] = Rest,
            Res4
    end,
    Post = #post{
        id = PostId,
        uid = PostUid,
        audience_type = decode_audience_type(AudienceType),
        audience_list = AudienceList,
        payload = PostPayload,
        ts_ms = util_redis:decode_ts(PostTsMs)
    },
    Comment = #comment{
        id = CommentId,
        post_id = PostId,
        publisher_uid = CommentPublisherUid,
        parent_id = ParentCommentId,
        payload = CommentPayload,
        ts_ms = util_redis:decode_ts(CommentTsMs)
    },
    if
        PostUid =:= undefined andalso CommentPublisherUid =:= undefined ->
            [{error, missing}, {error, missing}, {error, missing}];
        PostUid =/= undefined andalso CommentPublisherUid =:= undefined ->
            [{ok, Post}, {error, missing}, {ok, ParentPushList}];
        PostUid =:= undefined andalso CommentPublisherUid =/= undefined ->
            ?ERROR("Invalid internal state: postid: ~p, commentid: ~p", [PostId, CommentId]),
            [{error, missing}, {error, missing}, {error, missing}];
        true ->
            [{ok, Post}, {ok, Comment}, {ok, ParentPushList}]
    end.


-spec get_post_comments(PostId :: binary()) -> {ok, [comment()]} | {error, any()}.
get_post_comments(PostId) when is_binary(PostId) ->
    {ok, CommentIds} = q(["ZRANGEBYSCORE", post_comments_key(PostId), "-inf", "+inf"]),
    Comments = lists:map(
        fun(CommentId) ->
            {ok, Comment} = get_comment(CommentId, PostId),
            Comment
        end, CommentIds),
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


-spec get_user_feed(Uid :: uid(), DeadlineMs :: integer()) -> {ok, [feed_item()]} | {error, any()}.
get_user_feed(Uid, DeadlineMs) ->
    ok = cleanup_old_posts(Uid),
    {ok, PostIds} = q(["ZRANGEBYSCORE", reverse_post_key(Uid), integer_to_binary(DeadlineMs), "+inf"]),
    Posts = get_posts(PostIds),
    Comments = get_posts_comments(PostIds),
    {ok, lists:append(Posts, Comments)}.


-spec cleanup_old_posts(Uid :: uid()) -> ok.
cleanup_old_posts(Uid) ->
    NowMs = util:now_ms(),
    DeadlineMs = NowMs - ?POST_TTL_MS,
    CleanupCommands = get_cleanup_commands(Uid, DeadlineMs),
    [{ok, _}, {ok, _}] = qp(CleanupCommands),
    ok.


-spec get_cleanup_commands(Uid :: uid(), DeadlineMs :: integer()) -> [iodata()].
get_cleanup_commands(Uid, DeadlineMs) ->
    [
        ["ZREMRANGEBYSCORE", reverse_post_key(Uid), "-inf", integer_to_binary(DeadlineMs)],
        ["ZREMRANGEBYSCORE", reverse_comment_key(Uid), "-inf", integer_to_binary(DeadlineMs)]
    ].


-spec get_posts(PostIds :: [binary()]) -> [post()].
get_posts(PostIds) ->
    Results = lists:map(
        fun (PostId) ->
            case get_post(PostId) of
                {ok, Post} -> Post;
                {error, missing} -> undefined
             end
        end,
        PostIds),
    lists:filter(fun (X) -> X =/= undefined end, Results).


-spec get_posts_comments(PostIds :: [binary()]) -> [comment()].
get_posts_comments(PostIds) ->
    Results = lists:map(
        fun (PostId) ->
            {ok, Comments} = get_post_comments(PostId),
            Comments
        end,
        PostIds),
    lists:flatten(Results).


%%====================================================================
%% Internal functions
%%====================================================================

%% encode function should not allow any other values and crash here.
encode_audience_type(all) -> <<"a">>;
encode_audience_type(except) -> <<"e">>;
encode_audience_type(only) -> <<"o">>.

%% decode function should be able to handle undefined, since post need not exist.
decode_audience_type(<<"a">>) -> all;
decode_audience_type(<<"e">>) -> except;
decode_audience_type(<<"o">>) -> only;
decode_audience_type(_) -> undefined.


decode_comment_key(CommentKey) ->
    [Part1, Part2] = re:split(CommentKey, "}:"),
    CommentKeyPrefix = ?COMMENT_KEY,
    %% this is not nice?
    <<CommentKeyPrefix:3/binary, "{", PostId/binary>> = Part1,
    CommentId = Part2,
    {PostId, CommentId}.


q(Command) -> ecredis:q(ecredis_feed, Command).
qp(Commands) -> ecredis:qp(ecredis_feed, Commands).


-spec post_key(PostId :: binary()) -> binary().
post_key(PostId) ->
    <<?POST_KEY/binary, "{", PostId/binary, "}">>.


-spec deleted_post_key(binary()) -> binary().
deleted_post_key(Uid) ->
    <<?DELETED_POST_KEY/binary, <<"{">>/binary, Uid/binary, <<"}">>/binary>>.

-spec post_audience_key(PostId :: binary()) -> binary().
post_audience_key(PostId) ->
    <<?POST_AUDIENCE_KEY/binary, "{", PostId/binary, "}">>.


-spec comment_key(CommentId :: binary(), PostId :: binary()) -> binary().
comment_key(CommentId, PostId) ->
    <<?COMMENT_KEY/binary, "{", PostId/binary, "}:", CommentId/binary>>.


-spec comment_push_list_key(CommentId :: binary(), PostId :: binary()) -> binary().
comment_push_list_key (CommentId, PostId) ->
    <<?COMMENT_PUSH_LIST_KEY/binary, "{", PostId/binary, "}:", CommentId/binary>>.


-spec post_comments_key(PostId :: binary()) -> binary().
post_comments_key(PostId) ->
    <<?POST_COMMENTS_KEY/binary, "{", PostId/binary, "}">>.


-spec reverse_post_key(Uid :: uid()) -> binary().
reverse_post_key(Uid) ->
    <<?REVERSE_POST_KEY/binary, "{", Uid/binary, "}">>.


-spec reverse_comment_key(Uid :: uid()) -> binary().
reverse_comment_key(Uid) ->
    <<?REVERSE_COMMENT_KEY/binary, "{", Uid/binary, "}">>.

