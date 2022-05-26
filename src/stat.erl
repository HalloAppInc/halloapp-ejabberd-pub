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
-include("client_version.hrl").
-include("proc.hrl").
-include("sms.hrl").

-export([start_link/0]).
%% gen_mod callbacks
-export([start/2, stop/1, depends/2, mod_options/1]).
%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, terminate/2, handle_info/2, code_change/3]).


%% API
-export([
    count/2,
    count/3,
    count/4,
    gauge/3,
    gauge/4,
    reload_aws_config/0,
    get_aws_config/0,
    send_to_cloudwatch/1
]).

% Trigger funcitons
-export([
    trigger_send/0,
    trigger_count_users/0,
    trigger_count_sessions/0,
    trigger_zset_cleanup/0,
    trigger_count_users_by_version/0,
    trigger_count_users_by_os_version/0,
    trigger_count_users_by_langid/0,
    trigger_check_sms_reg/1,
    compute_counts_by_version/0,
    compute_counts_by_os_version/0,
    compute_counts_by_langid/0,
    compute_counts/0
]).

-type tag_value() :: atom() | string() | binary().
-type tag() :: {Name :: atom(), Value :: tag_value()}.
-type tags() :: [tag()].

-define(SMS_REG_CHECK_INCREMENTS, 1).

-export_type([
    tag/0,
    tags/0,
    tag_value/0
]).

start_link() ->
    gen_server:start_link({local, ?PROC()}, ?MODULE, [], []).

%%====================================================================
%% gen_mod callbacks
%%====================================================================


start(Host, Opts) ->
    ?INFO("start ~w", [?MODULE]),
    gen_mod:start_child(?MODULE, Host, Opts, ?PROC()),
    ok.


stop(_Host) ->
    ?INFO("stop ~w", [?MODULE]),
    gen_mod:stop_child(?PROC()),
    ok.


depends(_Host, _Opts) ->
    [].


mod_options(_Host) ->
    [].


-spec count(Namespace :: string(), Metric :: string()) -> ok.
count(Namespace, Metric) ->
    count(Namespace, Metric, 1),
    ok.


-spec count(Namespace :: string(), Metric :: string(), Value :: integer()) -> ok.
count(Namespace, Metric, Value) ->
    count(Namespace, Metric, Value, []).


-spec count(Namespace :: string(), Metric :: string(), Value :: integer(), Tags :: [tag()]) -> ok.
count(Namespace, Metric, Value, Tags) when is_atom(Metric) ->
    ?WARNING("Metric is supposed to be list: ~p ~p", [Metric, Namespace]),
    count(Namespace, atom_to_list(Metric), Value, Tags);
count(Namespace, Metric, Value, Tags) when is_list(Metric) ->
    gen_server:cast(?PROC(), {count, Namespace, Metric, Value, Tags}).


-spec gauge(Namespace :: string(), Metric :: string(), Value :: integer()) -> ok.
gauge(Namespace, Metric, Value) ->
    gauge(Namespace, Metric, Value, []).


% Used for metrics that can go up or down, like number of groups.
% When new call is made for the same metric new value is stored.
-spec gauge(Namespace :: string(), Metric :: string(), Value :: integer(), Tags :: [tag()]) -> ok.
gauge(Namespace, Metric, Value, Tags) when is_atom(Metric) ->
    ?WARNING("Metric is supposed to be list: ~p ~p", [Metric, Namespace]),
    gauge(Namespace, atom_to_list(Metric), Value, Tags);
gauge(Namespace, Metric, Value, Tags) ->
    gen_server:cast(?PROC(), {gauge, Namespace, Metric, Value, Tags}).

reload_aws_config() ->
    gen_server:call(?PROC(), {reload_aws_config}).

get_aws_config() ->
    gen_server:call(?PROC(), {get_aws_config}).


-spec trigger_send() -> ok.
trigger_send() ->
    gen_server:cast(?PROC(), {trigger_send}).

% TODO: this logic should move to new module mod_counters
-spec trigger_count_users() -> ok.
trigger_count_users() ->
    spawn(?MODULE, compute_counts, []).

-spec trigger_count_sessions() -> ok.
trigger_count_sessions() ->
    %% Add counters for total number of connections on the machine.
    gauge("HA/connections", "total_sessions", ejabberd_sm:ets_count_sessions(), []),
    gauge("HA/connections", "total_active_sessions", ejabberd_sm:ets_count_active_sessions(), []),
    gauge("HA/connections", "total_passive_sessions", ejabberd_sm:ets_count_passive_sessions(), []),
    ok.

-spec trigger_count_users_by_version() -> ok.
trigger_count_users_by_version() ->
    spawn(?MODULE, compute_counts_by_version, []).

-spec trigger_count_users_by_os_version() -> ok.
trigger_count_users_by_os_version() ->
    spawn(?MODULE, compute_counts_by_os_version, []).

-spec trigger_count_users_by_langid() -> ok.
trigger_count_users_by_langid() ->
    spawn(?MODULE, compute_counts_by_langid, []).

-spec trigger_check_sms_reg(TimeInterval :: atom()) -> ok.
trigger_check_sms_reg(TimeInterval) ->
    spawn(stat_sms, check_sms_reg, [TimeInterval]).

% TODO: this logic should move to new module mod_active_users
-spec trigger_zset_cleanup() -> ok.
trigger_zset_cleanup() ->
    _Pid = spawn(model_active_users, cleanup, []).

compute_counts() ->
    Start = util:now_ms(),
    ?INFO("start", []),
    CountAccounts = model_accounts:count_accounts(),
    ?INFO("Number of accounts: ~p", [CountAccounts]),
    stat:gauge("HA/account", "total_accounts", CountAccounts),
    CountRegistrations = model_accounts:count_registrations(),
    ?INFO("Number of registrations: ~p", [CountRegistrations]),
    stat:gauge("HA/account", "total_registrations", CountRegistrations),

    % groups
    CountGroups = model_groups:count_groups(),
    ?INFO("Number of groups: ~p", [CountGroups]),
    stat:gauge("HA/groups", "total_groups", CountGroups),

    % active_users
    ok = mod_active_users:compute_counts(),

    % engaged_users
    ok = mod_engaged_users:compute_counts(),

    End = util:now_ms(),
    ?INFO("Counting took ~p ms", [End - Start]),
    ok.


compute_counts_by_version() ->
    ?INFO("Version counts start"),
    Start = util:now_ms(),
    NowSec = util:now(),
    VersionExpiry = ?VERSION_VALIDITY,
    DeadlineSec = NowSec - VersionExpiry,
    {ok, AllVersions} = model_client_version:get_all_versions(),
    {ok, ValidVersions} = model_client_version:get_versions(DeadlineSec, NowSec),
    ValidVersionsMap = maps:from_list(lists:map(fun(V) -> {V, 1} end, ValidVersions)),

    VersionCountsMap = model_accounts:count_version_keys(),
    lists:foreach(
        fun(Version) ->
            CountsByVersion = maps:get(Version, VersionCountsMap, 0),
            Platform = util_ua:get_client_type(Version),
            IsValid = maps:is_key(Version, ValidVersionsMap),
            stat:gauge("HA/client_version", "all_users", CountsByVersion,
                    [{version, Version}, {platform, Platform}, {valid, IsValid}])
        end, AllVersions),
    End = util:now_ms(),
    ?INFO("Counting took ~p ms", [End - Start]),
    ok.


compute_counts_by_os_version() ->
    ?INFO("OS Version Count start"),
    Start = util:now_ms(),
    OsVersionsMap = model_accounts:count_os_version_keys(),
    maps:fold(
        fun(Version, Count, Acc) ->
            % ios versions contain a period
            Platform = case lists:member($., binary_to_list(Version)) of
                true -> ios;
                false -> android
            end,
            stat:gauge("HA/os_version", "all_users", Count, [{version, Version}, {platform, Platform}]),
            Acc
        end, #{}, OsVersionsMap),
    End = util:now_ms(),
    ?INFO("Counting took ~p ms", [End - Start]),
    ok.


compute_counts_by_langid() ->
    ?INFO("LangId counts start"),
    Start = util:now_ms(),

    LangCountsMap = model_accounts:count_lang_keys(),
    LangCountsList = maps:to_list(LangCountsMap),
    lists:foreach(
        fun({LangId, Count}) ->
            stat:gauge("HA/lang_id", "all_users", Count, [{lang_id, LangId}])
        end, LangCountsList),

    End = util:now_ms(),
    ?INFO("Counting took ~p ms", [End - Start]),
    ok.


init(_Stuff) ->
    % Each Erlang process has to do the configure
    % TODO: maybe make module where this erlcloud configure should go
    {ok, Config} = erlcloud_aws:auto_config(),
    erlcloud_aws:configure(Config),
    %% TODO(vipin): Move the background jobs in a different module.
    {ok, _Tref1} = timer:apply_interval(1 * ?SECONDS_MS, ?MODULE, trigger_send, []),
    {ok, _} = timer:apply_interval(10 * ?SECONDS_MS, ?MODULE, trigger_count_sessions, []),
    case util:get_machine_name() of
        <<"s-test">> ->
            {ok, _Tref2} = timer:apply_interval(5 * ?MINUTES_MS, ?MODULE, trigger_count_users, []),
            {ok, _Tref3} = timer:apply_interval(10 * ?MINUTES_MS, ?MODULE, trigger_zset_cleanup, []),
            {ok, _Tref4} = timer:apply_interval(2 * ?HOURS_MS, ?MODULE, trigger_count_users_by_version, []),
            {ok, _Tref5} = timer:apply_interval(1 * ?HOURS_MS, mod_athena_stats, run_athena_queries, []),
            {ok, _Tref6} = timer:apply_interval(15 * ?MINUTES_MS, ?MODULE, trigger_check_sms_reg, [recent]),
            {ok, _Tref7} = timer:apply_interval(4 * ?HOURS_MS, ?MODULE, trigger_check_sms_reg, [past]),
            {ok, _Tref8} = timer:apply_interval(2 * ?HOURS_MS, ?MODULE, trigger_count_users_by_langid, []),
            {ok, _Tref9} = timer:apply_interval(1 * ?HOURS_MS, ?MODULE, trigger_count_users_by_os_version, []);
        _ ->
            ok
    end,
    CurrentMinute = util:round_to_minute(util:now()),
    % minute is unix timestamp that always represents round minute for which the data is being
    % accumulated
    % agg_map is map of metrics for CloudWatch
    {ok, #{minute => CurrentMinute, agg_map => #{}}}.

handle_call({reload_aws_config}, _From, State) ->
    {ok, Config} = erlcloud_aws:auto_config(),
    ?INFO("Refreshing aws config ~p ~p ~p ~p",
        [Config#aws_config.access_key_id, Config#aws_config.secret_access_key,
            Config#aws_config.security_token, Config#aws_config.expiration]),
    erlcloud_aws:configure(Config),
    {reply, Config, State};

handle_call({get_aws_config}, _From, State) ->
    Config = erlcloud_aws:default_config(),
    ?INFO("Aws config ~p ~p ~p ~p",
        [Config#aws_config.access_key_id, Config#aws_config.secret_access_key,
            Config#aws_config.security_token, Config#aws_config.expiration]),
    {reply, Config, State};

handle_call(_Message, _From, State) ->
    ?ERROR("unexpected call ~p from ", _Message),
    {reply, ok, State}.


handle_cast({count, Namespace, Metric, Value, Tags}, State) ->
    NewState = count_internal(State, Namespace, Metric, Value, Tags),
    {noreply, NewState};

handle_cast({gauge, Namespace, Metric, Value, Tags}, State) ->
    NewState = gauge_internal(State, Namespace, Metric, Value, Tags),
    {noreply, NewState};

handle_cast({trigger_send}, State) ->
    NewState = maybe_rotate_data(State),
    {noreply, NewState};

handle_cast({ping, Id, Ts, From}, State) ->
    util_monitor:send_ack(self(), From, {ack, Id, Ts, self()}),
    {noreply, State};

handle_cast(_Message, State) ->
    {noreply, State}.


handle_info(_Message, State) -> {noreply, State}.
terminate(_Reason, _State) -> ok.
code_change(_OldVersion, State, _Extra) -> {ok, State}.

count_internal(State, Namespace, Metric, Value, Tags) ->
    process_count_internal(State, Namespace, Metric, Value, Tags, merge).

gauge_internal(State, Namespace, Metric, Value, Tags) ->
    process_count_internal(State, Namespace, Metric, Value, Tags, replace).

process_count_internal(State, Namespace, Metric, Value, Tags, Type) ->
    NewState1 = maybe_rotate_data(State),
    try
        DataPoint = make_statistic_set(Value),
        Tags1 = fix_tags(Tags),
        Key = make_key(Namespace, Metric, Tags1, "Count"),
        #{agg_map := AggMap} = NewState1,
        AggMap1 = update_state(Key, DataPoint, AggMap, Type),
        NewState1#{agg_map => AggMap1}
    catch
        error : {badtagvalue, V} ->
            ?ERROR("Invalid Tags value: ~p: ~p:~p ~p", [V, Namespace, Metric, Tags]),
            NewState1;
        error : {badtagname, N} ->
            ?ERROR("Invalid Tags name: ~p: ~p:~p ~p", [N, Namespace, Metric, Tags]),
            NewState1
    end.


-spec maybe_rotate_data(State :: map()) -> map().
maybe_rotate_data(State) ->
    MinuteNow = util:round_to_minute(util:now()),
    CurrentMinute = maps:get(minute, State, MinuteNow),
    case CurrentMinute == MinuteNow of
        true ->
            State;
        false ->
            #{minute := TimeSeconds, agg_map := AggMap} = State,
            send_data(TimeSeconds, AggMap),
            % after we send the data to CloudWatch we reset the agg_map.
            State#{minute => MinuteNow, agg_map => #{}}
    end.


-spec send_data(TimeSeconds :: integer(), MetricsMap :: map()) -> ok.
send_data(TimeSeconds, MetricsMap) when is_map(MetricsMap) ->
    TimeMilliSeconds = TimeSeconds * ?SECONDS_MS,
    Data = prepare_data(MetricsMap, TimeMilliSeconds),
    CloudwatchPid = spawn(?MODULE, send_to_cloudwatch, [Data]),
    OpenTsdbPid = spawn(stat_opentsdb, put_metrics, [MetricsMap, TimeMilliSeconds]),
    ?INFO("Spawned processes to send stats. Cloudwatch: ~p, OpenTSDB: ~p",
        [CloudwatchPid, OpenTsdbPid]),
    ok.


-spec send_to_cloudwatch(Data :: map()) -> ok.
send_to_cloudwatch(Data) when is_map(Data) ->
    maps:fold(
        fun (Namespace, Metrics, _Acc) ->
            cloudwatch_put_metric_data(Namespace, Metrics)
        end,
        ok,
        Data),
    ok.


-spec cloudwatch_put_metric_data(EnvNamespace :: string(), Metrics :: [metric_datum()]) -> ok.
cloudwatch_put_metric_data(Namespace, Metrics)
        when is_list(Namespace), is_list(Metrics), length(Metrics) > 20 ->
    % CloudWatch wants no more the 20 metrics in the same request
    {M1, M2} = lists:split(20, Metrics),
    cloudwatch_put_metric_data(Namespace, M1),
    cloudwatch_put_metric_data(Namespace, M2);
cloudwatch_put_metric_data(Namespace, Metrics)
        when is_list(Namespace), is_list(Metrics)->
    cloudwatch_put_metric_data_env(config:get_hallo_env(), Namespace, Metrics).


cloudwatch_put_metric_data_env(prod, Namespace, Metrics) ->
    try
        ?DEBUG("~s ~p", [Namespace, length(Metrics)]),
        erlcloud_mon:put_metric_data(Namespace, Metrics)
    of
        {error, Reason} ->
            ?ERROR("failed ~s ~w Reason: ~p",
                [Namespace, length(Metrics), Reason]);
        _Result ->
            ?DEBUG("success ~s ~w", [Namespace, length(Metrics)])
    catch
        Class:Reason:Stacktrace ->
            ?ERROR("Failed to send to CloudWatch NS: ~p M: ~p Stacktrace:~s",
                [Namespace, Metrics, lager:pr_stacktrace(Stacktrace, {Class, Reason})])
    end;
cloudwatch_put_metric_data_env(localhost, "HA/test" = Namespace, Metrics) ->
    ?INFO("would send: ~s metrics: ~p", [Namespace, Metrics]),
    erlcloud_mon:put_metric_data(Namespace, Metrics);
cloudwatch_put_metric_data_env(_Env, _Namespace, _Metrics) ->
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


make_key(Namespace, Metric, Tags, Unit) ->
    Dims = [#dimension{name = N, value = V} || {N, V} <- Tags],
    {metric, Namespace, Metric, Dims, Unit}.


-spec update_state(Key :: term(), DataPoint :: statistic_set(),
        State :: map(), Action :: merge | replace) -> map().
update_state(Key, DataPoint, State, Action) ->
    CurrentDP = maps:get(Key, State, undefined),
    case CurrentDP of
        undefined -> maps:put(Key, DataPoint, State);
        _ ->
            NewDP = case Action of
                merge -> merge(CurrentDP, DataPoint);
                replace -> DataPoint
            end,
            maps:put(Key, NewDP, State)
    end.


% make sure tags are strings
-spec fix_tags(Tags :: [tag()]) -> [tag()].
fix_tags(Tags) ->
    lists:sort([fix_tag(T) || T <- Tags]).


-spec fix_tag(Tag :: tag()) -> tag().
fix_tag({Name, Value})  ->
    {fix_tag_name(Name), fix_tag_value(Value)}.

fix_tag_value(Value) when is_atom(Value); is_list(Value);
        is_binary(Value); is_integer(Value) ->
    StrValue = util:to_list(Value),
    case string:find(StrValue, " ") of
        nomatch -> ok;
        _ ->
            ?ERROR("Tag Value has spaces |~p|", [Value]),
            error({badtagvalue, Value})
    end,
    StrValue;
fix_tag_value(V) ->
    error({badtagvalue, V}).


fix_tag_name(Name) when is_atom(Name); is_list(Name) ->
    util:to_list(Name);
fix_tag_name(Name) ->
    error({badtagname, Name}).

