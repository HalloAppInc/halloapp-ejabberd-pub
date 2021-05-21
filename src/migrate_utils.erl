%%%-------------------------------------------------------------------
%%% @author nikola
%%% @copyright (C) 2021, Halloapp Inc.
%%% @doc
%%%
%%% @end
%%% Created : 19. May 2021 2:19 PM
%%%-------------------------------------------------------------------
-module(migrate_utils).
-author("nikola").

-include("logger.hrl").
-include("account.hrl").
-include("time.hrl").

%% API
-export([
    user_details/1

]).

user_details(Uid) ->
    try
        user_details2(Uid)
    catch
        Class:Reason:Stacktrace ->
            ?ERROR("Stacktrace:~s",
                [lager:pr_stacktrace(Stacktrace, {Class, Reason})]),
            ?INFO("Unable to fetch details", [])
    end.

user_details2(Uid) ->
    {ok, Account} = model_accounts:get_account(Uid),
    #account{uid = Uid, name = Name, phone = Phone, signup_user_agent = UA, creation_ts_ms = CtMs,
        last_activity_ts_ms = LaTsMs, activity_status = ActivityStatus, client_version = CV} =
        Account,
    IsTestPhone = util:is_test_number(Phone),

    %% Get list of internal inviter phone numbers if any.
    {ok, InvitersList} = model_invites:get_inviters_list(Phone),
    InternalInviterPhoneNums = lists:foldl(
        fun(X, Acc) ->
            {InviterUid, _Ts} = X,
            case dev_users:is_dev_uid(InviterUid) of
                true ->
                    {ok, InviterPhoneNum} = model_accounts:get_phone(InviterUid),
                    io_lib:format("~s~s, ", [Acc, util:to_list(InviterPhoneNum)]);
                _ -> Acc
            end
        end,
        "",
        InvitersList),

    LastActivityTimeString = case LaTsMs of
        undefined -> undefined;
        _ ->
            calendar:system_time_to_rfc3339(LaTsMs,
                [{unit, millisecond}, {time_designator, $\s}])
    end,

    %% Designate account inactive if last activity 13 weeks ago.
    IsAccountInactive = case LaTsMs of
        undefined -> true;
        _ ->
            CurrentTimeMs = os:system_time(millisecond),
            (CurrentTimeMs - LaTsMs) > 13 * ?WEEKS_MS
    end,
    CreationTimeString = case CtMs of
        undefined -> undefined;
        _ ->
            calendar:system_time_to_rfc3339(CtMs,
                [{unit, millisecond}, {time_designator, $\s}])
    end,
    ?INFO("Last Activity: ~s, Last Status: ~s, Name: ~s, Creation: ~s, Test Phone?: ~s, "
    "Client Version: ~s, User Agent: ~s, Inactive?: ~s, Internal Inviters: ~s",
        [LastActivityTimeString, ActivityStatus, util:to_list(Name), CreationTimeString,
            IsTestPhone, util:to_list(CV), util:to_list(UA), IsAccountInactive,
            InternalInviterPhoneNums]).

