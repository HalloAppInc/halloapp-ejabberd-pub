%%%-------------------------------------------------------------------
%%% File: athena_push.erl
%%% copyright (C) 2021, HalloApp, Inc.
%%%
%%% Module with all athena push queries.
%%%
%%%-------------------------------------------------------------------
-module(athena_push).
-behavior(athena_query).
-author('murali').

-include("time.hrl").
-include("athena_query.hrl").

%% All query functions must end with query.
-export([
    %% callback for behavior function.
    get_queries/0,

    %% query functions for debug!
    push_success_rates_version/3,
    push_success_rates_cc/3,

    %% result processing functions.
    record_by_version/1,
    record_by_cc/1,
    record_by_platform/1
]).

%%====================================================================
%% mod_athena_stats callback
%%====================================================================
-define(MIN_ANDROID_VERSION, <<"HalloApp/Android0.130">>).
-define(MIN_IOS_VERSION, <<"HalloApp/iOS1.3.96">>).

get_queries() ->
    QueryTimeMs = util:now_ms() - ?WEEKS_MS,
    QueryTimeMsBin = util:to_binary(QueryTimeMs),
    [
        push_success_rates_version(?ANDROID, QueryTimeMsBin,?MIN_ANDROID_VERSION),
        push_success_rates_version(?IOS, QueryTimeMsBin, ?MIN_IOS_VERSION),
        push_success_rates_cc(?ANDROID, QueryTimeMsBin, ?MIN_ANDROID_VERSION),
        push_success_rates_cc(?IOS, QueryTimeMsBin, ?MIN_IOS_VERSION),
        push_success_rates_platform(QueryTimeMsBin, ?MIN_ANDROID_VERSION),
        push_latencies_version(?ANDROID, QueryTimeMsBin, ?MIN_ANDROID_VERSION),
        push_latencies_version(?IOS, QueryTimeMsBin, ?MIN_IOS_VERSION),
        push_latencies_cc(?ANDROID, QueryTimeMsBin, ?MIN_ANDROID_VERSION),
        push_latencies_cc(?IOS, QueryTimeMsBin, ?MIN_IOS_VERSION),
        push_latencies_platform(QueryTimeMsBin, ?MIN_ANDROID_VERSION)
    ].
    %% TODO: Update these queries to use push_api here.


%%====================================================================
%% encryption queries
%%====================================================================

push_success_rates_version(Platform, TimestampMsBin, _OldestClientVersion) ->
    QueryBin = <<"
        SELECT success.version, ROUND( success.count * 100.0 / total.count, 2) as rate, total.count as count
        FROM
            (SELECT server_push_sent.client_version as version, count(*) as count
            FROM server_push_sent
            LEFT JOIN client_push_received
            ON server_push_sent.push_id=client_push_received.push_received.id
            WHERE server_push_sent.platform='", Platform/binary, "'
                AND client_push_received.push_received.id IS NOT NULL
                AND server_push_sent.timestamp_ms>='", TimestampMsBin/binary, "'
            GROUP BY server_push_sent.client_version) as success
        JOIN
            (SELECT server_push_sent.client_version as version, count(*) as count
            FROM server_push_sent
            LEFT JOIN client_push_received
            ON server_push_sent.push_id=client_push_received.push_received.id
            WHERE server_push_sent.platform='", Platform/binary, "'
                AND server_push_sent.timestamp_ms>='", TimestampMsBin/binary, "'
            GROUP BY server_push_sent.client_version) as total
        ON success.version=total.version">>,
    #athena_query{
        query_bin = QueryBin,
        tags = #{"platform" => util:to_list(Platform)},
        result_fun = {?MODULE, record_by_version},
        metrics = ["push_success_rate_by_version"]
    }.


push_success_rates_cc(Platform, TimestampMsBin, _OldestClientVersion) ->
    QueryBin = <<"
        SELECT success.cc, ROUND( success.count * 100.0 / total.count, 2) as rate, total.count as count
        FROM
            (SELECT server_push_sent.cc as cc, count(*) as count
            FROM server_push_sent
            LEFT JOIN client_push_received
            ON server_push_sent.push_id=client_push_received.push_received.id
            WHERE server_push_sent.platform='", Platform/binary, "'
                AND client_push_received.push_received.id IS NOT NULL
                AND server_push_sent.timestamp_ms>='", TimestampMsBin/binary, "'
            GROUP BY server_push_sent.cc) as success
        JOIN
            (SELECT server_push_sent.cc as cc, count(*) as count
            FROM server_push_sent
            LEFT JOIN client_push_received
            ON server_push_sent.push_id=client_push_received.push_received.id
            WHERE server_push_sent.platform='", Platform/binary, "'
                AND server_push_sent.timestamp_ms>='", TimestampMsBin/binary, "'
            GROUP BY server_push_sent.cc) as total
        ON success.cc=total.cc">>,
    #athena_query{
        query_bin = QueryBin,
        tags = #{"platform" => util:to_list(Platform)},
        result_fun = {?MODULE, record_by_cc},
        metrics = ["push_success_rate_by_cc"]
    }.

push_success_rates_platform(TimestampMsBin, _OldestClientVersion) ->
    QueryBin = <<"
        SELECT success.platform, ROUND( success.count * 100.0 / total.count, 2) as rate, total.count as count
        FROM
            (SELECT server_push_sent.platform as platform, count(*) as count
            FROM server_push_sent
            LEFT JOIN client_push_received
            ON server_push_sent.push_id=client_push_received.push_received.id
            WHERE client_push_received.push_received.id IS NOT NULL
                AND server_push_sent.timestamp_ms>='", TimestampMsBin/binary, "'
            GROUP BY server_push_sent.platform) as success
        JOIN
            (SELECT server_push_sent.platform as platform, count(*) as count
            FROM server_push_sent
            LEFT JOIN client_push_received
            ON server_push_sent.push_id=client_push_received.push_received.id
            WHERE server_push_sent.timestamp_ms>='", TimestampMsBin/binary, "'
            GROUP BY server_push_sent.platform) as total
        ON success.platform=total.platform">>,
        #athena_query {
            query_bin = QueryBin,
            tags = #{},
            result_fun = {?MODULE, record_by_platform},
            metrics = ["push_success_rate_by_platform"]
        }.

push_latencies_version(Platform, TimestampMsBin, _OldestClientVersion) ->
    QueryBin = <<"
        SELECT server_push_sent.client_version as version, 
            ROUND(GREATEST(1000,AVG(CAST(client_push_received.push_received.client_timestamp AS BIGINT)) 
                - AVG(CAST(server_push_sent.timestamp_ms AS BIGINT)))/1000.0, 2) as latency, count(*) as count
        FROM server_push_sent
        INNER JOIN client_push_received
        ON server_push_sent.push_id=client_push_received.push_received.id
        WHERE server_push_sent.platform='", Platform/binary, "'
            AND client_push_received.push_received.id IS NOT NULL
            AND server_push_sent.timestamp_ms>='", TimestampMsBin/binary, "'
        GROUP BY server_push_sent.client_version">>,
    #athena_query{
        query_bin = QueryBin,
        tags = #{"platform" => util:to_list(Platform)},
        result_fun = {?MODULE, record_by_version},
        metrics = ["push_latency_by_version"]
    }.

push_latencies_cc(Platform, TimestampMsBin, _OldestClientVersion) ->
    QueryBin = <<"
        SELECT server_push_sent.cc as cc,
            ROUND(GREATEST(1000,AVG(CAST(client_push_received.push_received.client_timestamp AS BIGINT)) 
                - AVG(CAST(server_push_sent.timestamp_ms AS BIGINT)))/1000.0, 2) as latency, count(*) as count
            FROM server_push_sent
            INNER JOIN client_push_received
            ON server_push_sent.push_id=client_push_received.push_received.id
            WHERE server_push_sent.platform='", Platform/binary, "'
                AND client_push_received.push_received.id IS NOT NULL
                AND server_push_sent.timestamp_ms>='", TimestampMsBin/binary, "'
            GROUP BY server_push_sent.cc">>,
    #athena_query{
        query_bin = QueryBin,
        tags = #{"platform" => util:to_list(Platform)},
        result_fun = {?MODULE, record_by_cc},
        metrics = ["push_latency_by_cc"]
    }.

push_latencies_platform(TimestampMsBin, _OldestClientVersion) ->
    QueryBin = <<"
        SELECT server_push_sent.platform as platform,
            ROUND(GREATEST(1000,AVG(CAST(client_push_received.push_received.client_timestamp AS BIGINT)) 
                - AVG(CAST(server_push_sent.timestamp_ms AS BIGINT)))/1000.0, 2) as latency, count(*) as count
            FROM server_push_sent
            INNER JOIN client_push_received
            ON server_push_sent.push_id=client_push_received.push_received.id
            WHERE client_push_received.push_received.id IS NOT NULL
                AND server_push_sent.timestamp_ms>='", TimestampMsBin/binary, "'
            GROUP BY server_push_sent.platform">>,
    #athena_query{
        query_bin = QueryBin,
        tags = #{},
        result_fun = {?MODULE, record_by_platform},
        metrics = ["push_latency_by_platform"]
    }.


-spec record_by_version(Query :: athena_query()) -> ok.
record_by_version(Query) ->
    record_by("version", Query).

-spec record_by_cc(Query :: athena_query()) -> ok.
record_by_cc(Query) ->
    record_by("cc", Query).

-spec record_by_platform(Query :: athena_query()) -> ok.
record_by_platform(Query) ->
    record_by("platform", Query).

-spec record_by(Variable :: string(), Query :: athena_query()) -> ok.
record_by(Variable, Query) ->
    Result = Query#athena_query.result,
    ResultRows = maps:get(<<"ResultRows">>, maps:get(<<"ResultSet">>, Result)),
    [_HeaderRow | ActualResultRows] = ResultRows,
    TagsAndValues = maps:to_list(Query#athena_query.tags),
    [Metric1] = Query#athena_query.metrics,
    lists:foreach(
        fun(ResultRow) ->
            [VarValue, SuccessRateStr, TotalStr] = maps:get(<<"Data">>, ResultRow),
            {SuccessRate, <<>>} = string:to_float(SuccessRateStr),
            stat:count("HA/push", Metric1, SuccessRate,
                    [{Variable, util:to_list(VarValue)} | TagsAndValues]),
            TotalCount = util:to_integer(TotalStr),
            stat:count("HA/push", Metric1 ++ "_count", TotalCount,
                    [{Variable, util:to_list(VarValue)} | TagsAndValues])
        end, ActualResultRows),
    ok.
