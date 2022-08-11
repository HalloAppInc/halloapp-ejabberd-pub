-ifndef(MONITOR_HRL).
-define(MONITOR_HRL, 1).

-include("time.hrl").

-define(MONITOR_TABLE, ha_monitor).
-define(HTTP_TABLE, mod_http_checker).
-define(NOISE_LOGIN_TABLE, mod_noise_checker_login).
-define(NOISE_REGISTER_TABLE, mod_noise_checker_register).
-define(REDIS_TABLE, mod_redis_checker).

-define(MONITOR_GEN_SERVER, {global, ejabberd_monitor:get_registered_name()}).

-define(NS, "HA/monitoring").

-type fail_state() :: fail.
-type alive_state() :: ok.
-type proc_state() :: alive_state() | fail_state().
-type opts() :: [monitor_opt()].
-type monitor_opt() ::
    {ping_interval_ms, non_neg_integer()} |
    {state_history_length_ms, non_neg_integer()} |
    {consec_fail_threshold, non_neg_integer()} |
    {half_fail_threshold_ms, non_neg_integer()} |
    {ping_timeout_ms, non_neg_integer()} |
    {remonitor_delay_ms, non_neg_integer()}.

-define(ALIVE_STATE, ok).
-define(FAIL_STATE, fail).

-record(state, {
    monitors :: maps:map(),
    active_pings :: maps:map(),
    gen_servers :: [atom()],
    trefs :: [timer:tref()]
}).

%%====================================================================
%% Configurables
%%====================================================================

% processes are pinged every PING_INTERVAL_MS ms
-define(PING_INTERVAL_MS, (5 * ?SECONDS_MS)).
-define(NOISE_PING_INTERVAL_MS, (10 * ?SECONDS_MS)).

% save recent process states for STATE_HISTORY_LENGTH_MS seconds
% actual history saved will be between STATE_HISTORY_LENGTH_MS and (2 * STATE_HISTORY_LENGTH)
-define(STATE_HISTORY_LENGTH_MS, (10 * ?MINUTES_MS)).

% if there are CONSECUTIVE_FAILURE_THRESHOLD failures in a row, trigger an alert
-define(CONSECUTIVE_FAILURE_THRESHOLD,
    case config:is_testing_env() of
        true -> 3;          % smaller value so tests run faster
        false -> 8          % prod value
    end).

% if there are >= 50% fails for HALF_FAILURE_THRESHOLD_MS minutes, trigger an alert
-define(HALF_FAILURE_THRESHOLD_MS, (2 * ?MINUTES_MS)).

% a process will fail the ping if it takes longer than PING_TIMEOUT_MS to reply
-define(PING_TIMEOUT_MS,
    case config:is_testing_env() of
        true -> 50;  % ms             % shorter timeout so tests run faster
        false -> (5 * ?SECONDS_MS)      % prod timeout
    end).
-define(NOISE_PING_TIMEOUT_MS, (10 * ?SECONDS_MS)).

% if a process goes down, attempt to remonitor it after REMONITOR_DELAY_MS
-define(REMONITOR_DELAY_MS,
    case config:is_testing_env() of
        true -> 50;   % ms      % shorter delay so tests run faster
        false -> 500  % ms      % prod value
    end).

% length (in chars) of the id attached to each ping
-define(ID_LENGTH, 16).

-define(ATOM_CHECK_INTERVAL_MS, 1 * ?HOURS_MS).
-define(ATOM_LIMIT, 1048576).

-define(C2S_SIZE_CHECK_INTERVAL_MS, 1 * ?HOURS_MS).

-define(IAM_CHECK_INTERVAL_MS, (10 * ?MINUTES_MS)).

-define(MONITOR_PHONE, <<"16175551234">>).
-define(TEST_NAME, <<"NoiseRegisterTest">>).
-define(NOISE_LOGIN_PORT, 5222).
-define(NOISE_REGISTER_PORT,5208).

-endif.

