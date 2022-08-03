%%%-------------------------------------------------------------------
%%% File: athena_call.erl
%%% copyright (C) 2022, HalloApp, Inc.
%%%
%%% Module with all athena call queries.
%%%
%%%-------------------------------------------------------------------
-module(athena_call).
-behavior(athena_query).
-author(thomas).

-include("time.hrl").
-include("athena_query.hrl").

-export([
    %% callback for behavior function.
    get_queries/0,
    get_hourly_queries/0,
    %% result processing functions.
    record_global/1
]).

-define(HOURLY, "_hourly").

%%====================================================================
%% mod_athena_stats callback
%%====================================================================

get_queries() ->
    MinQueryTimeMs = util:now_ms() - ?DAYS_MS,
    MinQueryTimeMsBin = util:to_binary(MinQueryTimeMs),
    MaxQueryTimeMs = util:now_ms(),
    MaxQueryTimeMsBin = util:to_binary(MaxQueryTimeMs),
    [
        unique_call_answered_count(MinQueryTimeMsBin, MaxQueryTimeMsBin, ""),
        unique_call_connected_count(MinQueryTimeMsBin, MaxQueryTimeMsBin, ""),
        unique_call_has_duration_count(MinQueryTimeMsBin, MaxQueryTimeMsBin, "")
    ].

get_hourly_queries() ->
    % Query the past hour a day ago.
    MinQueryTimeMs = util:now_ms() - ?DAYS_MS - ?HOURS_MS,
    MinQueryTimeMsBin = util:to_binary(MinQueryTimeMs),
    MaxQueryTimeMs = util:now_ms() - ?DAYS_MS,
    MaxQueryTimeMsBin = util:to_binary(MaxQueryTimeMs),
    [
        unique_call_answered_count(MinQueryTimeMsBin, MaxQueryTimeMsBin, ?HOURLY),
        unique_call_connected_count(MinQueryTimeMsBin, MaxQueryTimeMsBin, ?HOURLY),
        unique_call_has_duration_count(MinQueryTimeMsBin, MaxQueryTimeMsBin, ?HOURLY)
    ].

%%====================================================================
%% call queries
%%====================================================================

unique_call_connected_count(MinTimestampMsBin, MaxTimestampMsBin, Suffix) ->
    QueryBin = <<"
        SELECT
            SUM(CASE WHEN all_calls.bothsides THEN 1 ELSE 0 END) as connected, 
            COUNT(*) AS count 
        FROM 
            (SELECT 
                COUNT(*) = SUM(CASE WHEN client_call.call.connected THEN 1 ELSE 0 END) as bothsides
            FROM client_call
                WHERE client_call.timestamp_ms >='", MinTimestampMsBin/binary,"'
                AND   client_call.timestamp_ms <='", MaxTimestampMsBin/binary,"'
            GROUP BY client_call.call.call_id
            ) AS all_calls">>,
    #athena_query{
        query_bin = QueryBin,
        tags = #{},
        result_fun = {?MODULE, record_global},
        metrics = ["unique_call_connected" ++ Suffix]
    }.


unique_call_answered_count(MinTimestampMsBin, MaxTimestampMsBin, Suffix) ->
    QueryBin = <<"
        SELECT
            SUM(CASE WHEN all_calls.bothsides THEN 1 ELSE 0 END) as answered, 
            COUNT(*) AS count 
        FROM 
            (SELECT 
                COUNT(*) = SUM(CASE WHEN client_call.call.answered THEN 1 ELSE 0 END) as bothsides
            FROM client_call
                WHERE client_call.timestamp_ms >='", MinTimestampMsBin/binary,"'
                AND   client_call.timestamp_ms <='", MaxTimestampMsBin/binary,"'
            GROUP BY client_call.call.call_id
            ) AS all_calls">>,
    #athena_query{
        query_bin = QueryBin,
        tags = #{},
        result_fun = {?MODULE, record_global},
        metrics = ["unique_call_answered" ++ Suffix]
    }.

unique_call_has_duration_count(MinTimestampMsBin, MaxTimestampMsBin, Suffix) ->
    QueryBin = <<"
        SELECT
            SUM(CASE WHEN all_calls.bothsides THEN 1 ELSE 0 END) as has_duration, 
            COUNT(*) AS count 
        FROM 
            (SELECT 
                COUNT(*) = SUM(CASE WHEN client_call.call.duration_ms != '0' THEN 1 ELSE 0 END) as bothsides
            FROM client_call
                WHERE client_call.timestamp_ms >='", MinTimestampMsBin/binary,"'
                AND   client_call.timestamp_ms <='", MaxTimestampMsBin/binary,"'
            GROUP BY client_call.call.call_id
            ) AS all_calls">>,
    #athena_query{
        query_bin = QueryBin,
        tags = #{},
        result_fun = {?MODULE, record_global},
        metrics = ["unique_call_has_duration" ++ Suffix]
    }.


-spec record_global(Query :: athena_query()) -> ok.
record_global(Query) ->
    Result = Query#athena_query.result,
    ResultRows = maps:get(<<"ResultRows">>, maps:get(<<"ResultSet">>, Result)),
    [_HeaderRow | ActualResultRows] = ResultRows,
    TagsAndValues = maps:to_list(Query#athena_query.tags),
    [Metric1] = Query#athena_query.metrics,
    lists:foreach(
        fun(ResultRow) ->
            [CountStr, TotalStr] = maps:get(<<"Data">>, ResultRow),
            Count = util:to_integer(CountStr),
            stat:count("HA/call", Metric1, Count, TagsAndValues),
            TotalCount = util:to_integer(TotalStr),
            stat:count("HA/call", Metric1 ++ "_count", TotalCount, TagsAndValues)
        end, ActualResultRows),
    ok.
