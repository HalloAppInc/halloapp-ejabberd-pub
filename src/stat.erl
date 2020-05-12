%%%-------------------------------------------------------------------
%%% @author nikola
%%% @copyright (C) 2020, Halloapp Inc.
%%% @doc
%%%  Monitoring and API for events.
%%% Data is send to AWS CloudWatch custom metrics.
%%% @end
%%% Created : 04. May 2020 4:42 PM
%%%-------------------------------------------------------------------
-module(stat).
-author("nikola").
-behavior(gen_server).
-behavior(gen_mod).

-include("logger.hrl").
-include("erlcloud_mon.hrl").

-export([start_link/0]).
%% gen_mod callbacks
-export([start/2, stop/1, depends/2, mod_options/1]).
%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, terminate/2, handle_info/2, code_change/3]).


%% API
-export([
    count/2,
    count/3
]).

% Trigger funcitons
-export([
    trigger_send/0
]).


start_link() ->
    gen_server:start_link({local, get_proc()}, ?MODULE, [], []).

%%====================================================================
%% gen_mod callbacks
%%====================================================================


start(Host, Opts) ->
    ?INFO_MSG("start ~w", [?MODULE]),
    gen_mod:start_child(?MODULE, Host, Opts, get_proc()),
    ok.


stop(_Host) ->
    ?INFO_MSG("stop ~w", [?MODULE]),
    gen_mod:stop_child(get_proc()),
    ok.


depends(_Host, _Opts) ->
    [].


mod_options(_Host) ->
    [].


get_proc() ->
    gen_mod:get_module_proc(global, ?MODULE).


-spec count(Namespace :: string(), Metric :: string()) -> ok.
count(Namespace, Metric) ->
    count(Namespace, Metric, 1),
    ok.

-spec count(Namespace :: string(), Metric :: string(), Value :: integer()) -> ok.
count(Namespace, Metric, Value) ->
    ?INFO_MSG("Namespace:~s, Metric:~s, Value:~p", [Namespace, Metric, Value]),
    gen_server:cast(get_proc(), {count, Namespace, Metric, Value}).

-spec trigger_send() -> ok.
trigger_send() ->
    gen_server:cast(get_proc(), {trigger_send}).


init(_Stuff) ->
    process_flag(trap_exit, true),
    % TODO: The initial configuration of erlcloud should probably move
    {ok, Config} = erlcloud_aws:auto_config(),
    erlcloud_aws:configure(Config),

    {ok, _Tref} = timer:apply_interval(1000, ?MODULE, trigger_send, []),
    CurrentMinute = util:round_to_minute(util:now()),
    {ok, #{minute => CurrentMinute}}.


handle_call(_Message, _From, State) ->
    ?ERROR_MSG("unexpected call ~p from ", _Message),
    {reply, ok, State}.


handle_cast({count, Namespace, Metric, Value}, State) ->
    NewState1 = maybe_rotate_data(State),
    DataPoint = make_statistic_set(Value),
    Key = make_key(Namespace, Metric, "Count"),
    NewState2 = update_state(Key, DataPoint, NewState1),
    {noreply, NewState2};


handle_cast({trigger_send}, State) ->
    NewState = maybe_rotate_data(State),
    {noreply, NewState};

handle_cast(_Message, State) -> {noreply, State}.


handle_info(_Message, State) -> {noreply, State}.
terminate(_Reason, _State) -> ok.
code_change(_OldVersion, State, _Extra) -> {ok, State}.


-spec maybe_rotate_data(State :: map()) -> map().
maybe_rotate_data(State) ->
    MinuteNow = util:round_to_minute(util:now()),
    CurrentMinute = maps:get(minute, State, MinuteNow),
    case CurrentMinute == MinuteNow of
        true ->
            State;
        false ->
            send_data(State),
            #{minute => MinuteNow}
    end.


-spec send_data(MetricsMap :: map()) -> ok.
send_data(MetricsMap) when is_map(MetricsMap) ->
    {TimeSeconds, MetricsMap2} = maps:take(minute, MetricsMap),
    Data = prepare_data(MetricsMap2, TimeSeconds * 1000),
    send_to_cloudwatch(Data).


-spec send_to_cloudwatch(Data :: map()) -> ok.
send_to_cloudwatch(Data) when is_map(Data) ->
    ?INFO_MSG("sending ~p Namespaces", [maps:size(Data)]),
    maps:map(
        fun (Namespace, Metrics) ->
            ?DEBUG("~s ~p", [Namespace, length(Metrics)]),
            cloudwatch_put_metric_data(Namespace, Metrics)
        end, Data),
    ok.

-spec cloudwatch_put_metric_data(Namespace :: string(), Metrics :: [metric_datum()]) -> ok.
cloudwatch_put_metric_data(Namespace, Metrics)
        when is_list(Namespace), is_list(Metrics)->
    try erlcloud_mon:put_metric_data(Namespace, Metrics) of
        {error, Reason} ->
            ?ERROR_MSG("failed ~s ~w Reason: ~p",
                [Namespace, length(Metrics), Reason]);
        _Result ->
            ?DEBUG("success ~s ~w", [Namespace, length(Metrics)])
    catch
        Class:Reason:Stacktrace ->
            ?ERROR_MSG("~nStacktrace:~s",
                [lager:pr_stacktrace(Stacktrace, {Class, Reason})])
    end.

-spec prepare_data(MetricsMap :: map(), TimestampMs :: non_neg_integer()) -> map().
prepare_data(MetricsMap, TimestampMs)
        when is_map(MetricsMap), is_integer(TimestampMs) ->
    maps:fold(
        fun (K, V, Ac) ->
            {metric, Namespace, Metric, Unit} = K,
            M = #metric_datum{
                metric_name = Metric,
                dimensions = [],
                statistic_values = V,
                timestamp = convert_time(TimestampMs),
                unit = Unit,
                value = undefined
            },
            MetricsList = maps:get(Namespace, Ac, []),
            maps:put(Namespace, [M | MetricsList], Ac)
        end, #{}, MetricsMap).

% O M G converting time 4 ways
-spec convert_time(TimestampMs :: non_neg_integer()) -> calendar:datetime1970().
convert_time(TimestampMs) ->
    Seconds = TimestampMs div 1000,
    TS = {Seconds div 1000000, Seconds rem 1000000, 0},
    calendar:now_to_datetime(TS).

-spec merge(A :: statistic_set(), B :: statistic_set()) -> statistic_set().
merge(A, B) ->
    #statistic_set{
        sample_count = A#statistic_set.sample_count + B#statistic_set.sample_count,
        sum = A#statistic_set.sum + B#statistic_set.sum,
        maximum = erlang:max(A#statistic_set.maximum, B#statistic_set.maximum),
        minimum = erlang:min(A#statistic_set.minimum, B#statistic_set.minimum)
    }.


make_statistic_set(Value) when is_integer(Value) ->
    make_statistic_set(float(Value));
make_statistic_set(Value) when is_float(Value) ->
    #statistic_set{
        sample_count = 1,
        sum = Value,
        maximum = Value,
        minimum = Value
    }.


make_key(Namespace, Metric, Unit) ->
    {metric, Namespace, Metric, Unit}.


-spec update_state(Key :: term(), DataPoint :: statistic_set(), State :: map()) -> map().
update_state(Key, DataPoint, State) ->
    CurrentDP = maps:get(Key, State, undefined),
    case CurrentDP of
        undefined -> maps:put(Key, DataPoint, State);
        _ ->
            NewDP = merge(CurrentDP, DataPoint),
            maps:put(Key, NewDP, State)
    end.
