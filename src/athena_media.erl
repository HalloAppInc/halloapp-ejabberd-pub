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
    get_queries/0
]).

%%====================================================================
%% mod_athena_stats callback
%%====================================================================

get_queries() ->
    Yesterday = util:yesterday(),
    [
        media_upload_status_query(Yesterday),
        media_download_status_query(Yesterday)
    ].


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
    FROM default.client_download_upload
    WHERE month='", MonthBin/binary, "'AND date='", DateBin/binary, "'
    GROUP BY  platform, version, media_download.status
    ORDER BY  platform, version, media_download.status;
    ">>,
    #athena_query{
        query_bin = QueryBin,
        result_fun = {athena_results, send_to_opentsdb},
        metrics = {"HA" , "media_download.status"}
    }.

