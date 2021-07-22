%%%-------------------------------------------------------------------
%%% @author nikola
%%% @copyright (C) 2021, HalloAppInc
%%% @doc
%%% Generic functions to log athena table results to opentsdb.
%%% Tables must have 2 special colums "timestamp" and "value" all other colums
%%% are treated as tags
%%% @end
%%% Created : 22. Jun 2021 2:22 PM
%%%-------------------------------------------------------------------
-module(athena_results).
-author("nikola").

-include("logger.hrl").
-include("athena_query.hrl").

-define(TIMESTAMP_CN, <<"timestamp">>).
-define(VALUE_CN, <<"value">>).

-define(PERCENTILE_COLUMNS, [<<"p50">>, <<"p75">>, <<"p90">>, <<"p95">>, <<"p99">>]).

%% API
-export([
    send_to_opentsdb/1,
    percentiles/1,
    percentile/1
]).

% Generic function to transform table to OpenTSDB points.
% Table must have 2 special colums: timestamp and value.
% All other colums are treated as tags, where the tag name is
% the column name and the tag value is the value.
-spec send_to_opentsdb(Query :: athena_query()) -> ok.
send_to_opentsdb(Query) ->
    Result = Query#athena_query.result,
    ResultRows = maps:get(<<"ResultRows">>, maps:get(<<"ResultSet">>, Result)),
    [HeaderRow | ActualResultRows] = ResultRows,
    {NS, Metric} = Query#athena_query.metrics,
    Namespace =  string:replace(NS, "/", ".", all),
    FullMetric = util:to_binary(Namespace ++ "." ++ Metric),

    TsdbPoints = lists:map(
        fun(DataRow) ->
            Data = parse_data(maps:get(<<"Data">>, HeaderRow), maps:get(<<"Data">>, DataRow)),
            Value = maps:get(?VALUE_CN, Data),
            Timestamp = maps:get(?TIMESTAMP_CN, Data),
            Tags = maps:remove(?VALUE_CN, maps:remove(?TIMESTAMP_CN, Data)),
            #{
                metric =>  FullMetric,
                timestamp => Timestamp,
                value => Value,
                tags => Tags
            }
        end,
        ActualResultRows
    ),
    lists:foreach(
        fun(X) ->
            % maybe remove this later
            ?INFO("put ~p", [X])
        end, TsdbPoints),
    stat_opentsdb:put(TsdbPoints),
    ok.


% Generic function to transform table to OpenTSDB points.
% Table must have 2 special colums: timestamp and value.
% All other colums are treated as tags, where the tag name is
% the column name and the tag value is the value.
-spec percentiles(Query :: athena_query()) -> ok.
percentiles(Query) ->
    percentile(Query).

-spec percentile(Query :: athena_query()) -> ok.
percentile(Query) ->
    Result = Query#athena_query.result,
    ResultRows = maps:get(<<"ResultRows">>, maps:get(<<"ResultSet">>, Result)),
    [HeaderRow | ActualResultRows] = ResultRows,
    {NS, Metric} = Query#athena_query.metrics,
    Namespace =  string:replace(NS, "/", ".", all),
    FullMetric = util:to_binary(Namespace ++ "." ++ Metric),

    TsdbPoints = lists:map(
        fun(DataRow) ->
            Data = parse_data(maps:get(<<"Data">>, HeaderRow), maps:get(<<"Data">>, DataRow)),
            Timestamp = maps:get(?TIMESTAMP_CN, Data),
            Tags =  maps:without([?VALUE_CN, ?TIMESTAMP_CN | ?PERCENTILE_COLUMNS], Data),
            lists:filtermap(
                fun (Percentile) ->
                    Value = maps:get(Percentile, Data, undefined),
                    case Value of
                        undefined -> false;
                        _ ->
                            Tags2 = maps:put(<<"percentile">>,  Percentile, Tags),
                            {true, #{
                                metric =>  FullMetric,
                                timestamp => Timestamp,
                                value => Value,
                                tags => Tags2
                            }}
                    end
                end, ?PERCENTILE_COLUMNS)
        end,
        ActualResultRows
    ),
    TsdbPoints2 = lists:flatten(TsdbPoints),
    lists:foreach(
        fun(X) ->
            % maybe remove this later
            ?INFO("put ~p", [X])
        end, TsdbPoints2),
    stat_opentsdb:put(TsdbPoints2),
    ok.


-spec parse_data(Headers :: list(), Data :: list()) -> map().
parse_data(Headers, Data) ->
    maps:from_list(lists:zip(Headers, Data)).
