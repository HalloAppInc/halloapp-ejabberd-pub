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
-define(MAX_DATAPOINTS_PER_REQUEST, 50).
-define(MACHINE_KEY, <<"machine">>).

%% API
-export([
    put_metrics/2
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
        true -> do_send_metrics(MetricsList, TimestampMs);
        false -> ok
    end.

-spec do_send_metrics(MetricsList :: [], TimestampMs :: integer()) -> ok | {error, any()}.
do_send_metrics(MetricsList, TimestampMs) ->
    URL = ?OPENTSDB_URL,
    Headers = [],
    Type = "application/json",
    Body = compose_body(MetricsList, TimestampMs),
    HTTPOptions = [],
    Options = [],
    ?DEBUG("URL : ~p, body: ~p", [URL, Body]),
    Response = httpc:request(post, {URL, Headers, Type, Body}, HTTPOptions, Options),
    case Response of
        {ok, {{_, ResCode, _}, _ResHeaders, _ResBody}} when ResCode =:= 200; ResCode =:= 204->
            ok;
        _ ->
            ?ERROR("Failed to send metrics: ~p, body: ~p response: ~p", [MetricsList, Body, Response]),
            {error, put_failed}
    end.


-spec compose_body(MetricsList :: [], TimestampMs :: integer()) -> binary().
compose_body(MetricsList, TimestampMs) ->
    Data = lists:map(
        fun({Key, Value}) ->
            {metric, Namespace, Metric, Dimensions, _Unit} = Key,
            TagsAndValues = compose_tags(Dimensions),
            #{
                <<"metric">> => util:to_binary(string:replace(Namespace, "/", ".", all) ++ "." ++ Metric),
                <<"timestamp">> => TimestampMs,
                <<"value">> => Value#statistic_set.sum,
                <<"tags">> => TagsAndValues
            }
        end, MetricsList),
    jiffy:encode(Data).


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
    TagsAndValues#{?MACHINE_KEY => MachineName}.

