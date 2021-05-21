%%%-------------------------------------------------------------------
%%% File: mod_inactive_accounts.erl
%%% copyright (C) 2021, HalloApp, Inc.
%%%
%%% Module to manage inactive accounts.
%%%
%%%-------------------------------------------------------------------
-module(mod_inactive_accounts).
-author('vipin').
-behaviour(gen_mod).

-include("logger.hrl").
-include("time.hrl").
-include("mod_inactive_accounts.hrl").
-include("util_redis.hrl").
-include("account.hrl").

%% gen_mod callbacks
-export([start/2, stop/1, mod_options/1, depends/2]).

-export([
    manage/0,
    is_inactive_user/1,
    check_and_delete_accounts/1,  %% for testing, TODO(vipin): delete after testing.
    find_inactive_accounts/2
]).

%%====================================================================
%% gen_mod callbacks
%%====================================================================

start(_Host, _Opts) ->
    ?INFO("start ~w", [?MODULE]),
    ok.


stop(_Host) ->
    ?INFO("stop ~w", [?MODULE]),
    ok.

depends(_Host, _Opts) ->
    [].

mod_options(_Host) ->
    [].


%%====================================================================
%% api
%%====================================================================

-spec manage() -> ok.
manage() ->
    {Date, {Hr, _Min, _Sec}} = calendar:local_time_to_universal_time(calendar:local_time()),
    ToExecute = calc_step_to_execute(calendar:day_of_the_week(Date), Hr),
    case ToExecute of
        find_uids ->
            case model_accounts:mark_inactive_uids_gen_start() of
                true ->
                    ?INFO("On Monday, create list of inactive Uids", []),
                     model_accounts:cleanup_uids_to_delete_keys(),
                     redis_migrate:start_migration("Find Inactive Accounts", redis_accounts,
                         {?MODULE, find_inactive_accounts},
                         [{dry_run, false}, {execute, sequential}]);
                false ->
                    ?INFO("On Monday list of inactive Uids already created", [])
            end;
        check_uids ->
            case model_accounts:mark_inactive_uids_check_start() of
                true ->
                    ?INFO("On Tuesday, Start checking of inactive Uids using above list", []),
                    check_and_delete_accounts(false);
                false ->
                    ?INFO("On Tuesday, checking of inactive Uids already started", [])
            end;
         delete_uids ->
            case model_accounts:mark_inactive_uids_deletion_start() of
                true ->
                    ?INFO("On Wednesday, Start deletion of inactive Uids using above list", []),
                    check_and_delete_accounts(true);
                false ->
                    ?INFO("On Wednesday, deletion of inactive Uids already started", [])
            end;
       _ ->
            ?INFO("Nothing to be done", []),
            ok
    end,
    ok.


calc_step_to_execute(DayOfWeek, Hr) ->
    %% Ok to run between 10AM and 4PM PST.
    IsHrOk = (Hr > 18) and (Hr < 24),
    case {DayOfWeek, IsHrOk} of
        {1, true} ->
            %% Find Uids to delete on Monday.
            find_uids;
        {2, true} ->
            %% Check Uids found above on Tuesday.
            check_uids;
        {3, true} ->
            %% Delete Uids found above on Wednesday.
            delete_uids;
        {_, _} ->
            none
    end.

            
-spec is_inactive_user(Uid :: uid()) -> boolean().
is_inactive_user(Uid) ->
    {ok, LastActivity} = model_accounts:get_last_activity(Uid),
    #activity{uid = Uid, last_activity_ts_ms = LastTsMs} = LastActivity,
    case LastTsMs of
        undefined ->
            ?ERROR("Undefined last active for Uid: ~p", [Uid]),
            false;
        _ ->
            CurrentTimeMs = util:now_ms(),
            (CurrentTimeMs - LastTsMs) > ?NUM_INACTIVITY_DAYS * ?DAYS_MS
    end.
 

%%====================================================================


-spec check_and_delete_accounts(ShouldDelete :: boolean()) -> ok.
check_and_delete_accounts(ShouldDelete) ->
    NumInactiveAccounts = model_accounts:count_uids_to_delete(),
    NumTotalAccounts = model_accounts:count_accounts(),
    ?INFO("Num Inactive: ~p, Total: ~p", [NumInactiveAccounts, NumTotalAccounts]),
    Fraction = NumInactiveAccounts / NumTotalAccounts,

    IsNoDevAccount = not (is_any_dev_account()),

    %% Ok to delete, if to delete is within acceptable fraction and no dev account is slated for
    %% deletion.
    IsAcceptable = (Fraction > 0.0001) and (Fraction < ?ACCEPTABLE_FRACTION) and IsNoDevAccount,
    case IsAcceptable of
        false -> 
            ?ERROR("Not deleting inactive accounts. NumInactive: ~p, Total: ~p, Fraction: ~p, No dev account?: ~p",
                [NumInactiveAccounts, NumTotalAccounts, Fraction, IsNoDevAccount]),
            ok;
        true ->
            delete_inactive_accounts(ShouldDelete)
    end,
    ok.

-spec is_any_dev_account() -> boolean().
is_any_dev_account() ->
    lists:any(fun(Slot) ->
        ?INFO("Looking for dev account in slot: ~p", [Slot]),
        {ok, List} = model_accounts:get_uids_to_delete(Slot),
        lists:any(fun(Uid) ->
            lists:member(Uid, dev_users:get_dev_uids())
        end,
        List)
    end,
    lists:seq(0, ?NUM_SLOTS - 1)).
 

-spec delete_inactive_accounts(ShouldDelete :: boolean()) -> ok.
delete_inactive_accounts(ShouldDelete) ->
   lists:foreach(
        fun(Slot) ->
            ?INFO("Deleting accounts in slot: ~p", [Slot]),
            {ok, List} = model_accounts:get_uids_to_delete(Slot),
            [maybe_delete_inactive_account(Uid, ShouldDelete) || Uid <- List]
        end,
        lists:seq(0, ?NUM_SLOTS - 1)).


-spec maybe_delete_inactive_account(Uid :: uid(), ShouldDelete :: boolean()) -> ok.
maybe_delete_inactive_account(Uid, ShouldDelete) ->
    case is_inactive_user(Uid) of
        true ->
            {ok, Phone} = model_accounts:get_phone(Uid),
            {_, Version} = model_accounts:get_client_version(Uid),
            VersionTimeLeft = case Version of
                missing -> 0;
                _ -> mod_client_version:get_time_left(Version, util:now())
            end,
            VersionDaysLeft = VersionTimeLeft / ?DAYS,
            {ok, InvitersList} = model_invites:get_inviters_list(Phone),
            IsInvitedInternally = lists:any(
                fun({InviterUid, _Ts}) ->
                    lists:member(InviterUid, dev_users:get_dev_uids())
                end,
                InvitersList),
            case IsInvitedInternally of
                false ->
                    case ShouldDelete of
                        true ->
                            ?INFO("Deleting: ~p, Phone: ~p, Version: ~p, Version validity: ~p days, Invited by: ~p",
                                [Uid, Phone, Version, VersionDaysLeft, InvitersList]),
                            ejabberd_auth:remove_user(Uid, util:get_host());
                        false ->
                            ?INFO("Check -- Will delete: ~p, Phone: ~p, Version: ~p, Version validity: ~p days, Invited by: ~p",
                                [Uid, Phone, Version, VersionDaysLeft, InvitersList])
                    end;
                true ->
                    %% Either invited explicitly by an insider or it is an initial account.
                    ?ERROR("Manual attention needed. Not deleting: ~p, Phone: ~p, Version: ~p, Version validity: ~p days, Invited by: ~p",
                        [Uid, Phone, Version, VersionDaysLeft, InvitersList])
            end;
        false ->
            ?INFO("Not deleting: ~p, account has become active", [Uid])
    end,
    ok.


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%                         Generate List of inactive users                            %%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
find_inactive_accounts(Key, State) ->
    ?INFO("Key: ~p", [Key]),
    DryRun = maps:get(dry_run, State, false),
    Result = re:run(Key, "^acc:{([0-9]+)}$", [global, {capture, all, binary}]),
    case Result of
        {match, [[_FullKey, Uid]]} ->
            ?INFO("Account uid: ~p", [Uid]),
            try
                case mod_inactive_accounts:is_inactive_user(Uid) of
                    true ->
                        {ok, Phone} = model_accounts:get_phone(Uid),
                        ?INFO("Adding Uid: ~p to delete, Phone: ~p", [Uid, Phone]),
                        case DryRun of
                            true ->
                                ok;
                            false ->
                                model_accounts:add_uid_to_delete(Uid)
                        end;
                    false -> ok
                end
            catch
                Class:Reason:Stacktrace ->
                    ?ERROR("Stacktrace:~s", [lager:pr_stacktrace(Stacktrace, {Class, Reason})]),
                    ?ERROR("Unable to get last activity: ~p", [Uid])
            end,
            ok;
        _ -> ok
    end,
    State.

