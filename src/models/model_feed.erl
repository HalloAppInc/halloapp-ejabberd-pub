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
    is_post_deleted/1,    %% test.
    is_comment_deleted/2    %% test.
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
-define(FIELD_DELETED, <<"del">>).

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
delete_post(PostId, _Uid) ->
    {ok, CommentIds} = q(["ZRANGEBYSCORE", post_comments_key(PostId), "-inf", "+inf"]),

    %% Delete all comments content and leave tombstone.
    CommentDeleteCommands = lists:foldl(
            fun(CommentId, Acc) ->
                [
                ["HDEL", comment_key(CommentId, PostId), ?FIELD_PAYLOAD],
                ["HSET", comment_key(CommentId, PostId), ?FIELD_DELETED, 1],
                ["DEL", comment_push_list_key(CommentId, PostId)]
                | Acc]
            end, [], CommentIds),
    case CommentIds of
        [] -> ok;
        _ -> qp(CommentDeleteCommands)
    end,

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
    Res =:= <<"1">>.


-spec is_comment_deleted(CommentId :: binary(), PostId :: binary()) -> boolean().
is_comment_deleted(CommentId, PostId) ->
    {ok, Res} = q(["HGET", comment_key(CommentId, PostId), ?FIELD_DELETED]),
    Res =:= <<"1">>.


-spec retract_comment(CommentId :: binary(), PostId :: binary()) -> ok | {error, any()}.
retract_comment(CommentId, PostId) ->
    [{ok, _}, {ok, _}, {ok, _}] = qp([
            ["HDEL", comment_key(CommentId, PostId), ?FIELD_PAYLOAD],
            ["HSET", comment_key(CommentId, PostId), ?FIELD_DELETED, 1],
            ["DEL", comment_push_list_key(CommentId, PostId)]]),
    ok.


-spec remove_all_user_posts(Uid :: uid()) -> ok.
remove_all_user_posts(Uid) ->
    {ok, PostIds} = q(["ZRANGEBYSCORE", reverse_post_key(Uid), "-inf", "+inf"]),
    lists:foreach(fun(PostId) -> ok = delete_post(PostId, Uid) end, PostIds),
    {ok, _} = q(["DEL", reverse_post_key(Uid)]),
    ok.


-spec get_post(PostId :: binary()) -> {ok, post()} | {error, any()}.
get_post(PostId) ->
    [{ok, [Uid, Payload, AudienceType, TimestampMs, IsDeletedBin]}, {ok, AudienceList}] = qp([
            ["HMGET", post_key(PostId),
                ?FIELD_UID, ?FIELD_PAYLOAD, ?FIELD_AUDIENCE_TYPE, ?FIELD_TIMESTAMP_MS, ?FIELD_DELETED],
            ["SMEMBERS", post_audience_key(PostId)]]),
    IsDeleted = (IsDeletedBin =:= <<"1">>),
    %% TODO(murali@): Update the condition after one month, since then all items in db will have the field.
    case Uid =:= undefined orelse Payload =:= undefined orelse
            TimestampMs =:= undefined orelse IsDeleted =:= true of
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
    {ok, [PublisherUid, ParentCommentId, Payload, TimestampMs, IsDeletedBin]} = q(
        ["HMGET", comment_key(CommentId, PostId),
            ?FIELD_PUBLISHER_UID, ?FIELD_PARENT_COMMENT_ID, ?FIELD_PAYLOAD, ?FIELD_TIMESTAMP_MS, ?FIELD_DELETED]),
    IsDeleted = (IsDeletedBin =:= <<"1">>),
    %% TODO(murali@): Update the condition after one month, since then all items in db will have the field.
    case PublisherUid =:= undefined orelse Payload =:= undefined orelse
            TimestampMs =:= undefined orelse IsDeleted =:= true of
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
        ["HMGET", post_key(PostId), ?FIELD_UID, ?FIELD_PAYLOAD,
                ?FIELD_AUDIENCE_TYPE, ?FIELD_TIMESTAMP_MS, ?FIELD_DELETED],
        ["SMEMBERS", post_audience_key(PostId)],
        ["HMGET", comment_key(CommentId, PostId), ?FIELD_PUBLISHER_UID, ?FIELD_PARENT_COMMENT_ID,
                ?FIELD_PAYLOAD, ?FIELD_TIMESTAMP_MS] | PushListCommands]),
    [PostUid, PostPayload, AudienceType, PostTsMs, IsPostDeletedBin] = Res1,
    AudienceList = Res2,
    [CommentPublisherUid, ParentCommentId, CommentPayload, CommentTsMs] = Res3,
    ParentPushList = case PushListCommands of
        [] -> [PostUid];
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
    IsPostDeleted = (IsPostDeletedBin =:= <<"1">>),

    %% Fetch and compare push data.
    ParentPushList2 = get_comment_push_data(ParentId, PostId),
    Set1 = sets:from_list(ParentPushList),
    Set2 = sets:from_list(ParentPushList2),
    case Set1 =:= Set2 of
        true ->
            ?INFO("Push data matches: ~p", [ParentPushList]);
        false ->
            ?ERROR("Push data mismatch, original: ~p, new: ~p", [ParentPushList, ParentPushList2])
    end,

    %% TODO(murali@): update these conditions after a few weeks to use the deleted field.
    if
        (PostUid =:= undefined orelse IsPostDeleted =:= true) andalso
                CommentPublisherUid =:= undefined ->
            [{error, missing}, {error, missing}, {error, missing}];
        PostUid =/= undefined andalso CommentPublisherUid =:= undefined ->
            [{ok, Post}, {error, missing}, {ok, ParentPushList}];
        PostUid =:= undefined andalso CommentPublisherUid =/= undefined ->
            ?ERROR("Invalid internal state: postid: ~p, commentid: ~p", [PostId, CommentId]),
            [{error, missing}, {error, missing}, {error, missing}];
        true ->
            [{ok, Post}, {ok, Comment}, {ok, ParentPushList}]
    end.


%% Test for now, remove it in a couple of days.
%% Returns a list of uids to send a push notification for when replying to commentId on postId.
-spec get_comment_push_data(CommentId :: binary(), PostId :: binary()) -> [binary()].
get_comment_push_data(undefined, PostId) ->
    ?ERROR("Invalid parent_id here for post: ~p", [PostId]),
    [];
get_comment_push_data(<<>>, PostId) ->
    {ok, PostUid} = q(["HGET", post_key(PostId), ?FIELD_UID]),
    [PostUid];
get_comment_push_data(CommentId, PostId) ->
    {ok, [CommentPublisherUid, ParentCommentId]} = q(
        ["HMGET", comment_key(CommentId, PostId), ?FIELD_PUBLISHER_UID, ?FIELD_PARENT_COMMENT_ID]),
    ParentCommentPushData = get_comment_push_data(ParentCommentId, PostId),
    [CommentPublisherUid | ParentCommentPushData].


-spec get_post_comments(PostId :: binary()) -> {ok, [comment()]} | {error, any()}.
get_post_comments(PostId) when is_binary(PostId) ->
    {ok, CommentIds} = q(["ZRANGEBYSCORE", post_comments_key(PostId), "-inf", "+inf"]),
    Comments = lists:foldr(
        fun(CommentId, Acc) ->
            case get_comment(CommentId, PostId) of
                {ok, Comment} -> [Comment | Acc];
                {error, _} ->
                    ?WARNING("Unable to get_comment, commentid: ~p, postid: ~p", [CommentId, PostId]),
                    Acc
            end
        end, [], CommentIds),
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

