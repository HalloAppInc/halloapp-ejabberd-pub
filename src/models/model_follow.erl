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
    get_all_following/1,
    get_followers/3,
    get_all_followers/1,
    block/2,
    unblock/2,
    is_blocked/2,
    is_blocked_by/2,
    is_blocked_any/2,
    get_blocked_uids/1,
    get_blocked_by_uids/1
]).

%%====================================================================
%% API
%%====================================================================

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


%% Get everyone that Uid is following (not paginated)
-spec get_all_following(Uid :: uid()) -> list(uid()).
get_all_following(Uid) ->
    get_all_internal(following_key(Uid)).


%% Get everyone following Uid (paginated)
-spec get_followers(Uid :: uid(), Cursor :: binary(), Limit :: pos_integer()) ->
    {Uids :: list(uid()), NewCursor :: binary()}.
get_followers(Uid, Cursor, Limit) ->
    get_all(follower_key(Uid), Cursor, Limit).


%% Get everyone following Uid (not paginated)
-spec get_all_followers(Uid :: uid()) -> list(uid()).
get_all_followers(Uid) ->
    get_all_internal(follower_key(Uid)).


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

%%====================================================================
%% Internal functions
%%====================================================================

get_all(Key, Cursor, Limit) when Cursor =:= <<>> ->
    %% TODO: update github ci to redis 6.2 so this command doesn't fail tests
%%    {ok, RawRes} = q(["ZRANGE", Key, "+inf", "-inf", "BYSCORE", "REV", "LIMIT", 0, Limit, "WITHSCORES"]),
    {ok, RawRes} = q(["ZREVRANGEBYSCORE", Key, "+inf", "-inf", "WITHSCORES", "LIMIT", 0, Limit]),
    Res = util_redis:parse_zrange_with_scores(RawRes),
    {Uids, Scores} = lists:unzip(Res),
    case length(Uids) < Limit orelse length(Uids) =:= 0 of
        true -> {Uids, <<>>};
        false -> {Uids, lists:last(Scores)}
    end;

get_all(Key, Cursor, Limit) ->
    %% TODO: update github ci to redis 6.2 so this command doesn't fail tests
%%    {ok, RawRes} = q(["ZRANGE", Key, <<"(", Cursor/binary>>, "-inf", "BYSCORE", "REV", "LIMIT", 0, Limit, "WITHSCORES"]),
    {ok, RawRes} = q(["ZREVRANGEBYSCORE", Key, <<"(", Cursor/binary>>, "-inf", "WITHSCORES", "LIMIT", 0, Limit]),
    Res = util_redis:parse_zrange_with_scores(RawRes),
    {Uids, Scores} = lists:unzip(Res),
    case length(Uids) < Limit orelse length(Uids) =:= 0 of
        true -> {Uids, <<>>};
        false -> {Uids, lists:last(Scores)}
    end.


get_all_internal(Key) ->
    {Res, _} = get_all(Key, <<>>, -1),
    Res.


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

