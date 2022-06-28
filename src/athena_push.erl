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
    record_success_version/1,
    record_success_cc/1
]).

%%====================================================================
%% mod_athena_stats callback
%%====================================================================

get_queries() ->
    QueryTimeMs = util:now_ms() - ?WEEKS_MS,
    QueryTimeMsBin = util:to_binary(QueryTimeMs),
    [
        push_success_rates_version(?ANDROID, QueryTimeMsBin, <<"HalloApp/Android0.130">>),
        push_success_rates_version(?IOS, QueryTimeMsBin, <<"HalloApp/iOS1.3.96">>),
        push_success_rates_cc(?ANDROID, QueryTimeMsBin, <<"HalloApp/Android0.130">>),
        push_success_rates_cc(?IOS, QueryTimeMsBin, <<"HalloApp/iOS1.3.96">>)
    ].


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
        result_fun = {?MODULE, record_success_version},
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
        result_fun = {?MODULE, record_success_cc},
        metrics = ["push_success_rate_by_cc"]
    }.


-spec record_success_version(Query :: athena_query()) -> ok.
record_success_version(Query) ->
    Result = Query#athena_query.result,
    ResultRows = maps:get(<<"ResultRows">>, maps:get(<<"ResultSet">>, Result)),
    [_HeaderRow | ActualResultRows] = ResultRows,
    TagsAndValues = maps:to_list(Query#athena_query.tags),
    [Metric1] = Query#athena_query.metrics,
    lists:foreach(
        fun(ResultRow) ->
            [Version, SuccessRateStr, TotalStr] = maps:get(<<"Data">>, ResultRow),
            {SuccessRate, <<>>} = string:to_float(SuccessRateStr),
            stat:count("HA/push", Metric1, SuccessRate,
                    [{"version", util:to_list(Version)} | TagsAndValues]),
            TotalCount = util:to_integer(TotalStr),
            stat:count("HA/push", Metric1 ++ "_count", TotalCount,
                    [{"version", util:to_list(Version)} | TagsAndValues])
        end, ActualResultRows),
    ok.


-spec record_success_cc(Query :: athena_query()) -> ok.
record_success_cc(Query) ->
    Result = Query#athena_query.result,
    ResultRows = maps:get(<<"ResultRows">>, maps:get(<<"ResultSet">>, Result)),
    [_HeaderRow | ActualResultRows] = ResultRows,
    TagsAndValues = maps:to_list(Query#athena_query.tags),
    [Metric1] = Query#athena_query.metrics,
    lists:foreach(
        fun(ResultRow) ->
            [CC, SuccessRateStr, TotalStr] = maps:get(<<"Data">>, ResultRow),
            {SuccessRate, <<>>} = string:to_float(SuccessRateStr),
            stat:count("HA/push", Metric1, SuccessRate,
                    [{"cc", util:to_list(CC)} | TagsAndValues]),
            TotalCount = util:to_integer(TotalStr),
            stat:count("HA/push", Metric1 ++ "_count", TotalCount,
                    [{"cc", util:to_list(CC)} | TagsAndValues])
        end, ActualResultRows),
    ok.

