%%%------------------------------------------------------------------------------------
%%% File: model_gw_score.erl
%%% Copyright (C) 2021, HalloApp, Inc.
%%%
%%% This model handles all the redis db queries that are related to gateway scoring.
%%% Each score entry contains two scores: recent and aggregate. Scores are always out
%%% of 100, and essentially represent the percentage of otp requests that result 
%%% in a new user registration.
%%%     - recent scores are outputted by stat_sms:check_gw_scores/0 and represent the
%%%         success rate of otp requests over the most recent interval s.t. 
%%%         2 hours <= IntervalLength <= 48 Hours and the interval contains at least 
%%%         a certain number of texts (?MIN_TEXTS_TO_SCORE_GW in sms.hrl)
%%%     - aggregate scores are a running combination of previous scores calculated
%%%         by: NewAggregateScore = RecentScore * ?RECENT_SCORE_WEIGHT + 
%%%                                     OldAggregateScore * (1 - ?RECENT_SCORE_WEIGHT).
%%%         Basically, they're a weighted average of the new Recent score with the
%%%         previous Aggregate score
%%%
%%%------------------------------------------------------------------------------------
-module(model_gw_score).
-author("luke").

-include("sms.hrl").
-include("redis_keys.hrl").
-include("time.hrl").

-define(TTL_TS_GW_SCORES, 2 * ?DAYS).

-ifdef(TEST).
%% debugging purposes
-include_lib("eunit/include/eunit.hrl").
-endif.

-export([
    store_score/3,
    store_score/4,
    get_aggregate_score/1,
    get_aggregate_score/2,
    get_aggregate_count/1,
    get_recent_score/1,
    get_recent_score/2,
    get_old_scores/2,
    get_aggregate_stats/1
]).

%%====================================================================
%% API
%%====================================================================

-define(FIELD_RECENT_SCORE, <<"rec">>).
-define(FIELD_AGGREGATE_SCORE, <<"agg">>).
-define(FIELD_AGGREGATE_COUNT, <<"cnt">>).
-define(FIELD_TEST_AGGREGATE_SCORE, <<"tagg">>).
-define(FIELD_TEST_RECENT_SCORE, <<"trec">>).

%% sets both current score and timestamped score (for logging/info purposes) with structure 
%%      score:GatewayCC recent RecentScore running AggScore 
%%      score:GatewayCC:TimeStamp recent RecentScore running AggScore
%% returns Increment time stamp
-spec store_score(ScoreName :: atom(), RecentScore :: integer(), AggScore :: integer()) -> 
        TimeStamp :: integer().
store_score(ScoreName, RecentScore, AggScore) ->
    CurrentIncrement = util:now() div ?SMS_REG_TIMESTAMP_INCREMENT,
    TsKey = ts_score_key(ScoreName, CurrentIncrement),
    TsCommand = [
        ["MULTI"],
        ["HSET", TsKey, 
            ?FIELD_RECENT_SCORE, util:to_binary(RecentScore), 
            ?FIELD_AGGREGATE_SCORE, util:to_binary(AggScore)],
        ["EXPIRE", TsKey, ?TTL_TS_GW_SCORES],
        ["EXEC"]],
    CurCommand = ["HSET", current_score_key(ScoreName), 
            ?FIELD_RECENT_SCORE, util:to_binary(RecentScore), 
            ?FIELD_AGGREGATE_SCORE, util:to_binary(AggScore)],
    RedisCommands = TsCommand ++ [CurCommand],
    % ?debugFmt("Running ~p", [RedisCommands]),
    _Result = qp(RedisCommands),
    CurrentIncrement.


store_score(ScoreName, RecentScore, AggScore, AggCount) -> % Only difference: new flag was added to calls to get score keys.
    CurrentIncrement = util:now() div ?SMS_REG_TIMESTAMP_INCREMENT,
    TsKey = ts_score_key(ScoreName, CurrentIncrement),
    TsCommand = [
        ["MULTI"],
        ["HSET", TsKey, 
            ?FIELD_TEST_RECENT_SCORE, util:to_binary(RecentScore), 
            ?FIELD_TEST_AGGREGATE_SCORE, util:to_binary(AggScore),
            ?FIELD_AGGREGATE_COUNT, util:to_binary(AggCount)],
        ["EXPIRE", TsKey, ?TTL_TS_GW_SCORES],
        ["EXEC"]],
    CurCommand = ["HSET", current_score_key(ScoreName), 
            ?FIELD_TEST_RECENT_SCORE, util:to_binary(RecentScore), 
            ?FIELD_TEST_AGGREGATE_SCORE, util:to_binary(AggScore),
            ?FIELD_AGGREGATE_COUNT, util:to_binary(AggCount)],
    RedisCommands = TsCommand ++ [CurCommand],
    % ?debugFmt("Running ~p", [RedisCommands]),
    _Result = qp(RedisCommands),
    CurrentIncrement.


-spec get_aggregate_score(ScoreName :: atom()) -> {ok, integer()} | {ok, undefined}.
get_aggregate_score(ScoreName) -> 
    {ok, AggScore} = q(["HGET", current_score_key(ScoreName), ?FIELD_AGGREGATE_SCORE]),
    {ok, util_redis:decode_int(AggScore)}.


get_aggregate_score(ScoreName, test) -> 
    {ok, AggScore} = q(["HGET", current_score_key(ScoreName), ?FIELD_TEST_AGGREGATE_SCORE]),
    {ok, util_redis:decode_int(AggScore)}.


-spec get_recent_score(ScoreName :: atom()) -> {ok, integer()} | {ok, undefined}.
get_recent_score(ScoreName) -> 
    {ok, RecentScore} = q(["HGET", current_score_key(ScoreName), ?FIELD_RECENT_SCORE]),
    {ok, util_redis:decode_int(RecentScore)}.


get_recent_score(ScoreName, test) -> 
    {ok, RecentScore} = q(["HGET", current_score_key(ScoreName), ?FIELD_TEST_RECENT_SCORE]),
    {ok, util_redis:decode_int(RecentScore)}.


-spec get_aggregate_count(ScoreName :: atom()) -> {ok, integer()} | {ok, undefined}.
 get_aggregate_count(ScoreName) -> 
     {ok, AggScore} = q(["HGET", current_score_key(ScoreName), ?FIELD_AGGREGATE_COUNT]),
     {ok, util_redis:decode_int(AggScore)}.


-spec get_old_scores(ScoreName :: atom(), TimeStamp :: integer()) -> 
        {ok, integer(), integer()} | {ok, undefined, undefined}.
get_old_scores(ScoreName, TimeStamp) ->
    {ok, [RecentScore, AggScore]} = q(["HMGET", ts_score_key(ScoreName, TimeStamp), ?FIELD_RECENT_SCORE,
            ?FIELD_AGGREGATE_SCORE]),
    {ok, util_redis:decode_int(RecentScore), util_redis:decode_int(AggScore)}.


-spec get_aggregate_stats(ScoreName :: atom()) -> {ok, undefined, undefined} | {ok, integer(), integer()}.
get_aggregate_stats(ScoreName) ->
    {ok, [AggScore, AggCount]} = q(["HMGET", current_score_key(ScoreName), ?FIELD_TEST_AGGREGATE_SCORE,
            ?FIELD_AGGREGATE_COUNT]),
    {ok, util_redis:decode_int(AggScore), util_redis:decode_int(AggCount)}.

%%====================================================================
%% Internal
%%====================================================================


current_score_key(ScoreName) ->
    NameBin = util:to_binary(ScoreName),    
    <<?GW_SCORE_KEY/binary, <<"{">>/binary, NameBin/binary, <<"}">>/binary>>.


ts_score_key(ScoreName, TimeStamp) ->
    NameBin = util:to_binary(ScoreName),
    TSBin = util:to_binary(TimeStamp),
    <<?GW_SCORE_KEY/binary, <<"{">>/binary, NameBin/binary, <<"}:">>/binary, TSBin/binary>>.


q(Command) -> ecredis:q(ecredis_phone, Command).
qp(Commands) -> ecredis:qp(ecredis_phone, Commands).

