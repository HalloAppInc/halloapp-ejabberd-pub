%%%-------------------------------------------------------------------
%%% File: athena_media.erl
%%% copyright (C) 2021, HalloApp, Inc.
%%%
%%% Module with all athena media_upload, media_download queries.
%%%
%%%-------------------------------------------------------------------
-module(athena_media).
-behavior(athena_query).
-author(nikola).

-include("time.hrl").
-include("athena_query.hrl").

%% All query functions must end with query.
-export([
    %% callback for behavior function.
    get_queries/0,
    backfill/3,
    backfill_all/0
]).

%%====================================================================
%% mod_athena_stats callback
%%====================================================================

get_queries() ->
    Yesterday = util:yesterday(),
    [
        media_upload_status_query(Yesterday),
        media_download_status_query(Yesterday),
        media_upload_timing_all_query(Yesterday),
        media_upload_timing_by_platform_query(Yesterday),
        media_download_timing_all_query(Yesterday),
        media_download_timing_by_platform_query(Yesterday)
    ].

-spec backfill(QueryFun, FromDate, ToDate) -> ok when
    QueryFun :: fun((calendar:date()) -> athena_query()),
    FromDate :: calendar:date(),
    ToDate :: calendar:date().
backfill(QueryFun, FromDate, ToDate)
        when FromDate > ToDate ->
    ok;
backfill(QueryFun, FromDate, ToDate)  ->
    DayBefore = util:day_before(ToDate),
    mod_athena_stats:run_query(QueryFun(ToDate)),
    backfill(QueryFun, FromDate, DayBefore).

backfill_all() ->
    FromDate = {2021, 05, 01},
    ToDate = {2021, 07, 19},
    Funcs = [
        fun media_upload_status_query/1,
        fun media_download_status_query/1,
        fun media_upload_timing_all_query/1,
        fun media_upload_timing_by_platform_query/1,
        fun media_download_timing_all_query/1,
        fun media_download_timing_by_platform_query/1
    ],
    [backfill(F, FromDate, ToDate) || F <- Funcs].

%%====================================================================
%% media queries
%%====================================================================

%% Counts uploads by Platform, Version and Status
-spec media_upload_status_query(calendar:date()) -> athena_query().
media_upload_status_query({_Year, Month, Date}) ->
    MonthBin = iolist_to_binary(io_lib:format("~2.2.0w", [Month])),
    DateBin = iolist_to_binary(io_lib:format("~2.2.0w", [Date])),
    QueryBin = <<"
    SELECT (min(cast(timestamp_ms AS bigint)) / (24*60*60*1000)) * 24*60*60 AS timestamp,
            platform,
            version,
            media_upload.status AS status,
            count(*) AS value
    FROM default.client_media_upload
    WHERE month='", MonthBin/binary, "'AND date='", DateBin/binary, "'
    GROUP BY  platform, version, media_upload.status
    ORDER BY  platform, version, media_upload.status;
    ">>,
    #athena_query{
        query_bin = QueryBin,
        result_fun = {athena_results, send_to_opentsdb},
        metrics = {"HA", "media_upload.status"}
    }.

%% Counts downloads by Platform, Version and Status
-spec media_download_status_query(calendar:date()) -> athena_query().
media_download_status_query({_Year, Month, Date}) ->
    MonthBin = iolist_to_binary(io_lib:format("~2.2.0w", [Month])),
    DateBin = iolist_to_binary(io_lib:format("~2.2.0w", [Date])),
    QueryBin = <<"
    SELECT (min(cast(timestamp_ms AS bigint)) / (24*60*60*1000)) * 24*60*60 AS timestamp,
            platform,
            version,
            media_download.status AS status,
            count(*) AS value
    FROM default.client_media_download
    WHERE month='", MonthBin/binary, "'AND date='", DateBin/binary, "'
    GROUP BY  platform, version, media_download.status
    ORDER BY  platform, version, media_download.status;
    ">>,
    #athena_query{
        query_bin = QueryBin,
        result_fun = {athena_results, send_to_opentsdb},
        metrics = {"HA" , "media_download.status"}
    }.


media_download_timing_by_platform_query({_Year, Month, Date}) ->
    MonthBin = iolist_to_binary(io_lib:format("~2.2.0w", [Month])),
    DateBin = iolist_to_binary(io_lib:format("~2.2.0w", [Date])),
    QueryBin = <<"
    SELECT platform,
         (min(cast(timestamp_ms AS bigint)) / (24*60*60*1000)) * 24*60*60 AS timestamp,
         approx_percentile(media_download.duration_ms, 0.5) AS p50,
         approx_percentile(media_download.duration_ms, 0.75) AS p75,
         approx_percentile(media_download.duration_ms, 0.90) AS p90,
         approx_percentile(media_download.duration_ms, 0.95) AS p95,
         approx_percentile(media_download.duration_ms, 0.99) AS p99
    FROM \"default\".\"client_media_download\"
    WHERE month='", MonthBin/binary, "'AND date='", DateBin/binary, "'
        AND media_download.status='ok'
    GROUP BY  platform;
    ">>,
    #athena_query{
        query_bin = QueryBin,
        result_fun = {athena_results, percentile},
        metrics = {"HA" , "media_download.timing_by_platform"}
    }.


media_download_timing_all_query({_Year, Month, Date}) ->
    MonthBin = iolist_to_binary(io_lib:format("~2.2.0w", [Month])),
    DateBin = iolist_to_binary(io_lib:format("~2.2.0w", [Date])),
    QueryBin = <<"
    SELECT 'all' as platform,
         (min(cast(timestamp_ms AS bigint)) / (24*60*60*1000)) * 24*60*60 AS timestamp,
         approx_percentile(media_download.duration_ms, 0.5) AS p50,
         approx_percentile(media_download.duration_ms, 0.75) AS p75,
         approx_percentile(media_download.duration_ms, 0.90) AS p90,
         approx_percentile(media_download.duration_ms, 0.95) AS p95,
         approx_percentile(media_download.duration_ms, 0.99) AS p99
    FROM \"default\".\"client_media_download\"
    WHERE month='", MonthBin/binary, "'AND date='", DateBin/binary, "'
        AND media_download.status='ok';
    ">>,
    #athena_query{
        query_bin = QueryBin,
        result_fun = {athena_results, percentile},
        metrics = {"HA" , "media_download.timing"}
    }.


media_upload_timing_by_platform_query({_Year, Month, Date}) ->
    MonthBin = iolist_to_binary(io_lib:format("~2.2.0w", [Month])),
    DateBin = iolist_to_binary(io_lib:format("~2.2.0w", [Date])),
    QueryBin = <<"
    SELECT platform,
         (min(cast(timestamp_ms AS bigint)) / (24*60*60*1000)) * 24*60*60 AS timestamp,
         approx_percentile(media_upload.duration_ms, 0.5) AS p50,
         approx_percentile(media_upload.duration_ms, 0.75) AS p75,
         approx_percentile(media_upload.duration_ms, 0.90) AS p90,
         approx_percentile(media_upload.duration_ms, 0.95) AS p95,
         approx_percentile(media_upload.duration_ms, 0.99) AS p99
    FROM \"default\".\"client_media_upload\"
    WHERE month='", MonthBin/binary, "'AND date='", DateBin/binary, "'
        AND media_upload.status='ok'
    GROUP BY  platform;
    ">>,
    #athena_query{
        query_bin = QueryBin,
        result_fun = {athena_results, percentile},
        metrics = {"HA" , "media_upload.timing_by_platform"}
    }.


media_upload_timing_all_query({_Year, Month, Date}) ->
    MonthBin = iolist_to_binary(io_lib:format("~2.2.0w", [Month])),
    DateBin = iolist_to_binary(io_lib:format("~2.2.0w", [Date])),
    QueryBin = <<"
    SELECT 'all' as platform,
         (min(cast(timestamp_ms AS bigint)) / (24*60*60*1000)) * 24*60*60 AS timestamp,
         approx_percentile(media_upload.duration_ms, 0.5) AS p50,
         approx_percentile(media_upload.duration_ms, 0.75) AS p75,
         approx_percentile(media_upload.duration_ms, 0.90) AS p90,
         approx_percentile(media_upload.duration_ms, 0.95) AS p95,
         approx_percentile(media_upload.duration_ms, 0.99) AS p99
    FROM \"default\".\"client_media_upload\"
    WHERE month='", MonthBin/binary, "'AND date='", DateBin/binary, "'
        AND media_upload.status='ok';
    ">>,
    #athena_query{
        query_bin = QueryBin,
        result_fun = {athena_results, percentile},
        metrics = {"HA" , "media_upload.timing"}
    }.

