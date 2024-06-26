-module(mod_retention).
-author(nikola).

-behaviour(gen_mod).

-include("logger.hrl").
-include("time.hrl").
-include("ha_types.hrl").
-include("account.hrl").
-include("athena_query.hrl").

-define(NUM_INACTIVE_DAYS, 31).

%% gen_mod API.
-export([start/2, stop/1, reload/3, mod_options/1, depends/2]).

% API
-export([
    schedule/0,
    unschedule/0,
    compute_retention/0,
    dump_accounts/0,
    dump_accounts_run/2,
    dump_account/1,  %% for testing
    weekly_user_retention_result/1
]).

%% Hooks
-export([reassign_jobs/0]).

start(_Host, _Opts) ->
    ?INFO("starting", []),
    ejabberd_hooks:add(reassign_jobs, ?MODULE, reassign_jobs, 10),
    check_and_schedule(),
    ok.

-spec schedule() -> ok.
schedule() ->
    %% dump account data daily at 3pm PT
    erlcron:cron(dump_accounts, {
        {daily, {10, pm}},
        {?MODULE, dump_accounts, []}
    }),
    
    %% Files written by dump_accounts will be sent to S3 the next day.
    %% Glue crawler run at 2am. We need to run computation after that.
    erlcron:cron(weekly_retention, {
        {weekly, wed, {03, am}},
        {?MODULE, compute_retention, []}
    }).


stop(_Host) ->
    ?INFO("stopping", []),
    ejabberd_hooks:delete(reassign_jobs, ?MODULE, reassign_jobs, 10),
    case util:is_main_stest() of
        true ->
            unschedule();
        false -> ok
    end,
    ok.

-spec unschedule() -> ok.
unschedule() ->
    erlcron:cancel(dump_accounts),
    erlcron:cancel(weekly_retention),
    ok.


reload(_Host, _NewOpts, _OldOpts) ->
    ok.


depends(_Host, _Opts) ->
    [].


mod_options(_Host) ->
    [].


%%====================================================================
%% Hooks
%%====================================================================

reassign_jobs() ->
    unschedule(),
    check_and_schedule(),
    ok.


check_and_schedule() ->
    case util:is_main_stest() of
        true -> schedule();
        false -> ok
    end,
    ok.



-spec compute_retention() -> ok.
compute_retention() ->
    ?INFO("computing retention"),
    mod_athena_stats:run_query(weekly_user_retention()),
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
        case model_accounts:get_account(Uid) of
            {error, missing} -> ok;
            {ok, Account} ->
                {ok, Friends} = model_friends:get_friends(Uid),
                RealFriends = model_accounts:filter_nonexisting_uids(lists:delete(Uid, Friends)),
                FriendLastActivity = model_accounts:get_last_activity_ts_ms(RealFriends),
                CurTsMs = util:now_ms(),
                ActiveFriends = maps:fold(
                    fun(K, V, Acc) ->
                        case ((CurTsMs - V) > ?NUM_INACTIVE_DAYS * ?DAYS_MS) of
                            false -> Acc ++ [K];
                            true -> Acc
                        end
                    end, [], FriendLastActivity),
                {ok, MarketingTags} = model_accounts:get_marketing_tags(Uid),
                LatestTag = case MarketingTags of
                    [] -> none;
                    _ ->
                      {Tag, _} = lists:nth(1, MarketingTags),
                      Tag
                end,
                {ok, Contacts} = model_contacts:get_contacts(Uid),
                AppType = util_uid:get_app_type(Uid),
                UidContacts = model_phone:get_uids(Contacts, AppType),
                NumContacts = length(Contacts),
                NumUidContacts = length(maps:to_list(UidContacts)),
                NumFriends = length(RealFriends),
                Groups = model_groups:get_groups(Uid),
                NumGroups = length(Groups),
                MaxGroupMemberShip = case maps:values(model_groups:get_group_size(Groups)) of
                    [] -> 0;
                    CountList -> lists:max(CountList)
                end,
                NumActiveFriends = length(ActiveFriends),
                NumGroups = model_groups:get_group_count(Uid),
                CC = mod_libphonenumber:get_cc(Account#account.phone),
                ha_events:log_event(<<"server.accounts">>, #{
                    uid => Account#account.uid,
                    app_type => AppType,
                    creation_ts_ms => Account#account.creation_ts_ms,
                    last_activity => Account#account.last_activity_ts_ms,
                    signup_version => Account#account.signup_user_agent,
                    campaign_id => Account#account.campaign_id,
                    signup_platform => util_ua:get_client_type(Account#account.signup_user_agent),
                    cc => CC,
                    lang_id => Account#account.lang_id,
                    num_contacts => NumContacts,
                    num_uid_contacts => NumUidContacts,
                    num_friends => NumFriends,
                    num_active_friends => NumActiveFriends,
                    friends => RealFriends,
                    num_groups => NumGroups,
                    max_group_membership => MaxGroupMemberShip,
                    device => Account#account.device,
                    os_version => Account#account.os_version,
                    latest_marketing_tag => LatestTag
                }),
                ok
        end
    catch
        Class : Reason : St ->
            ?ERROR("failed to dump account Uid: ~p, to log: ~p",
                [Uid, lager:pr_stacktrace(St, {Class, Reason})])
    end.


weekly_user_retention() ->
    Query = "
    SELECT
        from_unixtime(creation_week * 7 * 24 * 60 * 60) as creation_week_date,
        max(now / (7 * 24 * 60 * 60) - creation_week) as week,
        count(*) as total,
        count_if(last_activity > now - (7 * 24 * 60 * 60)) as active,
        histogram(last_activity > now - (7 * 24 * 60 * 60)) as active_map

    FROM (
        SELECT
            uid,
            MAX(last_activity / 1000) as last_activity,
            cast(to_unixtime(now()) as integer) as now,
            MAX(creation_ts_ms) / (7 * 24 * 60 * 60 * 1000) as creation_week

        FROM \"default\".\"server_accounts\"
        GROUP BY uid)

    GROUP BY creation_week
    ORDER BY creation_week DESC ;
    ",

    #athena_query{
        query_bin = list_to_binary(Query),
        result_fun = {?MODULE, weekly_user_retention_result},
        % TODO: Why is this a list?
        metrics = ["user_retention_weekly"]
    }.

-spec weekly_user_retention_result(Query :: athena_query()) -> ok.
weekly_user_retention_result(Query) ->
    [Metric1] = Query#athena_query.metrics,
    Result = Query#athena_query.result,
    ResultRows = maps:get(<<"ResultRows">>, maps:get(<<"ResultSet">>, Result)),
    [_HeaderRow | ActualResultRows] = ResultRows,
    lists:foreach(
        fun(ResultRow) ->
            ?INFO("ResultRow ~p", [ResultRow]),
            [DateStr, WeekStr, TotalStr, ActiveStr, _ActiveMap | _] =
                maps:get(<<"Data">>, ResultRow),
            [Cohort, _] = string:split(DateStr, " "),
            Total = util:to_integer(TotalStr),
            Active = util:to_integer(ActiveStr),
            Percentage = 100 * Active / Total,
            Week = util:to_integer(WeekStr),
            ?INFO("Date ~p Total ~p Active ~p Percentage ~.1f Week ~p",
                [Cohort, Total, Active, Percentage, Week]),
            stat:count("HA/retention", Metric1 ++ ".percentage",
                Percentage,
                [{"cohort", Cohort}, {"week", Week}]),
            stat:count("HA/retention", Metric1 ++ ".counts",
                Total,
                [{"cohort", Cohort}, {"week", Week}, {"count", "total"}]),
            stat:count("HA/retention", Metric1 ++ ".counts",
                Active,
                [{"cohort", Cohort}, {"week", Week}, {"count", "active"}]),
            ok
        end, ActualResultRows),
    ok.
