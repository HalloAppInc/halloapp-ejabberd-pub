%%%-------------------------------------------------------------------
%%% File: stat_opentsdb.erl
%%% copyright (C) 2020, Halloapp Inc.
%%%
%%%
%%%-------------------------------------------------------------------
-module(stat_opentsdb).
-author('murali').

-include("logger.hrl").
-include("time.hrl").
-include("client_version.hrl").
-include("erlcloud_mon.hrl").
-include("erlcloud_aws.hrl").

-define(OPENTSDB_URL, "http://opentsdb1.ha:4242/api/put").
-define(OPENTSDB_TAGS_LIMIT, 8).
-define(MAX_DATAPOINTS_PER_REQUEST, 50).
-define(MACHINE_KEY, <<"machine">>).

-define(REQUEST_TIMEOUT, 30 * ?SECONDS_MS).
-define(CONNECTION_TIMEOUT, 10 * ?SECONDS_MS).

%% Export all functions for unit tests
-ifdef(TEST).
-export([
    convert_metric_to_map/2,
    compose_tags/1
]).
-endif.

%% API
-export([
    put_metrics/2,
    do_send_metrics/2
]).

put_metrics(Metrics, TimestampMs) when is_map(Metrics) ->
    MachineName = util_aws:get_machine_name(),
    put(?MACHINE_KEY, MachineName),
    put_metrics(maps:to_list(Metrics), TimestampMs);
put_metrics(Metrics, TimestampMs) when length(Metrics) > ?MAX_DATAPOINTS_PER_REQUEST ->
    {Part1, Part2} = lists:split(?MAX_DATAPOINTS_PER_REQUEST, Metrics),
    send_metrics(Part1, TimestampMs),
    put_metrics(Part2, TimestampMs);
put_metrics(Metrics, TimestampMs) ->
    send_metrics(Metrics, TimestampMs).


-spec send_metrics(MetricsList :: [], TimestampMs :: integer()) -> ok | {error, any()}.
send_metrics([], _TimestampMs) ->
    ok;
send_metrics(MetricsList, TimestampMs) ->
    case config:is_prod_env() of
        true -> spawn(?MODULE, do_send_metrics, [MetricsList, TimestampMs]);
        false -> ok
    end.

-spec do_send_metrics(MetricsList :: [], TimestampMs :: integer()) -> ok | {error, any()}.
do_send_metrics(MetricsList, TimestampMs) ->
    try
        URL = ?OPENTSDB_URL,
        Headers = [],
        Type = "application/json",
        Body = compose_body(MetricsList, TimestampMs),
        HTTPOptions = [
            {timeout, ?REQUEST_TIMEOUT},
            {connect_timeout, ?CONNECTION_TIMEOUT}
        ],
        Options = [],
        ?DEBUG("URL : ~p, body: ~p", [URL, Body]),
        Response = httpc:request(post, {URL, Headers, Type, Body}, HTTPOptions, Options),
        case Response of
            {ok, {{_, ResCode, _}, _ResHeaders, _ResBody}} when ResCode =:= 200; ResCode =:= 204->
                ok;
            _ ->
                ?ERROR("OpenTSDB error sending metrics: ~p, body: ~p response: ~p",
                    [MetricsList, Body, Response]),
                {error, put_failed}
        end
    catch
        Class : Reason : Stacktrace ->
            ?ERROR("Error: Stacktrace:~s", [lager:pr_stacktrace(Stacktrace, {Class, Reason})]),
            {error, Reason}
    end.


-spec compose_body(MetricsList :: [], TimestampMs :: integer()) -> binary().
compose_body(MetricsList, TimestampMs) ->
    Data = lists:filtermap(
            fun(MetricKeyAndValue) ->
                MetricMap = convert_metric_to_map(MetricKeyAndValue, TimestampMs),
                case maps:size(maps:get(<<"tags">>, MetricMap)) > 0 of
                    true -> {true, MetricMap};
                    false -> false
                end
            end, MetricsList),
    jiffy:encode(Data).


-spec convert_metric_to_map({Key :: tuple(), Value :: statistic_set()},
        TimestampMs :: integer()) -> map().
convert_metric_to_map({Key, Value}, TimestampMs) ->
    {metric, Namespace, Metric, Dimensions, _Unit} = Key,
    TagsAndValues = compose_tags(Dimensions),
    #{
        <<"metric">> => util:to_binary(string:replace(Namespace, "/", ".", all) ++ "." ++ Metric),
        <<"timestamp">> => TimestampMs,
        <<"value">> => Value#statistic_set.sum,
        <<"tags">> => TagsAndValues
    }.


-spec compose_tags(Dimensions :: [#dimension{}]) -> #{}.
compose_tags(Dimensions) ->
    %% Opentsdb does not allow data with zero tags.
    %% So, to always ensure one tag: we add the machine name.
    MachineName = get(?MACHINE_KEY),
    TagsAndValues = lists:foldl(
        fun(#dimension{name = N, value = V}, Acc) ->
            Name = util:to_binary(N),
            Value = util:to_binary(V),
            maps:put(Name, Value, Acc)
        end, #{}, Dimensions),
    case maps:size(TagsAndValues) < ?OPENTSDB_TAGS_LIMIT of
        true ->
            TagsAndValues#{?MACHINE_KEY => MachineName};
        _ ->
            ?ERROR("Too many tags here."),
            #{}
    end.

