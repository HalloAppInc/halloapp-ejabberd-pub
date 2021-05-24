-module(mod_retention).
-author(nikola).

-behaviour(gen_mod).

-include("logger.hrl").
-include("time.hrl").
-include("ha_types.hrl").
-include("account.hrl").

%% gen_mod API.
-export([start/2, stop/1, reload/3, mod_options/1, depends/2]).

% API
-export([
    compute_retention/0,
    dump_accounts/0,
    dump_accounts_run/2
]).


start(_Host, _Opts) ->
    ?INFO("starting", []),
    case util_aws:get_machine_name() of
        <<"s-test">> ->
            application:ensure_all_started(erlcron),
            % TODO: change this one to {weekly, mon, {9, am}} when it works well
            erlcron:cron(dump_accounts, {
                {daily, {9, 25, pm}},
                {?MODULE, dump_accounts, []}
            }),

            erlcron:cron(weekly_retention, {
                {weekly, mon, {11, am}},
                {?MODULE, compute_retention, []}
            });
        _ -> ok
    end,
    ok.


stop(_Host) ->
    ?INFO("stopping", []),
    case util_aws:get_machine_name() of
        <<"s-test">> ->
            erlcron:cancel(dump_accounts),
            erlcron:cancel(weekly_retention);
        _ -> ok
    end,
    ok.


reload(_Host, _NewOpts, _OldOpts) ->
    ok.

% TODO: models should not be modules
depends(_Host, _Opts) ->
    [{model_accounts, hard}].


mod_options(_Host) ->
    [].

-spec compute_retention() -> ok.
compute_retention() ->
    ?INFO("computing retention"),
    % TODO: implement. Run some athena query
    ok.


-spec dump_accounts() -> ok.
dump_accounts() ->
    redis_migrate:start_migration("Dump accounts to log", redis_accounts,
        {?MODULE, dump_accounts_run}, [{dry_run, false}]),
    ok.


-spec dump_accounts_run(Key :: binary(), State :: map()) -> map().
dump_accounts_run(Key, State) ->
    Result = re:run(Key, "^acc:{([0-9]+)}$", [global, {capture, all, binary}]),
    case Result of
        {match, [[_FullKey, Uid]]} ->
            dump_account(Uid);
        _ -> ok
    end,
    State.


-spec dump_account(Uid :: uid()) -> ok.
dump_account(Uid) ->
    try
        ?INFO("Account uid: ~p", [Uid]),
        {ok, Account} = model_accounts:get_account(Uid),
        CC = mod_libphonenumber:get_cc(Account#account.phone),
        mod_client_log:log_event(<<"server.accounts">>, #{
            uid => Account#account.uid,
            creation_ts_ms => Account#account.creation_ts_ms,
            last_activity => Account#account.last_activity_ts_ms,
            signup_version => Account#account.signup_user_agent,
            signup_platform => util_ua:get_client_type(Account#account.signup_user_agent),
            cc => CC
        }),
        ok
    catch
        Class : Reason : St ->
            ?ERROR("failed to dump account to log: ~p", lager:pr(St, {Class, Reason}))
    end.
