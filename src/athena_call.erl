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
    record_by_cc/1
]).

%%====================================================================
%% mod_athena_stats callback
%%====================================================================

get_queries() ->
    %athena queries are ran hourly - to avoid double counting, only query the last hour of results.
    QueryTimeMs = util:now_ms() - ?HOURS_MS,
    QueryTimeMsBin = util:to_binary(QueryTimeMs),
    [
        unique_call_answered_count_by_cc(?ANDROID,QueryTimeMsBin),
        unique_call_answered_count_by_cc(?IOS, QueryTimeMsBin),
        unique_call_connected_count_by_cc(?ANDROID,QueryTimeMsBin),
        unique_call_connected_count_by_cc(?IOS, QueryTimeMsBin)
    ].


%%====================================================================
%% call queries
%%====================================================================

unique_call_connected_count_by_cc(Platform, TimestampMsBin) ->
    QueryBin = <<"
        SELECT fullcall.cc as cc, 
               SUM(CASE WHEN fullcall.bothsides THEN 1 ELSE 0 END) as connected, 
               COUNT(*) AS count 
        FROM 
            (SELECT 
                client_call.cc as cc, 
                (mirror.call IS NULL OR mirror.call.connected) AND client_call.call.connected as bothsides 
            FROM client_call LEFT JOIN
                (client_call AS mirror)
            ON mirror.uid != client_call.uid AND client_call.call.call_id = mirror.call.call_id
            WHERE client_call.timestamp_ms >='", TimestampMsBin/binary,"'
            AND client_call.platform='", Platform/binary,"'
            ) AS fullcall
        GROUP BY fullcall.cc">>,
    #athena_query{
        query_bin = QueryBin,
        tags = #{"platform" => util:to_list(Platform)},
        result_fun = {?MODULE, record_by_cc},
        metrics = ["unique_call_connected_by_cc"]
    }.


unique_call_answered_count_by_cc(Platform, TimestampMsBin) ->
    QueryBin = <<"
        SELECT fullcall.cc as cc, 
               SUM(CASE WHEN fullcall.bothsides THEN 1 ELSE 0 END) as answered, 
               COUNT(*) AS count 
        FROM 
            (SELECT 
                client_call.cc as cc, 
                (mirror.call IS NULL OR mirror.call.answered) AND client_call.call.answered as bothsides 
            FROM client_call LEFT JOIN
                (client_call AS mirror)
            ON mirror.uid != client_call.uid AND client_call.call.call_id = mirror.call.call_id
            WHERE client_call.timestamp_ms >='", TimestampMsBin/binary,"'
            AND client_call.platform='", Platform/binary,"'
            ) AS fullcall
        GROUP BY fullcall.cc">>,
    #athena_query{
        query_bin = QueryBin,
        tags = #{"platform" => util:to_list(Platform)},
        result_fun = {?MODULE, record_by_cc},
        metrics = ["unique_call_answered_by_cc"]
    }.

-spec record_by_cc(Query :: athena_query()) -> ok.
record_by_cc(Query) ->
    record_by("cc", Query).

-spec record_by(Variable :: string(), Query :: athena_query()) -> ok.
record_by(Variable, Query) ->
    Result = Query#athena_query.result,
    ResultRows = maps:get(<<"ResultRows">>, maps:get(<<"ResultSet">>, Result)),
    [_HeaderRow | ActualResultRows] = ResultRows,
    TagsAndValues = maps:to_list(Query#athena_query.tags),
    [Metric1] = Query#athena_query.metrics,
    lists:foreach(
        fun(ResultRow) ->
            [VarValue, CountStr, TotalStr] = maps:get(<<"Data">>, ResultRow),
            {Count, <<>>} = string:to_float(CountStr),
            stat:count("HA/call", Metric1, Count,
                    [{Variable, util:to_list(VarValue)} | TagsAndValues]),
            TotalCount = util:to_integer(TotalStr),
            stat:count("HA/call", Metric1 ++ "_count", TotalCount,
                    [{Variable, util:to_list(VarValue)} | TagsAndValues])
        end, ActualResultRows),
    ok.
