%%%-------------------------------------------------------------------
%%% @author josh
%%% @copyright (C) 2022, HalloApp, Inc.
%%% @doc
%%%
%%% @end
%%%-------------------------------------------------------------------
-module(model_follow).
-author("josh").

-include("logger.hrl").
-include("redis_keys.hrl").
-include("ha_types.hrl").

%% For testing
-ifdef(TEST).
-export([
    follow/3
]).
-endif.

%% API
-export([
    follow/2,
    unfollow/2,
    is_following/2,
    is_follower/2,
    get_following/3,
    get_following/2,
    get_random_following/2,
    get_all_following/1,
    get_following_count/1,
    get_followers/3,
    get_all_followers/1,
    get_followers_count/1,
    remove_all_following/1,
    remove_all_followers/1,
    block/2,
    unblock/2,
    is_blocked/2,
    is_blocked_by/2,
    is_blocked_any/2,
    get_blocked_uids/1,
    get_blocked_by_uids/1,
    remove_all_blocked_uids/1,
    remove_all_blocked_by_uids/1,
    follower_key/1,
    following_key/1,
    blocked_key/1,
    update_fof/2,
    get_all_fof/1,
    get_fof/3,
    get_all_fof_list/1,
    get_fof_list/3,
    update_contact_suggestions/2,
    update_fof_suggestions/2,
    get_contact_suggestions/1,
    get_fof_suggestions/1
]).

%%====================================================================
%% API
%%====================================================================

update_contact_suggestions(_Uid, []) -> ok;
update_contact_suggestions(Uid, ContactSuggestionsList) ->
    [{ok, _}, {ok, _}] = qp([
        ["DEL", contact_suggestions_key(Uid)],
        ["RPUSH", contact_suggestions_key(Uid) | ContactSuggestionsList]]),
    ok.


update_fof_suggestions(_Uid, []) -> ok;
update_fof_suggestions(Uid, FoFSuggestionsList) ->
    [{ok, _}, {ok, _}] = qp([
        ["DEL", fof_suggestions_key(Uid)],
        ["RPUSH", fof_suggestions_key(Uid) | FoFSuggestionsList]]),
    ok.


get_contact_suggestions(Uid) ->
    {ok, ContactSuggestionsList} = q(["LRANGE", contact_suggestions_key(Uid), "0", "-1"]),
    ContactSuggestionsList.


get_fof_suggestions(Uid) ->
    {ok, FoFSuggestionsList} = q(["LRANGE", fof_suggestions_key(Uid), "0", "-1"]),
    FoFSuggestionsList.


update_fof(Uid, FofWithScores) ->
    case util_redis:flatten_proplist(maps:to_list(FofWithScores)) of
        [] -> ok;
        RevFofScoresList ->
            [{ok, _}, {ok, _Res}] = qp([
                ["DEL", fof_index_key(Uid)],
                ["ZADD", fof_index_key(Uid) | lists:reverse(RevFofScoresList)]]),
            ok
    end.


-spec get_all_fof(Uid :: uid()) -> map().
get_all_fof(Uid) ->
    {Res, _} = get_fof(Uid, <<"+inf">>, -1),
    Res.

-spec get_all_fof_list(Uid :: uid()) -> list({uid(), integer()}).
get_all_fof_list(Uid) ->
    {Res, _} = get_fof_list(Uid, <<"+inf">>, -1),
    Res.


-spec get_fof(Uid :: uid(), Cursor :: binary(), Limit :: integer()) -> {map(), binary()}.
get_fof(Uid, <<>>, Limit) -> get_fof(Uid, <<"+inf">>, Limit);
get_fof(Uid, Cursor, Limit) ->
    {Res, NewCursor} = get_fof_list(Uid, Cursor, Limit),
    {maps:from_list(Res), NewCursor}.


-spec get_fof_list(Uid :: uid(), Cursor :: binary(), Limit :: integer()) -> {list({uid(), integer()}), binary()}.
get_fof_list(Uid, <<>>, Limit) -> get_fof_list(Uid, <<"+inf">>, Limit);
get_fof_list(Uid, Cursor, Limit) ->
    %% Use Limit and fetch some fof.
    {ok, RawRes} = q(["ZRANGE", fof_index_key(Uid), <<"(", Cursor/binary>>, "-inf", "BYSCORE", "REV", "WITHSCORES", "LIMIT", 0, Limit]),
    Res = util_redis:parse_zrange_with_scores(RawRes),
    Res2 = lists:map(fun({FofUid, ScoreBin}) -> {FofUid, util:to_integer(ScoreBin)} end, Res),
    case length(Res) < Limit orelse length(Res) =:= 0 of
        true -> {Res2, <<"">>};
        false -> {Res2, element(2, lists:last(Res))}
    end.


%% Uid follows Ouid
-spec follow(Uid :: uid(), Ouid :: uid()) -> ok.
follow(Uid, Ouid) ->
    follow(Uid, Ouid, util:now_ms()).
follow(Uid, Ouid, TsMs) ->
    [{ok, _}, {ok, _}] = qmn([
        ["ZADD", following_key(Uid), TsMs, Ouid],
        ["ZADD", follower_key(Ouid), TsMs, Uid]
    ]),
    ok.

%% Uid unfollows Ouid
-spec unfollow(Uid :: uid(), Ouid :: uid()) -> ok.
unfollow(Uid, Ouid) ->
    [{ok, _}, {ok, _}] = qmn([
        ["ZREM", following_key(Uid), Ouid],
        ["ZREM", follower_key(Ouid), Uid]
    ]),
    ok.


%% Uid is following Ouid ?
-spec is_following(Uid :: uid(), Ouid :: uid()) -> boolean().
is_following(Uid, Ouid) ->
    {ok, Res} = q(["ZSCORE", following_key(Uid), Ouid]),
    case util_redis:decode_int(Res) of
        undefined -> false;
        _ -> true
    end.


%% Uid is a follower of Ouid ?
-spec is_follower(Uid :: uid(), Ouid :: uid()) -> boolean().
is_follower(Uid, Ouid) ->
    {ok, Res} = q(["ZSCORE", follower_key(Uid), Ouid]),
    case util_redis:decode_int(Res) of
        undefined -> false;
        _ -> true
    end.


%% Get everyone that Uid is following (paginated)
-spec get_following(Uid :: uid(), Cursor :: binary(), Limit :: pos_integer()) ->
    {Uids :: list(uid()), NewCursor :: binary()}.
get_following(Uid, Cursor, Limit) ->
    get_all(following_key(Uid), Cursor, Limit).


-spec get_following(Uids :: [uid()] | uid(), Limit :: integer()) -> [uid()].
get_following(Uids, Limit) when is_list(Uids) ->
    Commands = lists:map(
        fun(Uid) ->
            ["ZRANGE", following_key(Uid), "+inf", "-inf", "BYSCORE", "REV", "LIMIT", 0, Limit]
        end, Uids),
    Res = qmn(Commands),
    Result = lists:flatmap(fun({ok, Followers}) -> Followers end, Res),
    Result;
get_following(Uid, Limit) ->
    get_following([Uid], Limit).


-spec get_random_following(Uids :: [uid()] | uid(), Limit :: integer()) -> [uid()].
get_random_following(Uids, Limit) when is_list(Uids) ->
    Commands = lists:map(
        fun(Uid) ->
            ["ZRANDMEMBER", following_key(Uid), Limit]
        end, Uids),
    Res = qmn(Commands),
    Result = lists:flatmap(fun({ok, Followers}) -> Followers end, Res),
    Result;
get_random_following(Uid, Limit) ->
    get_random_following([Uid], Limit).


%% Get everyone that Uid/Uids is/are following (not paginated)
-spec get_all_following(Uids :: [uid()] | uid()) -> [uid()].
get_all_following(Uids) when is_list(Uids) ->
    get_following(Uids, -1);
get_all_following(Uid) ->
    get_all_following([Uid]).


-spec get_following_count(Uid :: uid()) -> integer().
get_following_count(Uid) ->
    get_count_internal(following_key(Uid)).


%% Get everyone following Uid (paginated)
-spec get_followers(Uid :: uid(), Cursor :: binary(), Limit :: pos_integer()) ->
    {Uids :: list(uid()), NewCursor :: binary()}.
get_followers(Uid, Cursor, Limit) ->
    get_all(follower_key(Uid), Cursor, Limit).


%% Get everyone following Uid (not paginated)
-spec get_all_followers(Uid :: uid()) -> list(uid()).
get_all_followers(Uid) ->
    get_all_internal(follower_key(Uid)).

-spec get_followers_count(Uid :: list(uid()) | uid()) -> list(integer()) | integer().
get_followers_count(Uids) when is_list(Uids) ->
    Commands = lists:map(
        fun(Uid) ->
            ["ZCARD", follower_key(Uid)]
        end, Uids),
    lists:map(
        fun({ok, CountBin}) ->
            util:to_integer(CountBin)
        end, qmn(Commands));
get_followers_count(Uid) ->
    get_count_internal(follower_key(Uid)).

-spec remove_all_following(Uid :: uid()) -> {ok, list(uid())}.
remove_all_following(Uid) ->
    Following = get_all_following(Uid),
    Commands = lists:map(
        fun(Ouid) ->
            ["ZREM", follower_key(Ouid), Uid]
        end,
        Following
    ),
    {ok, _} = q(["DEL", following_key(Uid)]),
    _Result = qmn(Commands),
    {ok, Following}.


-spec remove_all_followers(Uid :: uid()) -> {ok, list(uid())}.
remove_all_followers(Uid) ->
    Followers = get_all_followers(Uid),
    Commands = lists:map(
        fun(Ouid) ->
            ["ZREM", following_key(Ouid), Uid]
        end,
        Followers
    ),
    {ok, _} = q(["DEL", follower_key(Uid)]),
    _Result = qmn(Commands),
    {ok, Followers}.


%% Uid blocks Ouid
-spec block(Uid :: uid(), Ouid :: uid()) -> ok.
block(Uid, Ouid) ->
    [{ok, _}, {ok, _}, {ok, _}] = qp([
        ["ZREM", following_key(Uid), Ouid],
        ["ZREM", follower_key(Uid), Ouid],
        ["SADD", blocked_key(Uid), Ouid]
    ]),
    [{ok, _}, {ok, _}, {ok, _}] = qp([
        ["ZREM", following_key(Ouid), Uid],
        ["ZREM", follower_key(Ouid), Uid],
        ["SADD", blocked_by_key(Ouid), Uid]
    ]),
    ok.


%% Uid unblocks Ouid
-spec unblock(Uid :: uid(), Ouid :: uid()) -> ok.
unblock(Uid, Ouid) ->
    [{ok, _}, {ok, _}] = qmn([
        ["SREM", blocked_key(Uid), Ouid],
        ["SREM", blocked_by_key(Ouid), Uid]
    ]),
    ok.


%% Uid blocked Ouid ?
-spec is_blocked(Uid :: uid(), Ouid :: uid()) -> boolean().
is_blocked(Uid, Ouid) ->
    {ok, Res} = q(["SISMEMBER", blocked_key(Uid), Ouid]),
    util_redis:decode_boolean(Res).


%% Uid is blocked by Ouid ?
-spec is_blocked_by(Uid :: uid(), Ouid :: uid()) -> boolean().
is_blocked_by(Uid, Ouid) ->
    {ok, Res} = q(["SISMEMBER", blocked_by_key(Uid), Ouid]),
    util_redis:decode_boolean(Res).


%% Uid blocked Ouid  or  Ouid blocked Uid
-spec is_blocked_any(Uid :: uid(), Ouid :: uid()) -> boolean().
is_blocked_any(Uid, Ouid) ->
    [{ok, Res1}, {ok, Res2}] = qp([
        ["SISMEMBER", blocked_key(Uid), Ouid],
        ["SISMEMBER", blocked_by_key(Uid), Ouid]
    ]),
    util_redis:decode_boolean(Res1) orelse util_redis:decode_boolean(Res2).


%% Get list of uids that Uid has blocked
-spec get_blocked_uids(Uid :: uid()) -> list(uid()) | {error, any()}.
get_blocked_uids(Uid) ->
    {ok, Res} = q(["SMEMBERS", blocked_key(Uid)]),
    Res.


%% Get list of uids that have blocked Uid
-spec get_blocked_by_uids(Uid :: uid()) -> list(uid()) | {error, any()}.
get_blocked_by_uids(Uid) ->
    {ok, Res} = q(["SMEMBERS", blocked_by_key(Uid)]),
    Res.


-spec remove_all_blocked_uids(Uid :: uid()) -> ok.
remove_all_blocked_uids(Uid) ->
    BlockedUsers = get_blocked_uids(Uid),
    CommandsList = lists:map(
        fun(Ouid) ->
            {["SREM", blocked_key(Uid), Ouid], ["SREM", blocked_by_key(Ouid), Uid]}
        end,
        BlockedUsers),
    {BlockedList, BlockedByList} = lists:unzip(CommandsList),
    _BlockedResults = qp(BlockedList),
    _BlockedByResults = qmn(BlockedByList),
    ok.


-spec remove_all_blocked_by_uids(Uid :: uid()) -> ok.
remove_all_blocked_by_uids(Uid) ->
    BlockedByUsers = get_blocked_by_uids(Uid),
    CommandsList = lists:map(
        fun(Ouid) ->
            {["SREM", blocked_by_key(Uid), Ouid], ["SREM", blocked_key(Ouid), Uid]}
        end,
        BlockedByUsers),
    {BlockedByList, BlockedList} = lists:unzip(CommandsList),
    _BlockedResults = qmn(BlockedList),
    _BlockedByResults = qp(BlockedByList),
    ok.

%%====================================================================
%% Internal functions
%%====================================================================

get_all(Key, Cursor, Limit) when Cursor =:= <<>> orelse Cursor =:= undefined ->
    {ok, RawRes} = q(["ZRANGE", Key, "+inf", "-inf", "BYSCORE", "REV", "LIMIT", 0, Limit, "WITHSCORES"]),
    Res = util_redis:parse_zrange_with_scores(RawRes),
    {Uids, Scores} = lists:unzip(Res),
    case length(Uids) < Limit orelse length(Uids) =:= 0 of
        true -> {Uids, <<>>};
        false -> {Uids, lists:last(Scores)}
    end;

get_all(Key, Cursor, Limit) ->
    {ok, RawRes} = q(["ZRANGE", Key, <<"(", Cursor/binary>>, "-inf", "BYSCORE", "REV", "LIMIT", 0, Limit, "WITHSCORES"]),
    Res = util_redis:parse_zrange_with_scores(RawRes),
    {Uids, Scores} = lists:unzip(Res),
    case length(Uids) < Limit orelse length(Uids) =:= 0 of
        true -> {Uids, <<>>};
        false -> {Uids, lists:last(Scores)}
    end.


get_all_internal(Key) ->
    {Res, _} = get_all(Key, <<>>, -1),
    Res.

get_count_internal(Key) ->
    {ok, RawCount} = q(["ZCARD", Key]),
    binary_to_integer(RawCount).

q(Command) -> ecredis:q(ecredis_friends, Command).
qp(Commands) -> ecredis:qp(ecredis_friends, Commands).
qmn(Commands) -> ecredis:qmn(ecredis_friends, Commands).

follower_key(Uid) ->
    <<?FOLLOWER_KEY/binary, <<"{">>/binary, Uid/binary, <<"}">>/binary>>.

following_key(Uid) ->
    <<?FOLLOWING_KEY/binary, <<"{">>/binary, Uid/binary, <<"}">>/binary>>.

blocked_key(Uid) ->
    <<?BLOCKED_KEY/binary, <<"{">>/binary, Uid/binary, <<"}">>/binary>>.

blocked_by_key(Uid) ->
    <<?BLOCKED_BY_KEY/binary, <<"{">>/binary, Uid/binary, <<"}">>/binary>>.

fof_index_key(Uid) ->
    <<?FOF_INDEX_KEY/binary, <<"{">>/binary, Uid/binary, <<"}">>/binary>>.

contact_suggestions_key(Uid) ->
    <<?CONTACT_SUGGESTIONS_KEY/binary, "{", Uid/binary, "}">>.

fof_suggestions_key(Uid) ->
    <<?FOF_SUGGESTIONS_KEY/binary, "{", Uid/binary, "}">>.

