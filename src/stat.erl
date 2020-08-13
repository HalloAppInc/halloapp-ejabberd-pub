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
-include("time.hrl").
-include("erlcloud_mon.hrl").
-include("erlcloud_aws.hrl").

-export([start_link/0]).
%% gen_mod callbacks
-export([start/2, stop/1, depends/2, mod_options/1]).
%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, terminate/2, handle_info/2, code_change/3]).


%% API
-export([
    count/2,
    count/3,
    count_d/3,
    count_d/4
]).

% Trigger funcitons
-export([
    trigger_send/0,
    trigger_count_users/0,
    trigger_zset_cleanup/0,
    compute_counts/0
]).

-type tag_value() :: atom() | string() | binary().
-type tag() :: {Name :: atom(), Value :: tag_value()}.

-export_type([
    tag/0,
    tag_value/0
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
    ?DEBUG("Namespace:~s, Metric:~s, Value:~p", [Namespace, Metric, Value]),
    gen_server:cast(get_proc(), {count, Namespace, Metric, Value}).

-spec count_d(Namespace :: string(), Metric :: string(), Tags :: [tag()]) -> ok.
count_d(Namespace, Metric, Tags) ->
    count_d(Namespace, Metric, 1, Tags).

-spec count_d(Namespace :: string(), Metric :: string(), Value :: integer(), Tags :: [tag()]) -> ok.
count_d(Namespace, Metric, Value, Tags) ->
    ?DEBUG("Namesapce:~s, Metric:~s Tags:~p", [Namespace, Metric, Tags]),
    Tags1 = fix_tags(Tags),
    Tags2 = [#dimension{name = N, value = V} || {N, V} <- Tags1],
    gen_server:cast(get_proc(), {count_d, Namespace, Metric, Value, Tags2}).

-spec trigger_send() -> ok.
trigger_send() ->
    gen_server:cast(get_proc(), {trigger_send}).

% TODO: this logic should move to new module mod_counters
-spec trigger_count_users() -> ok.
trigger_count_users() ->
    spawn(?MODULE, compute_counts, []).

% TODO: this logic should move to new module mod_active_users
-spec trigger_zset_cleanup() -> ok.
trigger_zset_cleanup() ->
    _Pid = spawn(model_active_users, cleanup, []).

compute_counts() ->
    Start = util:now_ms(),
    ?INFO_MSG("start", []),
    CountAccounts = model_accounts:count_accounts(),
    ?INFO_MSG("Number of accounts: ~p", [CountAccounts]),
    stat:count("HA/account", "total_accounts", CountAccounts),
    CountRegistrations = model_accounts:count_registrations(),
    ?INFO_MSG("Number of registrations: ~p", [CountRegistrations]),
    stat:count("HA/account", "total_registrations", CountRegistrations),
    ok = mod_active_users:compute_counts(),
    End = util:now_ms(),
    ?INFO_MSG("Counting took ~p ms", [End - Start]),
    ok.


init(_Stuff) ->
    process_flag(trap_exit, true),
    % TODO: The initial configuration of erlcloud should probably move
    {ok, _} = application:ensure_all_started(erlcloud),
    {ok, Config} = erlcloud_aws:auto_config(),
    erlcloud_aws:configure(Config),
    {ok, _Tref1} = timer:apply_interval(1 * ?SECONDS_MS, ?MODULE, trigger_send, []),
    {ok, _Tref2} = timer:apply_interval(5 * ?MINUTES_MS, ?MODULE, trigger_count_users, []),
    {ok, _Tref3} = timer:apply_interval(10 * ?MINUTES_MS, ?MODULE, trigger_zset_cleanup, []),
    CurrentMinute = util:round_to_minute(util:now()),
    {ok, #{minute => CurrentMinute}}.


handle_call(_Message, _From, State) ->
    ?ERROR_MSG("unexpected call ~p from ", _Message),
    {reply, ok, State}.


handle_cast({count, Namespace, Metric, Value}, State) ->
    NewState = count_internal(State, Namespace, Metric, Value, []),
    {noreply, NewState};

handle_cast({count_d, Namespace, Metric, Value, Tags}, State) ->
    NewState = count_internal(State, Namespace, Metric, Value, Tags),
    {noreply, NewState};

handle_cast({trigger_send}, State) ->
    NewState = maybe_rotate_data(State),
    {noreply, NewState};

handle_cast(_Message, State) -> {noreply, State}.


handle_info(_Message, State) -> {noreply, State}.
terminate(_Reason, _State) -> ok.
code_change(_OldVersion, State, _Extra) -> {ok, State}.

count_internal(State, Namespace, Metric, Value, Tags) ->
    NewState1 = maybe_rotate_data(State),
    DataPoint = make_statistic_set(Value),
    Key = make_key(Namespace, Metric, Tags, "Count"),
    NewState2 = update_state(Key, DataPoint, NewState1),
    NewState2.


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
    Data = prepare_data(MetricsMap2, TimeSeconds * ?SECONDS_MS),
    send_to_cloudwatch(Data).


-spec send_to_cloudwatch(Data :: map()) -> ok.
send_to_cloudwatch(Data) when is_map(Data) ->
    ?INFO_MSG("sending ~p Namespaces", [maps:size(Data)]),
    update_aws_config(),
    maps:fold(
        fun (Namespace, Metrics, _Acc) ->
            ?DEBUG("~s ~p", [Namespace, length(Metrics)]),
            cloudwatch_put_metric_data(Namespace, Metrics)
        end,
        ok,
        Data),
    ok.


-spec cloudwatch_put_metric_data(EnvNamespace :: string(), Metrics :: [metric_datum()]) -> ok.
cloudwatch_put_metric_data(Namespace, Metrics)
        when is_list(Namespace), is_list(Metrics)->
    cloudwatch_put_metric_data_env(config:get_hallo_env(), Namespace, Metrics).


cloudwatch_put_metric_data_env(prod, Namespace, Metrics) ->
    try
        erlcloud_mon:put_metric_data(Namespace, Metrics)
    of
        {error, Reason} ->
            ?ERROR_MSG("failed ~s ~w Reason: ~p",
                [Namespace, length(Metrics), Reason]);
        _Result ->
            ?DEBUG("success ~s ~w", [Namespace, length(Metrics)])
    catch
        Class:Reason:Stacktrace ->
            ?ERROR_MSG("Stacktrace:~s",
                [lager:pr_stacktrace(Stacktrace, {Class, Reason})])
    end;
cloudwatch_put_metric_data_env(localhost, "HA/test" = Namespace, Metrics) ->
    ?DEBUG("would send: ~s metrics: ~p", [Namespace, Metrics]),
    erlcloud_mon:put_metric_data(Namespace, Metrics);
cloudwatch_put_metric_data_env(_Env, Namespace, Metrics) ->
    ?DEBUG("would send: ~s metrics: ~p", [Namespace, Metrics]).


-spec update_aws_config() -> ok.
update_aws_config() ->
    try
        C = erlcloud_aws:default_config(),
        ?DEBUG("key_id:~s expiration:~p", [C#aws_config.access_key_id, C#aws_config.expiration]),
        update_aws_config(C)
    catch
        Class:Reason:Stacktrace ->
            ?ERROR_MSG("Stacktrace:~s",
                [lager:pr_stacktrace(Stacktrace, {Class, Reason})])
    end.


% TODO: delete this code if our change in erlcloud auto refreshing works
-spec update_aws_config(Config :: aws_config()) -> ok.
update_aws_config(#aws_config{access_key_id = _AccessKeyId, expiration = undefined}) ->
    ok;
update_aws_config(#aws_config{access_key_id = AccessKeyId, expiration = Expiration}) ->
    Now = util:now(),
    ExpiresIn = Expiration - Now,
    %% Tokens are usually expire in 3h, refresh the token if it expires in less then 5 minutes
    %% Also refresh the token if somehow the times is too much in the future.
    %% (Maybe the clock was off)
    case (ExpiresIn < 2 * ?MINUTES) or (ExpiresIn > 1 * ?DAYS) of
        false -> ok;
        true ->
            ?ERROR_MSG("erlcloud update_config failed to refresh our tokens: "
                "AccessKeyId: ~s Expiration: ~p", [AccessKeyId, Expiration]),
            %% This gets a new config with refreshed tokens
            {ok, NewConfig0} = erlcloud_aws:auto_config(),
            %% Debug code to force early expiration
            NewConfig = NewConfig0#aws_config{expiration = util:now() + 600},
            NewAccessKeyId = NewConfig#aws_config.access_key_id,
            NewExpiration = NewConfig#aws_config.expiration,
            erlcloud_aws:configure(NewConfig),
            ?INFO_MSG("refreshed aws config id:~p exp:~p new_id:~p exp:~p",
                [AccessKeyId, Expiration, NewAccessKeyId, NewExpiration])
    end,
    ok.

-spec prepare_data(MetricsMap :: map(), TimestampMs :: non_neg_integer()) -> map().
prepare_data(MetricsMap, TimestampMs)
        when is_map(MetricsMap), is_integer(TimestampMs) ->
    maps:fold(
        fun (K, V, Ac) ->
            {metric, Namespace, Metric, Dimensions, Unit} = K,
            M = #metric_datum{
                metric_name = Metric,
                dimensions = Dimensions,
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
    Seconds = TimestampMs div ?SECONDS_MS,
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


make_key(Namespace, Metric, Dimensions, Unit) ->
    {metric, Namespace, Metric, Dimensions, Unit}.


-spec update_state(Key :: term(), DataPoint :: statistic_set(), State :: map()) -> map().
update_state(Key, DataPoint, State) ->
    CurrentDP = maps:get(Key, State, undefined),
    case CurrentDP of
        undefined -> maps:put(Key, DataPoint, State);
        _ ->
            NewDP = merge(CurrentDP, DataPoint),
            maps:put(Key, NewDP, State)
    end.


% make sure tag values are atoms
-spec fix_tags(Tags :: [tag()]) -> [tag()].
fix_tags(Tags) ->
    [fix_tag(T) || T <- Tags].


-spec fix_tag(Tag :: tag()) -> tag().
fix_tag({Name, Value} = T) when is_atom(Value); is_list(Value); is_binary(Value) ->
    {Name, util:to_atom(Value)};
fix_tag(_) ->
    error(badarg).

