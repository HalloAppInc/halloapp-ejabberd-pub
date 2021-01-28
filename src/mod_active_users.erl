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
    CountFuns = [
        {fun count_active_users_1day/1, "1day"},
        {fun count_active_users_7day/1, "7day"},
        {fun count_active_users_28day/1, "28day"},
        {fun count_active_users_30day/1, "30day"}
    ],
    DeviceTypes = model_active_users:active_users_types(),
    [stat:gauge("HA/active_users", Desc ++ "_" ++ atom_to_list(Device), Fun(Device))
        || {Fun, Desc} <- CountFuns, Device <- DeviceTypes],
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

