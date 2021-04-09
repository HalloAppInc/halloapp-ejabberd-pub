%%%-------------------------------------------------------------------
%%% File: athena_queries.erl
%%% copyright (C) 2021, HalloApp, Inc.
%%%
%%% Module with all athena queries.
%%%
%%%-------------------------------------------------------------------
-module(athena_queries).
-author('murali').

-export([
    e2e_success_failure_rates_query/2,
    e2e_decryption_reason_rates_query/2,
    e2e_decryption_report_query/2,
    e2e_decryption_report_without_rerequest_query/2
]).

%%====================================================================
%% encryption queries
%%====================================================================

%% Query gets the encryption and decryption success rates ordered by version and total number
%% of messages for both encryption and decryption.
%% This query will run on a specific platform and on data from TimestampMs till current.
-spec e2e_success_failure_rates_query(Platform :: binary(), TimestampMsBin :: binary()) -> binary().
e2e_success_failure_rates_query(Platform, TimestampMsBin) ->
    Query = <<"
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
    Query.


%% Query gets the decryption error rates ordered by version and the error reason.
%% Also has the number of messages for each of the error reasons.
%% This query will run on a specific platform and on data from TimestampMs till current.
-spec e2e_decryption_reason_rates_query(Platform :: binary(), TimestampMs :: binary()) -> binary().
e2e_decryption_reason_rates_query(Platform, TimestampMsBin) ->
    Query = <<"
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
    Query.


%% Query gets the decryption report rates ordered by version.
%% This query will run on a specific platform and on data from TimestampMs till current.
-spec e2e_decryption_report_query(Platform :: binary(), TimestampMsBin :: binary()) -> binary().
e2e_decryption_report_query(Platform, TimestampMsBin) ->
    Query = <<"
        SELECT success.version, ROUND(success.count * 100.0 / total.count, 2) as success_rate,
            success.count as success_count, total.count as total_count
    FROM
        (SELECT version, count(*) as count
        FROM
            (SELECT \"decryption_report\", \"platform\", MAX(\"version\") as \"version\",
                MAX(\"timestamp_ms\") as \"timestamp_ms\"
            FROM \"default\".\"client_decryption_report\"
            GROUP BY \"decryption_report\", \"platform\")
        WHERE platform='", Platform/binary, "' AND \"timestamp_ms\" >= '", TimestampMsBin/binary, "'
            AND \"decryption_report\".\"result\"='ok'
        GROUP BY version) as success
        JOIN
        (SELECT version, count(*) as count
        FROM
            (SELECT \"decryption_report\", \"platform\", MAX(\"version\") as \"version\",
                MAX(\"timestamp_ms\") as \"timestamp_ms\"
            FROM \"default\".\"client_decryption_report\"
            GROUP BY \"decryption_report\", \"platform\")
        WHERE platform='", Platform/binary, "' AND \"timestamp_ms\" >= '", TimestampMsBin/binary, "'
        GROUP BY version) as total on success.version=total.version;">>,
    Query.


%% Query gets the decryption report rates with rerequest_count = 0, ordered by version.
%% This query will run on a specific platform and on data from TimestampMs till current.
-spec e2e_decryption_report_without_rerequest_query(Platform :: binary(), TimestampMs :: binary()) -> binary().
e2e_decryption_report_without_rerequest_query(Platform, TimestampMs) ->
    Query = <<"
        SELECT success.version, ROUND(success.count * 100.0 / total.count, 2) as success_rate,
            success.count as success_count, total.count as total_count
    FROM
        (SELECT version, count(*) as count
        FROM
            (SELECT \"decryption_report\", \"platform\", MAX(\"version\") as \"version\",
                MAX(\"timestamp_ms\") as \"timestamp_ms\"
            FROM \"default\".\"client_decryption_report\"
            GROUP BY \"decryption_report\", \"platform\")
        WHERE platform='", Platform/binary, "' AND \"timestamp_ms\" >= '", TimestampMs/binary, "'
            AND \"decryption_report\".\"result\"='ok' AND \"decryption_report\".\"rerequest_count\"=0
        GROUP BY version) as success
        JOIN
        (SELECT version, count(*) as count
        FROM
            (SELECT \"decryption_report\", \"platform\", MAX(\"version\") as \"version\",
                MAX(\"timestamp_ms\") as \"timestamp_ms\"
            FROM \"default\".\"client_decryption_report\"
            GROUP BY \"decryption_report\", \"platform\")
        WHERE platform='", Platform/binary, "' AND \"timestamp_ms\" >= '", TimestampMs/binary, "'
        GROUP BY version) as total on success.version=total.version;">>,
    Query.

