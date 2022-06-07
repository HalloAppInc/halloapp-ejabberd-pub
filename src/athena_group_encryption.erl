%%%-------------------------------------------------------------------
%%% File: athena_group_encryption.erl
%%% copyright (C) 2021, HalloApp, Inc.
%%%
%%% Module with all athena group encryption queries.
%%% TODO(murali@): add more queries about comment vs post enc/dec-success rate.
%%%-------------------------------------------------------------------
-module(athena_group_encryption).
-behavior(athena_query).
-author('murali').

-include("time.hrl").
-include("athena_query.hrl").

-export([
    %% callback for behavior function.
    get_queries/0,

    %% query functions for debug!
    e2e_success_failure_rates/2,
    e2e_decryption_reason_rates/2,
    e2e_decryption_report/1,
    e2e_decryption_report_7day/1,
    e2e_decryption_report_without_rerequest/1
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
        e2e_decryption_report_7day(QueryTimeMsBin),
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
                FROM \"default\".\"client_crypto_group_encryption\"
                    where platform='", Platform/binary, "' AND result='ok' AND \"timestamp_ms\" >= '", TimestampMsBin/binary, "'
                    GROUP BY version) as success
            JOIN
                (SELECT version, SUM(cast(count AS REAL)) as count
                FROM \"default\".\"client_crypto_group_encryption\"
                    where platform='", Platform/binary, "' AND \"timestamp_ms\" >= '", TimestampMsBin/binary, "'
                    GROUP BY version) as total
                on success.version=total.version) as enc_success
        JOIN
            (SELECT success.version, ROUND(success.count * 100 / total.count, 2) as success_rate, total.count as total_count
            FROM
                (SELECT version, SUM(cast(count AS REAL)) as count
                FROM \"default\".\"client_crypto_group_decryption\"
                    where platform='", Platform/binary, "' AND result='ok' AND \"timestamp_ms\" >= '", TimestampMsBin/binary, "'
                    GROUP BY version) as success
            JOIN
                (SELECT version, SUM(cast(count AS REAL)) as count
                FROM \"default\".\"client_crypto_group_decryption\"
                    where platform='", Platform/binary, "' AND \"timestamp_ms\" >= '", TimestampMsBin/binary, "'
                    GROUP BY version) as total  on success.version=total.version) as dec_success
        on enc_success.version=dec_success.version
        ORDER BY enc_success.version DESC;">>,
    #athena_query{
        query_bin = QueryBin,
        tags = #{"platform" => util:to_list(Platform)},
        result_fun = {athena_e2e_results, record_enc_and_dec},
        metrics = ["group_encryption_rate", "group_decryption_rate"]
    }.


%% Query gets the decryption error rates ordered by version and the error reason.
%% Also has the number of messages for each of the error reasons.
%% This query will run on a specific platform and on data from TimestampMs till current.
-spec e2e_decryption_reason_rates(Platform :: binary(), TimestampMs :: binary()) -> athena_query().
e2e_decryption_reason_rates(Platform, TimestampMsBin) ->
    QueryBin = <<"
        SELECT reason.version, reason.failure_reason,
            ROUND(reason.count * 100.0 / total.count, 2) as reason_rate,
            reason.count as reason_count, total.count as total_count
        FROM
            (SELECT version, failure_reason, SUM(cast(count AS INTEGER)) as count
            FROM \"default\".\"client_crypto_group_decryption\"
                where platform='", Platform/binary, "' AND result!='ok' AND \"timestamp_ms\" >= '", TimestampMsBin/binary, "'
                GROUP BY version, failure_reason) as reason
            JOIN
            (SELECT version, SUM(cast(count AS INTEGER)) as count
            FROM \"default\".\"client_crypto_group_decryption\"
                where platform='", Platform/binary, "' AND result!='ok' AND \"timestamp_ms\" >= '", TimestampMsBin/binary, "'
                GROUP BY version) as total  on reason.version=total.version
        ORDER BY reason.version DESC, reason.count DESC;">>,
    #athena_query{
        query_bin = QueryBin,
        tags = #{"platform" => Platform},
        result_fun = undefined
    }.


%% Query gets the decryption report rates ordered by version.
%% This query will run on data from TimestampMs till current.
-spec e2e_decryption_report(TimestampMsBin :: binary()) -> athena_query().
e2e_decryption_report(TimestampMsBin) ->
    QueryBin = <<"
        SELECT success.platform, success.version,
            ROUND(success.count * 100.0 / total.count, 2) as success_rate,
            success.count as success_count, total.count as total_count
        FROM
            (SELECT platform, version, count(*) as count
            FROM
                (SELECT \"group_decryption_report\", \"platform\", MAX(\"version\") as \"version\",
                    MAX(\"timestamp_ms\") as \"timestamp_ms\"
                FROM \"default\".\"client_group_decryption_report\"
                WHERE \"group_decryption_report\".\"time_taken_s\" <= 86400
                GROUP BY \"group_decryption_report\", \"platform\")
                WHERE timestamp_ms >= '", TimestampMsBin/binary, "'
                    AND \"group_decryption_report\".\"result\"='ok'
                GROUP BY version, platform) as success
        JOIN
            (SELECT platform, version, count(*) as count
            FROM
                (SELECT \"group_decryption_report\", \"platform\", MAX(\"version\") as \"version\",
                    MAX(\"timestamp_ms\") as \"timestamp_ms\"
                FROM \"default\".\"client_group_decryption_report\"
                WHERE \"group_decryption_report\".\"time_taken_s\" <= 86400
                GROUP BY \"group_decryption_report\", \"platform\")
                WHERE timestamp_ms >= '", TimestampMsBin/binary, "'
                    AND \"group_decryption_report\".\"reason\" != 'contentMissing'
                    AND \"group_decryption_report\".\"reason\" != 'content_missing'
                GROUP BY version, platform) as total
        ON success.version=total.version
            AND success.platform=total.platform
        ORDER BY success.version DESC;">>,
    #athena_query{
        query_bin = QueryBin,
        tags = #{},
        result_fun = {athena_e2e_results, record_dec_report},
        metrics = ["group_decryption_report"]
    }.


%% Query gets the decryption report rates ordered by version.
%% This query will run on data from TimestampMs till current.
-spec e2e_decryption_report_7day(TimestampMsBin :: binary()) -> athena_query().
e2e_decryption_report_7day(TimestampMsBin) ->
    QueryBin = <<"
        SELECT success.platform, success.version,
            ROUND(success.count * 100.0 / total.count, 2) as success_rate,
            success.count as success_count, total.count as total_count
        FROM
            (SELECT platform, version, count(*) as count
            FROM
                (SELECT \"group_decryption_report\", \"platform\", MAX(\"version\") as \"version\",
                    MAX(\"timestamp_ms\") as \"timestamp_ms\"
                FROM \"default\".\"client_group_decryption_report\"
                WHERE \"group_decryption_report\".\"time_taken_s\" <= 604800
                GROUP BY \"group_decryption_report\", \"platform\")
                WHERE timestamp_ms >= '", TimestampMsBin/binary, "'
                    AND \"group_decryption_report\".\"result\"='ok'
                GROUP BY version, platform) as success
        JOIN
            (SELECT platform, version, count(*) as count
            FROM
                (SELECT \"group_decryption_report\", \"platform\", MAX(\"version\") as \"version\",
                    MAX(\"timestamp_ms\") as \"timestamp_ms\"
                FROM \"default\".\"client_group_decryption_report\"
                WHERE \"group_decryption_report\".\"time_taken_s\" <= 604800
                GROUP BY \"group_decryption_report\", \"platform\")
                WHERE timestamp_ms >= '", TimestampMsBin/binary, "'
                    AND \"group_decryption_report\".\"reason\" != 'contentMissing'
                    AND \"group_decryption_report\".\"reason\" != 'content_missing'
                GROUP BY version, platform) as total
        ON success.version=total.version
            AND success.platform=total.platform
        ORDER BY success.version DESC;">>,
    #athena_query{
        query_bin = QueryBin,
        tags = #{},
        result_fun = {athena_e2e_results, record_dec_report},
        metrics = ["group_decryption_report_7day"]
    }.


%% Query gets the decryption report rates with rerequest_count = 0, ordered by version.
%% This query will run on data from TimestampMs till current.
-spec e2e_decryption_report_without_rerequest(TimestampMsBin :: binary()) -> athena_query().
e2e_decryption_report_without_rerequest(TimestampMsBin) ->
    QueryBin = <<"
        SELECT success.platform, success.version,
            ROUND(success.count * 100.0 / total.count, 2) as success_rate,
            success.count as success_count, total.count as total_count
        FROM
            (SELECT platform, version, count(*) as count
            FROM
                (SELECT \"group_decryption_report\", \"platform\", MAX(\"version\") as \"version\",
                    MAX(\"timestamp_ms\") as \"timestamp_ms\"
                FROM \"default\".\"client_group_decryption_report\"
                GROUP BY \"group_decryption_report\", \"platform\")
                WHERE timestamp_ms >= '", TimestampMsBin/binary, "'
                    AND \"group_decryption_report\".\"result\"='ok'
                    AND \"group_decryption_report\".\"rerequest_count\"=0
                GROUP BY version, platform) as success
        JOIN
            (SELECT platform, version, count(*) as count
            FROM
                (SELECT \"group_decryption_report\", \"platform\", MAX(\"version\") as \"version\",
                    MAX(\"timestamp_ms\") as \"timestamp_ms\"
                FROM \"default\".\"client_group_decryption_report\"
                GROUP BY \"group_decryption_report\", \"platform\")
                WHERE timestamp_ms >= '", TimestampMsBin/binary, "'
                    AND \"group_decryption_report\".\"reason\" != 'contentMissing'
                    AND \"group_decryption_report\".\"reason\" != 'content_missing'
                GROUP BY version, platform) as total
        ON success.version=total.version
            AND success.platform=total.platform
        ORDER BY success.version DESC;">>,
    #athena_query{
        query_bin = QueryBin,
        tags = #{},
        result_fun = {athena_e2e_results, record_dec_report},
        metrics = ["group_decryption_report0"]
    }.

