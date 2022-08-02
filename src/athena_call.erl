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
    %% result processing functions.
    record_global/1
]).

%%====================================================================
%% mod_athena_stats callback
%%====================================================================

get_queries() ->
    QueryTimeMs = util:now_ms() - ?DAYS_MS,
    QueryTimeMsBin = util:to_binary(QueryTimeMs),
    [
        unique_call_answered_count(QueryTimeMsBin),
        unique_call_connected_count(QueryTimeMsBin),
        unique_call_has_duration_count(QueryTimeMsBin)
    ].


%%====================================================================
%% call queries
%%====================================================================

unique_call_connected_count(TimestampMsBin) ->
    QueryBin = <<"
        SELECT
            SUM(CASE WHEN all_calls.bothsides THEN 1 ELSE 0 END) as connected, 
            COUNT(*) AS count 
        FROM 
            (SELECT 
                COUNT(*) = SUM(CASE WHEN client_call.call.connected THEN 1 ELSE 0 END) as bothsides
            FROM client_call
                WHERE client_call.timestamp_ms >='", TimestampMsBin/binary,"'
            GROUP BY client_call.call.call_id
            ) AS all_calls">>,
    #athena_query{
        query_bin = QueryBin,
        tags = #{},
        result_fun = {?MODULE, record_global},
        metrics = ["unique_call_connected"]
    }.


unique_call_answered_count(TimestampMsBin) ->
    QueryBin = <<"
        SELECT
            SUM(CASE WHEN all_calls.bothsides THEN 1 ELSE 0 END) as answered, 
            COUNT(*) AS count 
        FROM 
            (SELECT 
                COUNT(*) = SUM(CASE WHEN client_call.call.answered THEN 1 ELSE 0 END) as bothsides
            FROM client_call
                WHERE client_call.timestamp_ms >='", TimestampMsBin/binary,"'
            GROUP BY client_call.call.call_id
            ) AS all_calls">>,
    #athena_query{
        query_bin = QueryBin,
        tags = #{},
        result_fun = {?MODULE, record_global},
        metrics = ["unique_call_answered"]
    }.

unique_call_has_duration_count(TimestampMsBin) ->
    QueryBin = <<"
        SELECT
            SUM(CASE WHEN all_calls.bothsides THEN 1 ELSE 0 END) as has_duration, 
            COUNT(*) AS count 
        FROM 
            (SELECT 
                COUNT(*) = SUM(CASE WHEN client_call.call.duration_ms != '0' THEN 1 ELSE 0 END) as bothsides
            FROM client_call
                WHERE client_call.timestamp_ms >='", TimestampMsBin/binary,"'
            GROUP BY client_call.call.call_id
            ) AS all_calls">>,
    #athena_query{
        query_bin = QueryBin,
        tags = #{},
        result_fun = {?MODULE, record_global},
        metrics = ["unique_call_has_duration"]
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
