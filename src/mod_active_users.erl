%%%-------------------------------------------------------------------
%%% @author josh
%%% @copyright (C) 2020, HalloApp, Inc.
%%% @doc
%%%
%%% @end
%%% Created : 08. Jul 2020 4:48 PM
%%%-------------------------------------------------------------------
-module(mod_active_users).
-author("josh").

-include("active_users.hrl").
-include("logger.hrl").
-include("time.hrl").

%% API
-export([
    count_active_users_1day/1,
    count_active_users_7day/1,
    count_active_users_28day/1,
    count_active_users_30day/1,
    count_recent_active_users/2,
    compute_counts/0,
    update_last_activity/3
]).

%%====================================================================
%% API
%%====================================================================

-spec count_active_users_1day(Type :: activity_type()) -> non_neg_integer().
count_active_users_1day(Type) ->
    count_recent_active_users(1 * ?DAYS_MS, Type).


-spec count_active_users_7day(Type :: activity_type()) -> non_neg_integer().
count_active_users_7day(Type) ->
    count_recent_active_users(7 * ?DAYS_MS, Type).


-spec count_active_users_28day(Type :: activity_type()) -> non_neg_integer().
count_active_users_28day(Type) ->
    count_recent_active_users(28 * ?DAYS_MS, Type).


-spec count_active_users_30day(Type :: activity_type()) -> non_neg_integer().
count_active_users_30day(Type) ->
    count_recent_active_users(30 * ?DAYS_MS, Type).


-spec count_recent_active_users(IntervalMs :: non_neg_integer(),
        Type :: activity_type()) -> non_neg_integer().
count_recent_active_users(IntervalMs, Type) ->
    Now = util:now_ms(),
    model_active_users:count_active_users_between(Type, Now - IntervalMs, Now + (1 * ?MINUTES_MS)).


-spec compute_counts() -> ok.
compute_counts() ->
    Total1 = count_active_users_1day(all),
    Android1 = count_active_users_1day(android),
    Ios1 = count_active_users_1day(ios),
    ?INFO_MSG("Active users in the past 1 day: ~p total, ~p android, ~p ios", [Total1, Android1, Ios1]),
    stat:count("HA/active_users", "1day_all", Total1),
    stat:count("HA/active_users", "1day_android", Android1),
    stat:count("HA/active_users", "1day_ios", Ios1),
    Total7 = count_active_users_7day(all),
    Android7 = count_active_users_7day(android),
    Ios7 = count_active_users_7day(ios),
    ?INFO_MSG("Active users in the past 7 days: ~p total, ~p android, ~p ios", [Total7, Android7, Ios7]),
    stat:count("HA/active_users", "7day_all", Total7),
    stat:count("HA/active_users", "7day_android", Android7),
    stat:count("HA/active_users", "7day_ios", Ios7),
    Total28 = count_active_users_28day(all),
    Android28 = count_active_users_28day(android),
    Ios28 = count_active_users_28day(ios),
    ?INFO_MSG("Active users in the past 28 days: ~p total, ~p android, ~p ios", [Total28, Android28, Ios28]),
    stat:count("HA/active_users", "28day_all", Total28),
    stat:count("HA/active_users", "28day_android", Android28),
    stat:count("HA/active_users", "28day_ios", Ios28),
    Total30 = count_active_users_1day(all),
    Android30 = count_active_users_1day(android),
    Ios30 = count_active_users_1day(ios),
    ?INFO_MSG("Active users in the past 30 days: ~p total, ~p android, ~p ios", [Total30, Android30, Ios30]),
    stat:count("HA/active_users", "30day_all", Total30),
    stat:count("HA/active_users", "30day_android", Android30),
    stat:count("HA/active_users", "30day_ios", Ios30),
    ok.


-spec update_last_activity(Uid :: binary(), TimestampMs :: integer(), Resource :: binary()) -> ok.
update_last_activity(Uid, TimestampMs, Resource) ->
    Type = util_ua:resource_to_client_type(Resource),
    MainKey = model_active_users:get_active_users_key(Uid),
    Keys = case Type of
        undefined -> [MainKey];
        _ -> [MainKey, model_active_users:get_active_users_key(Uid, Type)]
    end,
    ok = model_active_users:set_activity(Uid, TimestampMs, Keys),
    ok.

