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
    convert_metric_to_map/3,
    compose_tags/2
]).
-endif.

%% API
-export([
    put_metrics/2,
    do_send_request/1,
    put/1
]).

-type datapoint() :: #{
    metric := binary(),
    timestamp := integer(),
    value := integer() | float(),
    tags := map()
}.

put_metrics(Metrics, TimestampMs) when is_map(Metrics) ->
    MachineName = util_aws:get_machine_name(),
    put_metrics(maps:to_list(Metrics), TimestampMs, MachineName).

put_metrics(Metrics, TimestampMs, MachineName) when length(Metrics) > ?MAX_DATAPOINTS_PER_REQUEST ->
    {Part1, Part2} = lists:split(?MAX_DATAPOINTS_PER_REQUEST, Metrics),
    send_metrics(Part1, TimestampMs, MachineName),
    put_metrics(Part2, TimestampMs, MachineName);
put_metrics(Metrics, TimestampMs, MachineName) ->
    send_metrics(Metrics, TimestampMs, MachineName).


-spec send_metrics(MetricsList :: [], TimestampMs :: integer(), MachineName :: binary())
            -> ok | {error, any()}.
send_metrics([], _TimestampMs, _MachineName) ->
    ok;
send_metrics(MetricsList, TimestampMs, MachineName) ->
    try
        send_request(compose_body(MetricsList, TimestampMs, MachineName))
    catch
        Class : Reason : Stacktrace ->
            ?ERROR("Error:~s", [lager:pr_stacktrace(Stacktrace, {Class, Reason})]),
            {error, Reason}
    end.

-spec put(DataPoints :: list(datapoint())) -> ok | {error, any()}.
put([]) ->
    ok;
put(DataPoints) ->
    try
        {NowList, LaterList} = lists:split(
            min(?MAX_DATAPOINTS_PER_REQUEST, length(DataPoints)),
            DataPoints),
        send_request(jiffy:encode(NowList)),
        put(LaterList)
    catch
        Class : Reason : Stacktrace ->
            ?ERROR("Error:~s", [lager:pr_stacktrace(Stacktrace, {Class, Reason})]),
            {error, Reason}
    end.


-spec send_request(Body :: binary()) -> ok.
send_request(Body) ->
    case config:is_prod_env() of
        true ->
            spawn(?MODULE, do_send_request, [Body]),
            ok;
        false -> ok
    end.

do_send_request(Body) ->
    try
        URL = ?OPENTSDB_URL,
        Headers = [],
        Type = "application/json",
        Body = Body,
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
                ?ERROR("OpenTSDB error sending, body: ~p response: ~p",
                    [Body, Response]),
                {error, put_failed}
        end
    catch
        Class : Reason : Stacktrace ->
            ?ERROR("Error: Stacktrace:~s", [lager:pr_stacktrace(Stacktrace, {Class, Reason})]),
            {error, Reason}
    end.


-spec compose_body(MetricsList :: [], TimestampMs :: integer(), MachineName :: binary()) -> binary().
compose_body(MetricsList, TimestampMs, MachineName) ->
    Data = lists:filtermap(
            fun(MetricKeyAndValue) ->
                MetricMap = convert_metric_to_map(MetricKeyAndValue, TimestampMs, MachineName),
                case maps:size(maps:get(<<"tags">>, MetricMap)) > 0 of
                    true -> {true, MetricMap};
                    false -> false
                end
            end, MetricsList),
    jiffy:encode(Data).


-spec convert_metric_to_map({Key :: tuple(), Value :: statistic_set()},
        TimestampMs :: integer(), MachineName :: binary()) -> map().
convert_metric_to_map({Key, Value}, TimestampMs, MachineName) ->
    {metric, Namespace, Metric, Dimensions, _Unit} = Key,
    TagsAndValues = compose_tags(Dimensions, MachineName),
    #{
        <<"metric">> => util:to_binary(string:replace(Namespace, "/", ".", all) ++ "." ++ Metric),
        <<"timestamp">> => TimestampMs,
        <<"value">> => Value#statistic_set.sum,
        <<"tags">> => TagsAndValues
    }.


-spec compose_tags(Dimensions :: [#dimension{}], MachineName :: binary()) -> #{}.
compose_tags(Dimensions, MachineName) ->
    %% Opentsdb does not allow data with zero tags.
    %% So, to always ensure one tag: we add the machine name.
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
            ?ERROR("Too many tags here ~p", [TagsAndValues]),
            #{}
    end.
