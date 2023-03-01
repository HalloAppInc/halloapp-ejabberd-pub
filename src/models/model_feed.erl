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
-include("moments.hrl").

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
    check_daily_limit/3,
    index_post_by_user_tags/4,
    get_public_moments/4,
    get_posts_by_time_bucket/6,
    get_posts_by_geo_tag_time_bucket/7,
    split_cursor/1,
    join_cursor/3,
    update_cursor_post_id/2,
    get_global_cursor_index/1,
    get_geotag_cursor_index/1,
    get_fof_cursor_index/1,
    split_cursor_index/1,
    update_cursor_post_index/4,
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
    get_recent_user_posts/1,
    get_user_latest_post/1,
    get_latest_posts/1,
    get_psa_tag_posts/1,
    is_psa_tag_done/1,
    mark_psa_tag_done/1,
    del_psa_tag_done/1,
    get_moment_time_to_send/1,
    set_moment_time_to_send/5,
    overwrite_moment_time_to_send/5, %% dangerous.
    del_moment_time_to_send/1,
    is_moment_tag_done/1,
    mark_moment_tag_done/1,
    del_moment_tag_done/1,
    is_post_owner/2,
    get_post_tag/1,
    add_uid_to_audience/2,
    expire_all_user_posts/2,
    set_notification_id/2,
    get_notification_id/1,
    is_post_expired/1,
    remove_all_user_posts/1,    %% test.
    get_num_posts/1,
    is_post_deleted/1,    %% test.
    is_comment_deleted/2,    %% test.
    remove_user/1,
    store_external_share_post/3,
    delete_external_share_post/1,
    get_external_share_post/1,
    generate_notification_time/1, %% test
    get_all_public_moments/2,
    get_all_posts_by_time_bucket/3,
    get_all_posts_by_geo_tag_time_bucket/4,
    mark_seen_posts/2,
    mark_seen_posts/3,
    get_past_seen_posts/1,
    get_past_seen_posts/2,
    clear_past_seen_posts/1,
    get_moment_info/1,
    get_post_num_seen/1,
    inc_post_num_seen/1,
    prepend_ranked_feed/3,
    append_ranked_feed/3,
    get_ranked_feed/1,
    clear_ranked_feed/1,
    expire_post/1,
    unexpire_post/1
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
-define(FIELD_EXPIRED, <<"exp">>).
-define(FIELD_GROUP_ID, <<"gid">>).
-define(FIELD_PSA_TAG, <<"pst">>).
-define(FIELD_PSA_TAG_DONE, <<"ptd">>).
-define(FIELD_MOMENT_TAG_DONE, <<"mtd">>).
-define(FIELD_NUM_TAKES, <<"nt">>).
-define(FIELD_NOTIFICATION_TIMESTAMP, <<"nts">>).
-define(FIELD_TIME_TAKEN, <<"tt">>).
-define(FIELD_NUM_SELFIE_TAKES, <<"nst">>).
-define(FIELD_NOTIFICATION_ID, <<"nid">>).
-define(FIELD_CONTENT_TYPE, <<"cnt">>).
-define(FIELD_MOMENT_NOTIFICATION_ID, <<"nfi">>).
-define(FIELD_MOMENT_NOTIFICATION_TYPE, <<"nft">>).
-define(FIELD_MOMENT_NOTIFICATION_PROMPT, <<"nfp">>).
-define(FIELD_MOMENT_NOTIFICATION_TIMESTAMP, <<"nts">>).


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
    {NotificationTimestampBin, NumTakesBin, TimeTakenBin, NumSelfieTakesBin, NotificationIdBin, ContentTypeBin} = encode_moment_info(MomentInfo),
    C1 = [["HSET", post_key(PostId),
        ?FIELD_UID, Uid,
        ?FIELD_PAYLOAD, Payload,
        ?FIELD_TAG, encode_post_tag(PostTag),
        ?FIELD_AUDIENCE_TYPE, encode_audience_type(FeedAudienceType),
        ?FIELD_TIMESTAMP_MS, integer_to_binary(TimestampMs),
        ?FIELD_NUM_TAKES, NumTakesBin,
        ?FIELD_NOTIFICATION_TIMESTAMP, NotificationTimestampBin,
        ?FIELD_TIME_TAKEN, TimeTakenBin,
        ?FIELD_NUM_SELFIE_TAKES, NumSelfieTakesBin,
        ?FIELD_NOTIFICATION_ID, NotificationIdBin,
        ?FIELD_CONTENT_TYPE, ContentTypeBin]],
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


check_daily_limit(Uid, _PostId, MomentInfo) ->
    {_NotificationTimestampBin, _NumTakesBin, _TimeTakenBin,
        _NumSelfieTakesBin, NotificationIdBin, _ContentTypeBin} = encode_moment_info(MomentInfo),
    DailyLimitKey = daily_limit_key(Uid, NotificationIdBin),
    [{ok, Count}, {ok, _}] = qp([
            ["INCR", DailyLimitKey],
            ["EXPIRE", DailyLimitKey, ?POST_EXPIRATION]]),
    util:to_integer(Count) =< ?MAX_DAILY_MOMENT_LIMIT.


prepend_ranked_feed(_Uid, [], _MomentScoresMap) -> ok;
prepend_ranked_feed(Uid, RankedMomentIds, MomentScoresMap) ->
    Commands1 = lists:map(fun(MomentId) -> ["LREM", feed_rank_key(Uid), 1, MomentId] end, RankedMomentIds),
    Commands2 = [["LPUSH", feed_rank_key(Uid) | lists:reverse(RankedMomentIds)]],
    Commands3 = lists:flatmap(
        fun(MomentId) ->
            {Score, Explanation} = maps:get(MomentId, MomentScoresMap, {-1, <<"error getting score">>}),
            [
                ["SET", post_score_key(Uid, MomentId), util:to_binary(Score)],
                ["EXPIRE", post_score_key(Uid, MomentId), ?MOMENT_TAG_EXPIRATION],
                ["SET", post_score_explanation_key(Uid, MomentId), Explanation],
                ["EXPIRE", post_score_explanation_key(Uid, MomentId), ?MOMENT_TAG_EXPIRATION]
            ]
        end, RankedMomentIds),
    Commands = Commands1 ++ Commands2 ++ Commands3,
    qmn(Commands),
    ok.


append_ranked_feed(_Uid, [], _MomentScoresMap) -> ok;
append_ranked_feed(Uid, RankedMomentIds, MomentScoresMap) ->
    Commands1 = lists:map(fun(MomentId) -> ["LREM", feed_rank_key(Uid), 1, MomentId] end, RankedMomentIds),
    Commands2 = [["RPUSH", feed_rank_key(Uid) | RankedMomentIds]],
    Commands3 = lists:flatmap(
        fun(MomentId) ->
            {Score, Explanation} = maps:get(MomentId, MomentScoresMap, {-1.0, <<"error getting score">>}),
            case Score =:= -1.0 of
                true ->
                    ?ERROR("Error finding score for momentId: ~p", [MomentId]);
                false -> ok
            end,
            [
                ["SET", post_score_key(Uid, MomentId), util:to_binary(Score)],
                ["EXPIRE", post_score_key(Uid, MomentId), ?MOMENT_TAG_EXPIRATION],
                ["SET", post_score_explanation_key(Uid, MomentId), Explanation],
                ["EXPIRE", post_score_explanation_key(Uid, MomentId), ?MOMENT_TAG_EXPIRATION]
            ]
        end, RankedMomentIds),
    Commands = Commands1 ++ Commands2 ++ Commands3,
    qmn(Commands),
    ok.


get_ranked_feed(Uid) ->
    {ok, RankedMomentIds} = q(["LRANGE", feed_rank_key(Uid), "0", "-1"]),
    Commands = lists:flatmap(
        fun(MomentId) ->
            [["GET", post_score_key(Uid, MomentId)],
            ["GET", post_score_explanation_key(Uid, MomentId)]]
        end, RankedMomentIds),
    MomentScoresMap = case Commands of
        [] -> #{};
        _ ->
            Results = qmn(Commands),
            Results2 = parse_score_and_explanation(Results, []),
            maps:from_list(lists:zip(RankedMomentIds, Results2))
    end,
    {RankedMomentIds, MomentScoresMap}.


clear_ranked_feed(Uid) ->
    q(["DEL", feed_rank_key(Uid)]),
    ok.


parse_score_and_explanation([], Res) ->
    lists:reverse(Res);
parse_score_and_explanation([{ok, Score}, {ok, Exp} | Rest], Res) ->
    parse_score_and_explanation(Rest, [{util_redis:decode_float(Score), Exp} | Res]).


mark_seen_posts(_Uid, []) -> ok;
mark_seen_posts(Uid, PostIds) when is_list(PostIds) ->
    case get_notification_id(Uid) of
        undefined ->
            %% this should never happen.
            ?ERROR("Uid: ~p undefined notification_id", [Uid]),
            ok;
        LatestNotifId ->
            mark_seen_posts(Uid, LatestNotifId, PostIds),
            ok
    end,
    ok;
mark_seen_posts(Uid, PostId) ->
    mark_seen_posts(Uid, [PostId]).


mark_seen_posts(_Uid, _LatestNotifId, []) -> ok;
mark_seen_posts(Uid, LatestNotifId, PostIds) ->
    [{ok, _}, {ok, _}] = qp([
                    ["SADD", seen_posts_key(Uid, LatestNotifId)] ++ PostIds,
                    ["EXPIRE", seen_posts_key(Uid, LatestNotifId), ?MOMENT_TAG_EXPIRATION]]),
    ok.


get_past_seen_posts(Uid) ->
    case get_notification_id(Uid) of
        undefined ->
            %% this should never happen.
            ?ERROR("Uid: ~p undefined notification_id", [Uid]),
            [];
        LatestNotifId ->
            get_past_seen_posts(Uid, LatestNotifId)
    end.


get_past_seen_posts(Uid, LatestNotifId) ->
    {ok, PostIds} = q(["SMEMBERS", seen_posts_key(Uid, LatestNotifId)]),
    PostIds.


clear_past_seen_posts(Uid) ->
    case get_notification_id(Uid) of
        undefined ->
            %% this should never happen.
            ?ERROR("Uid: ~p undefined notification_id", [Uid]);
        LatestNotifId ->
            q(["DEL", seen_posts_key(Uid, LatestNotifId)])
    end,
    ok.


%% Indexes post-id by a specific geotag if the post-tag matches public content.
-spec index_post_by_user_tags(PostId :: binary(), Uid :: uid(), PostTag :: post_tag(), TimestampMs :: integer()) -> ok.
index_post_by_user_tags(PostId, Uid, PostTag, TimestampMs) ->
    try
        %% Index public content - only moments for now.
        %% Ignore posts for now.
        case PostTag =:= public_moment of
            true ->
                %% Index onto time buckets.
                [{ok, _}, {ok, _}] = qp([
                    ["ZADD", time_bucket_key(TimestampMs), TimestampMs, PostId],
                    ["EXPIRE", time_bucket_key(TimestampMs), ?KATCHUP_MOMENT_INDEX_EXPIRATION]]),

                %% We could obtain other user info here like lang-id or cc etc and index by them as well.
                %% Obtain geo tag and index by geotag.
                GeoTag = model_accounts:get_latest_geo_tag(Uid),
                [{ok, _}, {ok, _}] = qp([
                            ["ZADD", geo_tag_time_bucket_key(GeoTag, TimestampMs), TimestampMs, PostId],
                            ["EXPIRE", geo_tag_time_bucket_key(GeoTag, TimestampMs), ?KATCHUP_MOMENT_INDEX_EXPIRATION]]),
                ok;
            false -> ok
        end,
        ok
    catch
        _:_ ->
            ok
    end,
    ok.


get_all_public_moments(GeoTag, TimestampMs) ->
    TimestampHr = floor(TimestampMs / ?HOURS_MS),
    case GeoTag =:= undefined orelse GeoTag =:= <<>> of
        true ->
            get_all_posts_by_time_bucket(TimestampHr, TimestampHr, []);
        false ->
            get_all_posts_by_geo_tag_time_bucket(GeoTag, TimestampHr, TimestampHr, [])
    end.


-spec get_public_moments(GeoTag :: maybe(binary()), TimestampMs :: integer(), Cursor :: maybe(binary()), Limit :: integer()) -> [binary()].
get_public_moments(GeoTag, TimestampMs, Cursor, Limit) ->
    case GeoTag =:= undefined orelse GeoTag =:= <<>> of
        true ->
            case get_global_cursor_index(Cursor) of
                {<<>>, undefined} ->
                    TimestampHr = floor(TimestampMs / ?HOURS_MS),
                    get_posts_by_time_bucket(TimestampHr, TimestampHr, undefined, Limit, Limit, []);
                {CursorPostId, CursorTimestampMs} ->
                    CursorTimestampHr = floor(CursorTimestampMs / ?HOURS_MS),
                    get_posts_by_time_bucket(CursorTimestampHr, CursorTimestampHr, CursorPostId, Limit, Limit, [])
            end;
        false ->
            case get_geotag_cursor_index(Cursor) of
                {<<>>, undefined} ->
                    TimestampHr = floor(TimestampMs / ?HOURS_MS),
                    get_posts_by_geo_tag_time_bucket(GeoTag, TimestampHr, TimestampHr, undefined, Limit, Limit, []);
                {CursorPostId, CursorTimestampMs} ->
                    CursorTimestampHr = floor(CursorTimestampMs / ?HOURS_MS),
                    get_posts_by_geo_tag_time_bucket(GeoTag, CursorTimestampHr, CursorTimestampHr, CursorPostId, Limit, Limit, [])
            end
    end.


-spec get_posts_by_time_bucket(StartTimestampHr :: integer(), CurTimestampHr :: integer(),
        CursorPostId :: maybe(binary()), CurLimit :: integer(), Limit :: integer(), ResultPostIds :: [binary()]) -> [binary()].
get_posts_by_time_bucket(StartTimestampHr, CurTimestampHr,
        _CursorPostId, _CurLimit, _Limit, ResultPostIds)
        when StartTimestampHr - CurTimestampHr >= ?KATCHUP_MOMENT_EXPIRATION_HRS ->
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
        when StartTimestampHr - CurTimestampHr >= ?KATCHUP_MOMENT_EXPIRATION_HRS ->
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


-spec get_all_posts_by_time_bucket(StartTimestampHr :: integer(), CurTimestampHr :: integer(),
        ResultPostIds :: [binary()]) -> [binary()].
get_all_posts_by_time_bucket(StartTimestampHr, CurTimestampHr, ResultPostIds)
        when StartTimestampHr - CurTimestampHr >= ?KATCHUP_MOMENT_EXPIRATION_HRS ->
    ResultPostIds;
get_all_posts_by_time_bucket(StartTimestampHr, CurTimestampHr, ResultPostIds) ->
    {ok, PostIds} = q(["ZREVRANGEBYSCORE", time_bucket_key_hr(CurTimestampHr), "+inf", "-inf"]),
    FinalResultPostIds = ResultPostIds ++ PostIds,
    get_all_posts_by_time_bucket(StartTimestampHr, CurTimestampHr-1, FinalResultPostIds).



-spec get_all_posts_by_geo_tag_time_bucket(GeoTag :: binary(), StartTimestampHr :: integer(), CurTimestampHr :: integer(),
        ResultPostIds :: [binary()]) -> [binary()].
get_all_posts_by_geo_tag_time_bucket(_GeoTag, StartTimestampHr, CurTimestampHr, ResultPostIds)
        when StartTimestampHr - CurTimestampHr >= ?KATCHUP_MOMENT_EXPIRATION_HRS ->
    ResultPostIds;
get_all_posts_by_geo_tag_time_bucket(GeoTag, StartTimestampHr, CurTimestampHr, ResultPostIds) ->
    {ok, PostIds} = q(["ZREVRANGEBYSCORE", geo_tag_time_bucket_key_hr(GeoTag, CurTimestampHr), "+inf", "-inf"]),
    FinalResultPostIds = ResultPostIds ++ PostIds,
    get_all_posts_by_geo_tag_time_bucket(GeoTag, StartTimestampHr, CurTimestampHr-1, FinalResultPostIds).


-spec split_cursor(Cursor :: binary()) -> {maybe(binary()), maybe(binary()), maybe(integer())}.
split_cursor(undefined) -> {<<>>, <<>>, undefined};
split_cursor(<<>>) -> {<<>>, <<>>, undefined};
split_cursor(Cursor) ->
    try
        [CursorPostIndex, CursorPostId, RequestTimestampMsBin] = re:split(Cursor, "::"),
        {CursorPostIndex, CursorPostId, util_redis:decode_int(RequestTimestampMsBin)}
    catch
        _:_ ->
            ?ERROR("Failed to split cursor: ~p", [Cursor]),
            {<<>>, <<>>, undefined}
    end.


-spec join_cursor(CursorPostIndex :: binary(), CursorPostId :: binary(), RequestTimestampMs :: integer()) -> binary().
join_cursor(CursorPostIndex, CursorPostId, RequestTimestampMs) ->
    RequestTimestampMsBin = util_redis:encode_int(RequestTimestampMs),
    <<CursorPostIndex/binary, "::", CursorPostId/binary, "::", RequestTimestampMsBin/binary>>.


update_cursor_post_id(Cursor, PostId) ->
    {CursorPostIndex, _CursorPostId, RequestTimestampMs} = split_cursor(Cursor),
    join_cursor(CursorPostIndex, PostId, RequestTimestampMs).


get_global_cursor_index(Cursor) ->
    {CursorPostIndex, _CursorPostId, _RequestTimestampMs} = split_cursor(Cursor),
    {
        _GeoTagCursorPostId, _GeoTagCursorTimestampMs,
        _FofCursorUidScoreBin, _FofCursorTimestampMs,
        GlobalCursorPostId, GlobalCursorTimestampMs
    } = split_cursor_index(CursorPostIndex),
    {GlobalCursorPostId, GlobalCursorTimestampMs}.


get_geotag_cursor_index(Cursor) ->
    {CursorPostIndex, _CursorPostId, _RequestTimestampMs} = split_cursor(Cursor),
    {
        GeoTagCursorPostId, GeoTagCursorTimestampMs,
        _FofCursorUidScoreBin, _FofCursorTimestampMs,
        _GlobalCursorPostId, _GlobalCursorTimestampMs
    } = split_cursor_index(CursorPostIndex),
    {GeoTagCursorPostId, GeoTagCursorTimestampMs}.


get_fof_cursor_index(Cursor) ->
    {CursorPostIndex, _CursorPostId, _RequestTimestampMs} = split_cursor(Cursor),
    {
        _GeoTagCursorPostId, _GeoTagCursorTimestampMs,
        FofCursorUidScoreBin, FofCursorTimestampMs,
        _GlobalCursorPostId, _GlobalCursorTimestampMs
    } = split_cursor_index(CursorPostIndex),
    {FofCursorUidScoreBin, FofCursorTimestampMs}.


split_cursor_index(CursorPostIndex) ->
    try
        [GeoTagCursorIndex, FofCursorIndex, GlobalCursorIndex] = case CursorPostIndex of
            <<>> -> [<<>>, <<>>, <<>>];
            _ -> re:split(CursorPostIndex, "&")
        end,
        [GeoTagCursorPostId, GeoTagCursorTimestampMsBin] = case GeoTagCursorIndex of
            <<>> -> [<<>>, <<>>];
            _ -> re:split(GeoTagCursorIndex, "@")
        end,
        [FofCursorUidScoreBin, FofCursorTimestampMsBin] = case FofCursorIndex of
            <<>> -> [<<>>, <<>>];
            _ -> re:split(FofCursorIndex, "@")
        end,
        [GlobalCursorPostId, GlobalCursorTimestampMsBin] = case GlobalCursorIndex of
            <<>> -> [<<>>, <<>>];
            _ -> re:split(GlobalCursorIndex, "@")
        end,
        {
        GeoTagCursorPostId, util_redis:decode_int(GeoTagCursorTimestampMsBin),
        FofCursorUidScoreBin, util_redis:decode_int(FofCursorTimestampMsBin),
        GlobalCursorPostId, util_redis:decode_int(GlobalCursorTimestampMsBin)
        }
    catch
        _:_ ->
            ?ERROR("Failed to split cursor: ~p", [CursorPostIndex]),
            {<<>>, undefined, <<>>, undefined, <<>>, undefined}
    end.


update_cursor_post_index(Cursor, LastGeoTaggedMoment, NewFofScoreCursorBin, LastGlobalMoment) ->
    try
        {GeoTagPostId, GeoTagTimestampMs} = case LastGeoTaggedMoment of
            undefined -> get_geotag_cursor_index(Cursor);
            _ -> {LastGeoTaggedMoment#post.id, LastGeoTaggedMoment#post.ts_ms}
        end,
        GeoTagTimestampMsBin = util_redis:encode_int(GeoTagTimestampMs),
        {GlobalPostId, GlobalTimestampMs} = case LastGlobalMoment of
            undefined -> get_global_cursor_index(Cursor);
            _ -> {LastGlobalMoment#post.id, LastGlobalMoment#post.ts_ms}
        end,
        {NewFofScoreCursorBin, NewFofCursorTimestampMs} = case NewFofScoreCursorBin of
            <<>> -> {<<>>, undefined};
            undefined -> get_fof_cursor_index(Cursor);
            _ -> {NewFofScoreCursorBin, undefined}
        end,
        NewFofCursorTimestampMsBin = util_redis:encode_int(NewFofCursorTimestampMs),
        GlobalTimestampMsBin = util_redis:encode_int(GlobalTimestampMs),
        {_, CursorPostId, RequestTimestampMs} = split_cursor(Cursor),
        CursorPostIndex = <<GeoTagPostId/binary, "@", GeoTagTimestampMsBin/binary, "&",
            NewFofScoreCursorBin/binary, "@", NewFofCursorTimestampMsBin/binary, "&",
            GlobalPostId/binary, "@", GlobalTimestampMsBin/binary>>,
        join_cursor(CursorPostIndex, CursorPostId, RequestTimestampMs)
    catch
        Error:Reason ->
            ?ERROR("Failed to update cursor: ~p, Error: ~p, Reason: ~p", [Cursor, Error, Reason]),
            Cursor
    end.


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


-spec expire_post(PostId :: binary()) -> ok | {error, any()}.
expire_post(PostId) ->
    %% Set expired field to be 1.
    {ok, _} = q(["HSET", post_key(PostId), ?FIELD_EXPIRED, 1]),
    ok.


unexpire_post(PostId) ->
    %% Set expired field to be 0.
    {ok, _} = q(["HSET", post_key(PostId), ?FIELD_EXPIRED, 0]),
    ok.


-spec is_post_deleted(PostId :: binary()) -> boolean().
is_post_deleted(PostId) ->
    {ok, Res} = q(["HGET", post_key(PostId), ?FIELD_DELETED]),
    util_redis:decode_boolean(Res, false).


is_post_expired(PostId) ->
    {ok, Res} = q(["HGET", post_key(PostId), ?FIELD_EXPIRED]),
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


-spec expire_all_user_posts(Uid :: uid(), NotificationId :: integer()) -> ok.
expire_all_user_posts(Uid, NotificationId) ->
    {ok, PostIds} = q(["ZRANGE", reverse_post_key(Uid), "-inf", "+inf", "BYSCORE"]),
    case get_posts(PostIds) of
        [] -> ok;
        Posts ->
            ExpirePostIds = lists:filtermap(
                fun(Post) ->
                    case Post#post.moment_info of
                        undefined ->
                            ?ERROR("PostId: ~p moment_info is undefined", [Post#post.id]),
                            {true, Post#post.id};
                        MomentInfo ->
                            case MomentInfo#pb_moment_info.notification_id < NotificationId of
                                true -> {true, Post#post.id};
                                false -> false
                            end
                    end
                end, Posts),
            lists:foreach(fun(PostId) -> ok = expire_post(PostId) end, ExpirePostIds)
    end,
    cleanup_reverse_index(Uid),
    ok.


-spec set_notification_id(Uid :: uid(), NotificationId :: integer()) -> ok.
set_notification_id(Uid, NotificationId) ->
    {ok, _} = q(["SET", notification_id_key(Uid), util:to_binary(NotificationId)]),
    ok.


-spec get_notification_id(Uid :: uid()) -> maybe(integer()).
get_notification_id(Uid) ->
    {ok, NotificationId} = q(["GET", notification_id_key(Uid)]),
    util_redis:decode_int(NotificationId).


-spec remove_all_user_posts(Uid :: uid()) -> ok.
remove_all_user_posts(Uid) ->
    {ok, PostIds} = q(["ZRANGEBYSCORE", reverse_post_key(Uid), "-inf", "+inf"]),
    lists:foreach(fun(PostId) -> ok = delete_post(PostId, Uid) end, PostIds),
    {ok, _} = q(["DEL", reverse_post_key(Uid)]),
    ok.

%% Does not count deleted posts
-spec get_num_posts(Uid :: uid()) -> non_neg_integer().
get_num_posts(Uid) ->
    {ok, PostIds} = q(["ZRANGE", reverse_post_key(Uid), "-inf", "+inf", "BYSCORE"]),
    length(lists:filter(
        fun(PostId) ->
            not is_post_deleted(PostId)
        end,
        PostIds
    )).


-spec get_post(PostId :: binary()) -> {ok, post()} | {error, any()}.
get_post(PostId) ->
    [
        {ok, [Uid, Payload, PostTag, AudienceType, TimestampMs, Gid, PSATag, IsDeletedBin,
            NotificationTimestampBin, NumTakesBin, TimeTakenBin, NumSelfieTakesBin, NotificationIdBin,
            ContentTypeBin, IsExpiredBin]},
        {ok, AudienceList}] = qp([
            ["HMGET", post_key(PostId),
                ?FIELD_UID, ?FIELD_PAYLOAD, ?FIELD_TAG, ?FIELD_AUDIENCE_TYPE, ?FIELD_TIMESTAMP_MS,
                ?FIELD_GROUP_ID, ?FIELD_PSA_TAG, ?FIELD_DELETED, ?FIELD_NOTIFICATION_TIMESTAMP,
                ?FIELD_NUM_TAKES, ?FIELD_TIME_TAKEN, ?FIELD_NUM_SELFIE_TAKES, ?FIELD_NOTIFICATION_ID,
                ?FIELD_CONTENT_TYPE, ?FIELD_EXPIRED],
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
                moment_info = decode_moment_info(NotificationTimestampBin, NumTakesBin, TimeTakenBin,
                    NumSelfieTakesBin, NotificationIdBin, ContentTypeBin),
                expired = util_redis:decode_boolean(IsExpiredBin, false)
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
                ?FIELD_NUM_TAKES, ?FIELD_TIME_TAKEN, ?FIELD_NUM_SELFIE_TAKES, ?FIELD_NOTIFICATION_ID,
                ?FIELD_CONTENT_TYPE, ?FIELD_EXPIRED],
        ["SMEMBERS", post_audience_key(PostId)],
        ["HMGET", comment_key(CommentId, PostId), ?FIELD_PUBLISHER_UID, ?FIELD_PARENT_COMMENT_ID, ?FIELD_COMMENT_TYPE,
                ?FIELD_PAYLOAD, ?FIELD_TIMESTAMP_MS, ?FIELD_DELETED]]),
    [PostUid, PostPayload, PostTag, AudienceType, PostTsMs, IsPostDeletedBin,
        NotificationTimestampBin, NumTakesBin, TimeTakenBin, NumSelfieTakesBin, NotificationIdBin, ContentTypeBin, IsExpiredBin] = Res1,
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
                moment_info = decode_moment_info(NotificationTimestampBin, NumTakesBin, TimeTakenBin,
                    NumSelfieTakesBin, NotificationIdBin, ContentTypeBin),
                expired = util_redis:decode_boolean(IsExpiredBin, false)
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


-spec get_moment_time_to_send(DateTimeSecs :: integer()) -> {integer(), integer(), moment_type(), binary()}.
get_moment_time_to_send(DateTimeSecs) ->
    Date = util:get_date(DateTimeSecs),
    [{ok, Payload1}, {ok, Payload2}, {ok, Payload3}, {ok, Payload4}] =
        qp([["GET", moment_time_to_send_key(Date)],
            ["HGET", moment_time_to_send_key2(Date), ?FIELD_MOMENT_NOTIFICATION_ID],
            ["HGET", moment_time_to_send_key2(Date), ?FIELD_MOMENT_NOTIFICATION_TYPE],
            ["HGET", moment_time_to_send_key2(Date), ?FIELD_MOMENT_NOTIFICATION_PROMPT]]),
    case Payload1 of
        undefined ->
            ?INFO("Generating moment time to send now, Tag: ~p, DateTimeSecs: ~p", [Date, DateTimeSecs]),
            {FullDate, {_,_,_}} = calendar:system_time_to_universal_time(DateTimeSecs, second),
            DayOfWeek = calendar:day_of_the_week(FullDate),
            %% live camera on Fri, Sat, Sun, text_post on one of Mon, Tue, Wed, Thu
            case DayOfWeek >= 5 andalso DayOfWeek =< 7 of
                true ->
                    set_moment_time(live_camera, DateTimeSecs);
                false ->
                    TextPostDay = rand:uniform(4),
                    lists:foreach(fun(WeekDay) ->
                        PostType = case TextPostDay =:= WeekDay of
                            true -> text_post;
                            false -> live_camera
                        end,
                        ?INFO("Processing: ~p, PostType: ~p", [WeekDay, PostType]),
                        WeekDayTimeSecs = DateTimeSecs + ((WeekDay - DayOfWeek) * ?DAYS),
                        set_moment_time(PostType, WeekDayTimeSecs)
                    end, lists:seq(DayOfWeek, 4))
              end,
              get_moment_time_to_send(DateTimeSecs);
        _ ->
            case {Payload2, Payload3, Payload4} of
                {_, _, undefined} ->
                    {util:to_integer_zero(Payload1), util:to_integer_zero(Payload2), util_moments:to_moment_type(Payload3), <<"WYD?">>};
                {_, _, _} ->
                    {util:to_integer_zero(Payload1), util:to_integer_zero(Payload2), util_moments:to_moment_type(Payload3), Payload4}
            end
    end.

set_moment_time(PostType, WeekDayTimeSecs) ->
    Prompt = mod_prompts:get_prompt(PostType),
    Time = generate_notification_time(WeekDayTimeSecs),
    WeekDate = util:get_date(WeekDayTimeSecs),
    set_moment_time_to_send(Time, WeekDayTimeSecs, PostType, Prompt, WeekDate).

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
 
-spec set_moment_time_to_send(Time :: integer(), Id :: integer(), Type :: moment_type(), Prompt :: binary(), Tag :: integer()) -> boolean().
set_moment_time_to_send(Time, Id, Type, Prompt, Tag) ->
    {ok, Payload} = q(["SET", moment_time_to_send_key(Tag), util:to_binary(Time),
                      "EX", ?MOMENT_TAG_EXPIRATION, "NX"]),
    case Payload =:= <<"OK">> of
        true ->
            qp([["HSET", moment_time_to_send_key2(Tag), ?FIELD_MOMENT_NOTIFICATION_ID, util:to_binary(Id)],
                ["HSET", moment_time_to_send_key2(Tag), ?FIELD_MOMENT_NOTIFICATION_TYPE, util_moments:moment_type_to_bin(Type)],
                ["HSET", moment_time_to_send_key2(Tag), ?FIELD_MOMENT_NOTIFICATION_PROMPT, Prompt],
                ["EXPIRE", moment_time_to_send_key2(Tag), ?MOMENT_TAG_EXPIRATION]]),
            % Store the type, timestamp and prompt by id.
            qp([["HSET", moment_info_key(Id), ?FIELD_MOMENT_NOTIFICATION_TYPE, util_moments:moment_type_to_bin(Type)],
                ["HSET", moment_info_key(Id), ?FIELD_MOMENT_NOTIFICATION_PROMPT, Prompt],
                ["EXPIRE", moment_info_key(Id), ?MOMENT_TAG_EXPIRATION]]),
            true;
        false -> false
    end.


overwrite_moment_time_to_send(Time, Id, Type, Prompt, Tag) ->
    q(["SET", moment_time_to_send_key(Tag), util:to_binary(Time), "EX", ?MOMENT_TAG_EXPIRATION]),
    qp([["HSET", moment_time_to_send_key2(Tag), ?FIELD_MOMENT_NOTIFICATION_ID, util:to_binary(Id)],
        ["HSET", moment_time_to_send_key2(Tag), ?FIELD_MOMENT_NOTIFICATION_TYPE, util_moments:moment_type_to_bin(Type)],
        ["HSET", moment_time_to_send_key2(Tag), ?FIELD_MOMENT_NOTIFICATION_PROMPT, Prompt],
        ["EXPIRE", moment_time_to_send_key2(Tag), ?MOMENT_TAG_EXPIRATION]]),
    % Store the type, timestamp and prompt by id.
    qp([["HSET", moment_info_key(Id), ?FIELD_MOMENT_NOTIFICATION_TYPE, util_moments:moment_type_to_bin(Type)],
        ["HSET", moment_info_key(Id), ?FIELD_MOMENT_NOTIFICATION_PROMPT, Prompt],
        ["EXPIRE", moment_info_key(Id), ?MOMENT_TAG_EXPIRATION]]),
    ok.


-spec get_post_num_seen(PostId :: binary()) -> {ok, integer()} | {error, any()}.
get_post_num_seen(PostId) ->
    {ok, Res} = q(["GET", num_seen_key(PostId)]),
    {ok, util:to_integer_zero(Res)}.

-spec inc_post_num_seen(PostId :: binary()) -> ok | {error, any()}.
inc_post_num_seen(PostId) ->
    qp([
        ["INCR", num_seen_key(PostId)],
        ["EXPIRE", num_seen_key(PostId), ?POST_EXPIRATION]
    ]).

-spec get_moment_info(NotificationId :: integer()) -> {maybe(integer()), atom(), binary()}.
get_moment_info(NotificationId) ->
    [{ok, Type}, {ok, Prompt}, {ok, NotifTs}] = qp([
        ["HGET", moment_info_key(NotificationId), ?FIELD_MOMENT_NOTIFICATION_TYPE],
        ["HGET", moment_info_key(NotificationId), ?FIELD_MOMENT_NOTIFICATION_PROMPT],
        ["HGET", moment_info_key(NotificationId), ?FIELD_MOMENT_NOTIFICATION_TIMESTAMP]]),
    {util_redis:decode_ts(NotifTs), util_moments:to_moment_type(Type), Prompt}.


-spec del_moment_time_to_send(DateTimeSecs :: integer()) -> ok.
del_moment_time_to_send(DateTimeSecs) ->
    Date = util:get_date(DateTimeSecs),
    util_redis:verify_ok(qp([["DEL", moment_time_to_send_key(Date)], ["DEL", moment_time_to_send_key2(Date)]])).

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


%% Returns 3 most recent posts + today to display on other user's profile
-spec get_recent_user_posts(Uid :: uid()) -> [post()].
get_recent_user_posts(Uid) ->
    {ok, AllPostIds} = q(["ZRANGE", reverse_post_key(Uid), "-inf", "+inf", "BYSCORE"]),
    Posts = lists:reverse(get_posts(AllPostIds)),  % list is in order of most to least recent
    %% If two posts have same moment notification ts, remove older one
    {FilteredPosts, _} = lists:mapfoldl(
        fun (#post{moment_info = undefined} = Post, NotifTsSet) ->
                ?ERROR("Invalid Post: ~p", [Post]),
                {undefined, NotifTsSet};
            (#post{moment_info = #pb_moment_info{notification_timestamp = NotifTs}} = Post, NotifTsSet) ->
                case sets:is_element(NotifTs, NotifTsSet) of
                    true -> {undefined, NotifTsSet};
                    false -> {Post, sets:add_element(NotifTs, NotifTsSet)}
                end
        end,
        sets:new(),
        Posts),
    FinalPosts = lists:filter(fun(P) -> P =/= undefined end, FilteredPosts),
    case lists:partition(fun(#post{expired = Expired}) -> Expired =:= false end, FinalPosts) of
        {[], FinalPosts} ->
            %% No post for today
            lists:sublist(FinalPosts, 3);
        {TodayPost, _OtherPosts} when length(TodayPost) =:= 1 ->
            %% Post for today
            lists:sublist(FinalPosts, 4);
        Res ->
            ?ERROR("Unexpected recent post history for ~s: ~p | partitioned: ~p", [Uid, FinalPosts, Res]),
            lists:sublist(FinalPosts, 4)
    end.


-spec get_user_latest_post(Uid :: uid()) -> maybe(post()).
get_user_latest_post(Uid) ->
    {ok, LatestPostIds} = q(["ZRANGE", reverse_post_key(Uid), "0", "0", "REV"]),
    LatestPost = case LatestPostIds of
        [] -> undefined;
        [LatestPostId] ->
            case get_post(LatestPostId) of
                {ok, Post} -> Post;
                {error, missing} -> undefined
            end
    end,
    LatestPost.


-spec get_latest_posts(Uids :: [uid()]) -> list(post()).
get_latest_posts(Uids) ->
    Commands = lists:map(
        fun(Uid) ->
            ["ZRANGE", reverse_post_key(Uid), "0", "0", "REV"]
        end, Uids),
    PostIds = lists:foldl(fun ({ok, Res}, Acc) -> Acc ++ Res end, [], qmn(Commands)),
    get_posts(PostIds).


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


encode_moment_info(undefined) -> {<<>>, <<>>, <<>>, <<>>, <<>>, <<>>};
encode_moment_info(#pb_moment_info{notification_timestamp = NotificationTimestamp, num_takes = NumTakes,
        time_taken = TimeTaken, num_selfie_takes = NumSelfieTakes, notification_id = NotificationId,
        content_type = ContentType}) ->
    NotificationTimestampBin = util_redis:encode_int(NotificationTimestamp),
    NumTakesBin = util_redis:encode_int(NumTakes),
    TimeTakenBin = util_redis:encode_int(TimeTaken),
    NumSelfieTakesBin = util_redis:encode_int(NumSelfieTakes),
    NotificationIdBin = util_redis:encode_int(NotificationId),
    ContentTypeBin = util:to_binary(ContentType),
    {NotificationTimestampBin, NumTakesBin, TimeTakenBin, NumSelfieTakesBin, NotificationIdBin, ContentTypeBin}.


decode_moment_info(NotificationTimestampBin, NumTakesBin, TimeTakenBin, NumSelfieTakesBin, NotificationIdBin, ContentTypeBin) ->
    NotifTs = case util_redis:decode_int(NotificationTimestampBin) of
        undefined -> 0;
        Val -> Val
    end,
    NumTakes = case util_redis:decode_int(NumTakesBin) of
        undefined -> 0;
        Val2 -> Val2
    end,
    TimeTaken = case util_redis:decode_int(TimeTakenBin) of
        undefined -> 0;
        Val3 -> Val3
    end,
    NumSelfieTakes = case util_redis:decode_int(NumSelfieTakesBin) of
        undefined -> 0;
        Val4 -> Val4
    end,
    NotificationId = case util_redis:decode_int(NotificationIdBin) of
        undefined -> 0;
        Val5 -> Val5
    end,
    ContentType = case util:to_atom(ContentTypeBin) of
        undefined -> image;
        Val6 -> Val6
    end,
    case NotifTs =:= 0 andalso NotificationId =:= 0 of
        true -> undefined;
        false ->
            #pb_moment_info{
                notification_timestamp = NotifTs,
                num_takes = NumTakes,
                time_taken = TimeTaken,
                num_selfie_takes = NumSelfieTakes,
                notification_id = NotificationId,
                content_type = ContentType
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


-spec moment_info_key(NotificationId :: integer()) -> binary().
moment_info_key(NotificationId) ->
    NotificationIdBin = util:to_binary(NotificationId),
    <<?MOMENT_INFO_KEY/binary, "{", NotificationIdBin/binary, "}">>.


-spec notification_id_key(Uid :: uid()) -> binary().
notification_id_key(Uid) ->
    <<?NOTIFICATION_ID_KEY/binary, "{", Uid/binary, "}">>.


-spec reverse_group_post_key(Gid :: uid()) -> binary().
reverse_group_post_key(Gid) ->
    <<?REVERSE_GROUP_POST_KEY/binary, "{", Gid/binary, "}">>.


-spec daily_limit_key(Uid :: binary(), NotificationTimestampBin :: binary()) -> binary().
daily_limit_key(Uid, NotificationTimestampBin) ->
    <<?DAILY_LIMIT_KEY/binary, "{", Uid/binary, "}:", NotificationTimestampBin/binary>>.


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


-spec seen_posts_key(Uid :: binary(), LatestNotifId :: integer()) -> binary().
seen_posts_key(Uid, LatestNotifId) ->
    LatestNotifIdBin = util:to_binary(LatestNotifId),
    <<?SEEN_POSTS_KEY/binary, "{", Uid/binary, "}:", LatestNotifIdBin/binary>>.


num_seen_key(PostId) ->
    <<?POST_NUM_SEEN_KEY/binary, "{", PostId/binary, "}">>.


feed_rank_key(Uid) ->
    <<?FEED_RANK_KEY/binary, "{", Uid/binary, "}">>.


post_score_key(Uid, PostId) ->
    <<?POST_SCORE_KEY/binary, "{", Uid/binary, "}:", PostId/binary>>.


post_score_explanation_key(Uid, PostId) ->
    <<?POST_SCORE_EXPLANATION_KEY/binary, "{", Uid/binary, "}:", PostId/binary>>.

