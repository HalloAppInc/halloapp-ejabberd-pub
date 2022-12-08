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

-include("ha_types.hrl").
-include("active_users.hrl").
-include("logger.hrl").
-include("time.hrl").

%% API
-export([
    count_halloapp_active_users_1day/1,
    count_katchup_active_users_1day/1,
    count_halloapp_active_users_7day/1,
    count_katchup_active_users_7day/1,
    count_halloapp_active_users_28day/1,
    count_katchup_active_users_28day/1,
    count_halloapp_active_users_30day/1,
    count_katchup_active_users_30day/1,
    count_recent_active_users/3,
    compute_counts/0,
    update_last_activity/3,
    update_last_connection/3
]).

%%====================================================================
%% API
%%====================================================================

-spec count_halloapp_active_users_1day(Type :: activity_type()) -> non_neg_integer().
count_halloapp_active_users_1day(Type) ->
    count_recent_active_users(1 * ?DAYS_MS, Type, ?HALLOAPP).

-spec count_katchup_active_users_1day(Type :: activity_type()) -> non_neg_integer().
count_katchup_active_users_1day(Type) ->
    count_recent_active_users(1 * ?DAYS_MS, Type, ?KATCHUP).


-spec count_halloapp_active_users_7day(Type :: activity_type()) -> non_neg_integer().
count_halloapp_active_users_7day(Type) ->
    count_recent_active_users(7 * ?DAYS_MS, Type, ?HALLOAPP).

-spec count_katchup_active_users_7day(Type :: activity_type()) -> non_neg_integer().
count_katchup_active_users_7day(Type) ->
    count_recent_active_users(7 * ?DAYS_MS, Type, ?KATCHUP).


-spec count_halloapp_active_users_28day(Type :: activity_type()) -> non_neg_integer().
count_halloapp_active_users_28day(Type) ->
    count_recent_active_users(28 * ?DAYS_MS, Type, ?HALLOAPP).

-spec count_katchup_active_users_28day(Type :: activity_type()) -> non_neg_integer().
count_katchup_active_users_28day(Type) ->
    count_recent_active_users(28 * ?DAYS_MS, Type, ?KATCHUP).


-spec count_halloapp_active_users_30day(Type :: activity_type()) -> non_neg_integer().
count_halloapp_active_users_30day(Type) ->
    count_recent_active_users(30 * ?DAYS_MS, Type, ?HALLOAPP).

-spec count_katchup_active_users_30day(Type :: activity_type()) -> non_neg_integer().
count_katchup_active_users_30day(Type) ->
    count_recent_active_users(30 * ?DAYS_MS, Type, ?KATCHUP).


-spec count_recent_active_users(IntervalMs :: non_neg_integer(),
        Type :: activity_type(), AppType :: app_type()) -> non_neg_integer().
count_recent_active_users(IntervalMs, Type, AppType) ->
    Now = util:now_ms(),
    model_active_users:count_active_users_between(Type, Now - IntervalMs, Now + (1 * ?MINUTES_MS), AppType).

-spec count_recent_connected_users(IntervalMs :: non_neg_integer(), AppType :: app_type()) -> non_neg_integer().
count_recent_connected_users(IntervalMs, AppType) ->
    Now = util:now_ms(),
    model_active_users:count_connected_users_between(Now - IntervalMs, Now + (1 * ?MINUTES_MS), AppType).

days_to_count() -> [1, 7, 28, 30].


-spec compute_counts() -> ok.
compute_counts() ->
    CountFunsHA = [
        {fun count_halloapp_active_users_1day/1, "1day"},
        {fun count_halloapp_active_users_7day/1, "7day"},
        {fun count_halloapp_active_users_28day/1, "28day"},
        {fun count_halloapp_active_users_30day/1, "30day"}
    ],
    CountFunsKA = [
        {fun count_katchup_active_users_1day/1, "1day"},
        {fun count_katchup_active_users_7day/1, "7day"},
        {fun count_katchup_active_users_28day/1, "28day"},
        {fun count_katchup_active_users_30day/1, "30day"}
    ],
    DeviceTypes = model_active_users:active_users_types(),
    [stat:gauge("HA/active_users", Desc ++ "_" ++ atom_to_list(Device), Fun(Device))
        || {Fun, Desc} <- CountFunsHA, Device <- DeviceTypes],
    [stat:gauge("KA/active_users", Desc ++ "_" ++ atom_to_list(Device), Fun(Device))
        || {Fun, Desc} <- CountFunsKA, Device <- DeviceTypes],

    ?INFO("computing active users by country: start"),
    CCTypes = model_active_users:active_users_cc_types(),
    [stat:gauge("HA/active_users", Desc ++ "_by_cc." ++ util:to_list(CC), Fun({cc, CC}))
        || {Fun, Desc} <- CountFunsHA, {cc, CC} <- CCTypes],
    [stat:gauge("KA/active_users", Desc ++ "_by_cc." ++ util:to_list(CC), Fun({cc, CC}))
        || {Fun, Desc} <- CountFunsKA, {cc, CC} <- CCTypes],
    ?INFO("computing active users by country: done"),

    [stat:gauge("HA/active_users", util:to_list(Day) ++ "day_connected_all",
        count_recent_connected_users(Day * ?DAYS_MS, ?HALLOAPP)) || Day <- days_to_count()],
    [stat:gauge("KA/active_users", util:to_list(Day) ++ "day_connected_all",
        count_recent_connected_users(Day * ?DAYS_MS, ?KATCHUP)) || Day <- days_to_count()],
    ok.


-spec update_last_activity(Uid :: binary(), TimestampMs :: integer(), Resource :: maybe(binary())) -> ok.
update_last_activity(Uid, TimestampMs, Resource) ->
    UserAgent = util_ua:resource_to_client_type(Resource),
    Keys = [model_active_users:get_active_users_key(Uid)],
    Keys1 = case UserAgent of
        undefined -> Keys;
        _ -> [model_active_users:get_active_users_key(Uid, UserAgent) | Keys]
    end,
    case model_accounts:get_phone(Uid) of
        {ok, Phone} ->
            CC = mod_libphonenumber:get_cc(Phone),
            Keys2 = [model_active_users:get_active_users_key(Uid, {cc, CC}) | Keys1],
            case util:is_test_number(Phone) of
                false ->
                    ok = model_active_users:set_activity(Uid, TimestampMs, Keys2);
                true ->
                    ok
            end;
        {error, missing} ->
            ?ERROR("Can not find the phone of active user? Uid: ~p", [Uid])
    end,
    ok.

-spec update_last_connection(Uid :: uid(), TimestampMs :: integer(), AppType :: app_type()) -> ok.
update_last_connection(Uid, TimestampMs, AppType) ->
    model_active_users:set_connectivity(Uid, TimestampMs, AppType),
    ok.

