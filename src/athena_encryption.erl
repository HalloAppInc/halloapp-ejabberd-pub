%%%-------------------------------------------------------------------
%%% File: athena_queries.erl
%%% copyright (C) 2021, HalloApp, Inc.
%%%
%%% Module with all athena encryption queries.
%%%
%%%-------------------------------------------------------------------
-module(athena_encryption).
-behavior(athena_query).
-author('murali').

-include("time.hrl").
-include("athena_query.hrl").

%% All query functions must end with query.
-export([
    %% callback for behavior function.
    get_queries/0,

    %% query functions for debug!
    e2e_success_failure_rates/2,
    e2e_decryption_reason_rates/2,
    e2e_decryption_report/1,
    e2e_decryption_report_without_rerequest/1,

    %% result processing functions.
    record_enc_and_dec/1,
    record_dec/1,
    record_dec_report/1
]).

%%====================================================================
%% mod_athena_stats callback
%%====================================================================

get_queries() ->
    QueryTimeMs = util:now_ms() - ?WEEKS_MS,
    QueryTimeMsBin = util:to_binary(QueryTimeMs),
    [
        e2e_success_failure_rates(?ANDROID, QueryTimeMsBin),
        e2e_success_failure_rates(?IOS, QueryTimeMsBin),
        e2e_decryption_reason_rates(?ANDROID, QueryTimeMsBin),
        e2e_decryption_reason_rates(?IOS, QueryTimeMsBin),
        e2e_decryption_report(QueryTimeMsBin),
        e2e_decryption_report_without_rerequest(QueryTimeMsBin)
    ].


%%====================================================================
%% encryption queries
%%====================================================================

%% Query gets the encryption and decryption success rates ordered by version and total number
%% of messages for both encryption and decryption.
%% This query will run on a specific platform and on data from TimestampMs till current.
-spec e2e_success_failure_rates(Platform :: binary(), TimestampMsBin :: binary()) -> athena_query().
e2e_success_failure_rates(Platform, TimestampMsBin) ->
    QueryBin = <<"
        SELECT enc_success.version, enc_success.success_rate as enc_success_rate,
            enc_success.total_count as enc_total_count, dec_success.success_rate as dec_success_rate,
            dec_success.total_count as dec_total_count
        FROM
            (SELECT success.version, ROUND(success.count * 100 / total.count, 2) as success_rate, total.count as total_count
            FROM
                (SELECT version, SUM(cast(count AS REAL)) as count
                FROM \"default\".\"client_crypto_encryption\"
                    where platform='", Platform/binary, "' AND result='success' AND \"timestamp_ms\" >= '", TimestampMsBin/binary, "'
                    GROUP BY version) as success
            JOIN
                (SELECT version, SUM(cast(count AS REAL)) as count
                FROM \"default\".\"client_crypto_encryption\"
                    where platform='", Platform/binary, "' AND \"timestamp_ms\" >= '", TimestampMsBin/binary, "'
                    GROUP BY version) as total
                on success.version=total.version) as enc_success
        JOIN
            (SELECT success.version, ROUND(success.count * 100 / total.count, 2) as success_rate, total.count as total_count
            FROM
                (SELECT version, SUM(cast(count AS REAL)) as count
                FROM \"default\".\"client_crypto_decryption\"
                    where platform='", Platform/binary, "' AND result='success' AND \"timestamp_ms\" >= '", TimestampMsBin/binary, "'
                    GROUP BY version) as success
            JOIN
                (SELECT version, SUM(cast(count AS REAL)) as count
                FROM \"default\".\"client_crypto_decryption\"
                    where platform='", Platform/binary, "' AND \"timestamp_ms\" >= '", TimestampMsBin/binary, "'
                    GROUP BY version) as total  on success.version=total.version) as dec_success
        on enc_success.version=dec_success.version
        ORDER BY enc_success.version DESC;">>,
    #athena_query{
        query_bin = QueryBin,
        tags = #{"platform" => util:to_list(Platform)},
        result_fun = {?MODULE, record_enc_and_dec},
        metrics = ["encryption_rate", "decryption_rate"]
    }.


%% Query gets the decryption error rates ordered by version and the error reason.
%% Also has the number of messages for each of the error reasons.
%% This query will run on a specific platform and on data from TimestampMs till current.
-spec e2e_decryption_reason_rates(Platform :: binary(), TimestampMs :: binary()) -> athena_query().
e2e_decryption_reason_rates(Platform, TimestampMsBin) ->
    QueryBin = <<"
        SELECT reason.version, reason.result,
            ROUND(reason.count * 100.0 / total.count, 2) as reason_rate,
            reason.count as reason_count, total.count as total_count
        FROM
            (SELECT version, result, SUM(cast(count AS INTEGER)) as count
            FROM \"default\".\"client_crypto_decryption\"
                where platform='", Platform/binary, "' AND result!='success' AND \"timestamp_ms\" >= '", TimestampMsBin/binary, "'
                GROUP BY version, result) as reason
            JOIN
            (SELECT version, SUM(cast(count AS INTEGER)) as count
            FROM \"default\".\"client_crypto_decryption\"
                where platform='", Platform/binary, "' AND result!='success' AND \"timestamp_ms\" >= '", TimestampMsBin/binary, "'
                GROUP BY version) as total  on reason.version=total.version
        ORDER BY reason.version DESC, reason.count DESC;">>,
    #athena_query{
        query_bin = QueryBin,
        tags = #{"platform" => Platform},
        result_fun = undefined
        %% First value is encryption and next is decryption in the result.
    }.


%% Query gets the decryption report rates ordered by version.
%% This query will run on data from TimestampMs till current.
-spec e2e_decryption_report(TimestampMsBin :: binary()) -> athena_query().
e2e_decryption_report(TimestampMsBin) ->
    QueryBin = <<"
        SELECT success.platform, success.version, success.is_silent,
            ROUND(success.count * 100.0 / total.count, 2) as success_rate,
            success.count as success_count, total.count as total_count
        FROM
            (SELECT platform, version, \"decryption_report\".\"is_silent\" as is_silent, count(*) as count
            FROM
                (SELECT \"decryption_report\", \"platform\", MAX(\"version\") as \"version\",
                    MAX(\"timestamp_ms\") as \"timestamp_ms\"
                FROM \"default\".\"client_decryption_report\"
                GROUP BY \"decryption_report\", \"platform\")
                WHERE timestamp_ms >= '", TimestampMsBin/binary, "'
                    AND \"decryption_report\".\"result\"='ok'
                GROUP BY version, \"decryption_report\".\"is_silent\", platform) as success
        JOIN
            (SELECT platform, version, \"decryption_report\".\"is_silent\" as is_silent, count(*) as count
            FROM
                (SELECT \"decryption_report\", \"platform\", MAX(\"version\") as \"version\",
                    MAX(\"timestamp_ms\") as \"timestamp_ms\"
                FROM \"default\".\"client_decryption_report\"
                GROUP BY \"decryption_report\", \"platform\")
                WHERE timestamp_ms >= '", TimestampMsBin/binary, "'
                GROUP BY version, \"decryption_report\".\"is_silent\", platform) as total
        ON success.version=total.version
            AND success.platform=total.platform
            AND success.is_silent=total.is_silent
        ORDER BY success.version DESC;">>,
    #athena_query{
        query_bin = QueryBin,
        tags = #{},
        result_fun = {?MODULE, record_dec_report},
        metrics = ["decryption_report"]
    }.


%% Query gets the decryption report rates with rerequest_count = 0, ordered by version.
%% This query will run on data from TimestampMs till current.
-spec e2e_decryption_report_without_rerequest(TimestampMsBin :: binary()) -> athena_query().
e2e_decryption_report_without_rerequest(TimestampMsBin) ->
    QueryBin = <<"
        SELECT success.platform, success.version, success.is_silent,
            ROUND(success.count * 100.0 / total.count, 2) as success_rate,
            success.count as success_count, total.count as total_count
        FROM
            (SELECT platform, version, \"decryption_report\".\"is_silent\" as is_silent, count(*) as count
            FROM
                (SELECT \"decryption_report\", \"platform\", MAX(\"version\") as \"version\",
                    MAX(\"timestamp_ms\") as \"timestamp_ms\"
                FROM \"default\".\"client_decryption_report\"
                GROUP BY \"decryption_report\", \"platform\")
                WHERE timestamp_ms >= '", TimestampMsBin/binary, "'
                    AND \"decryption_report\".\"result\"='ok'
                    AND \"decryption_report\".\"rerequest_count\"=0
                GROUP BY version, \"decryption_report\".\"is_silent\", platform) as success
        JOIN
            (SELECT platform, version, \"decryption_report\".\"is_silent\" as is_silent, count(*) as count
            FROM
                (SELECT \"decryption_report\", \"platform\", MAX(\"version\") as \"version\",
                    MAX(\"timestamp_ms\") as \"timestamp_ms\"
                FROM \"default\".\"client_decryption_report\"
                GROUP BY \"decryption_report\", \"platform\")
                WHERE timestamp_ms >= '", TimestampMsBin/binary, "'
                GROUP BY version, \"decryption_report\".\"is_silent\", platform) as total
        ON success.version=total.version
            AND success.platform=total.platform
            AND success.is_silent=total.is_silent
        ORDER BY success.version DESC;">>,
    #athena_query{
        query_bin = QueryBin,
        tags = #{},
        result_fun = {?MODULE, record_dec_report},
        metrics = ["decryption_report0"]
    }.


-spec record_enc_and_dec(Query :: athena_query()) -> ok.
record_enc_and_dec(Query) ->
    Result = Query#athena_query.result,
    ResultRows = maps:get(<<"ResultRows">>, maps:get(<<"ResultSet">>, Result)),
    [_HeaderRow | ActualResultRows] = ResultRows,
    TagsAndValues = maps:to_list(Query#athena_query.tags),
    [Metric1, Metric2] = Query#athena_query.metrics,
    lists:foreach(
        fun(ResultRow) ->
            [Version, EncSuccessRateStr, _, DecSuccessRateStr, _] = maps:get(<<"Data">>, ResultRow),
            {EncSuccessRate, <<>>} = string:to_float(EncSuccessRateStr),
            {DecSuccessRate, <<>>} = string:to_float(DecSuccessRateStr),
            stat:count("HA/e2e", Metric1, EncSuccessRate,
                    [{"version", util:to_list(Version)} | TagsAndValues]),
            stat:count("HA/e2e", Metric2, DecSuccessRate,
                    [{"version", util:to_list(Version)} | TagsAndValues])
        end, ActualResultRows),
    ok.


-spec record_dec(Query :: athena_query()) -> ok.
record_dec(Query) ->
    Result = Query#athena_query.result,
    ResultRows = maps:get(<<"ResultRows">>, maps:get(<<"ResultSet">>, Result)),
    [_HeaderRow | ActualResultRows] = ResultRows,
    TagsAndValues = maps:to_list(Query#athena_query.tags),
    [Metric1] = Query#athena_query.metrics,
    lists:foreach(
        fun(ResultRow) ->
            [Version, DecSuccessRateStr, _, _] = maps:get(<<"Data">>, ResultRow),
            {DecSuccessRate, <<>>} = string:to_float(DecSuccessRateStr),
            stat:count("HA/e2e", Metric1, DecSuccessRate,
                    [{"version", util:to_list(Version)} | TagsAndValues])
        end, ActualResultRows),
    ok.


%% TODO(murali@): generalize the result functions
-spec record_dec_report(Query :: athena_query()) -> ok.
record_dec_report(Query) ->
    Result = Query#athena_query.result,
    ResultRows = maps:get(<<"ResultRows">>, maps:get(<<"ResultSet">>, Result)),
    [_HeaderRow | ActualResultRows] = ResultRows,
    TagsAndValues = maps:to_list(Query#athena_query.tags),
    [Metric1] = Query#athena_query.metrics,
    lists:foreach(
        fun(ResultRow) ->
            [Platform, Version, IsSilent, DecSuccessRateStr, _, TotalMsgsStr] = maps:get(<<"Data">>, ResultRow),
            {DecSuccessRate, <<>>} = string:to_float(DecSuccessRateStr),
            stat:count("HA/e2e", Metric1, DecSuccessRate,
                    [{"version", util:to_list(Version)},
                    {"platform", util:to_list(Platform)},
                    {"is_silent", util:to_list(IsSilent)} | TagsAndValues]),
            {TotalMsgs, <<>>} = string:to_float(TotalMsgsStr),
            stat:count("HA/e2e", Metric1 ++ "_count", TotalMsgs,
                    [{"version", util:to_list(Version)},
                    {"platform", util:to_list(Platform)},
                    {"is_silent", util:to_list(IsSilent)} | TagsAndValues])
        end, ActualResultRows),
    ok.

