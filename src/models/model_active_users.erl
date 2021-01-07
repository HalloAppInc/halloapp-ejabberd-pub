%%%-------------------------------------------------------------------
%%% @author josh
%%% @copyright (C) 2020, HalloApp, Inc.
%%% @doc
%%%
%%% @end
%%% Created : 30. Jun 2020 7:59 PM
%%%-------------------------------------------------------------------
-module(model_active_users).
-author("josh").

-include("active_users.hrl").
-include("logger.hrl").
-include("redis_keys.hrl").
-include("time.hrl").
-include("ha_types.hrl").

%% API
-export([
    count_active_users_between/3,
    get_active_users_key/1,
    set_activity/3,
    cleanup/0,
    get_active_users_key/2,
    get_engaged_users_key/1,
    get_engaged_users_key/2,
    count_engaged_users_between/3,
    get_active_users_key_slot/2,
    get_engaged_users_key_slot/2
]).

-define(NUM_SLOTS, 256).

%%====================================================================
%% API
%%====================================================================

-spec count_active_users_between(Type :: activity_type(), LowerBound :: non_neg_integer(),
        UpperBound :: non_neg_integer()) -> non_neg_integer().
count_active_users_between(Type, LowerBound, UpperBound) ->
    lists:foldl(
        fun (Slot, Acc) ->
            Key = get_active_users_key_slot(Slot, Type),
            Acc + count_active_users_by_key(Key, LowerBound, UpperBound)
        end,
        0,
        lists:seq(0, ?NUM_SLOTS - 1)
    ).


-spec count_engaged_users_between(Type :: activity_type(), LowerBound :: non_neg_integer(),
        UpperBound :: non_neg_integer()) -> non_neg_integer().
count_engaged_users_between(Type, LowerBound, UpperBound) ->
    lists:foldl(
        fun (Slot, Acc) ->
            Key = get_engaged_users_key_slot(Slot, Type),
            Acc + count_active_users_by_key(Key, LowerBound, UpperBound)
        end,
        0,
        lists:seq(0, ?NUM_SLOTS - 1)
    ).


-spec get_active_users_key(Uid :: uid()) -> binary().
get_active_users_key(Uid) ->
    Slot = hash(binary_to_list(Uid)),
    get_active_users_key_slot(Slot, all).


-spec get_active_users_key(Uid :: uid(), Type :: activity_type()) -> binary().
get_active_users_key(Uid, Type) ->
    Slot = hash(binary_to_list(Uid)),
    get_active_users_key_slot(Slot, Type).


-spec get_engaged_users_key(Uid :: uid()) -> binary().
get_engaged_users_key(Uid) ->
    get_engaged_users_key(Uid, all).


-spec get_engaged_users_key(Uid :: uid(), Type :: activity_type()) -> binary().
get_engaged_users_key(Uid, Type) ->
    Slot = hash(binary_to_list(Uid)),
    get_engaged_users_key_slot(Slot, Type).


-spec set_activity(Uid :: uid(), TimestampMs :: integer(), Keys :: list()) -> ok.
set_activity(Uid, TimestampMs, Keys) ->
    Commands = [["ZADD", Key, TimestampMs, Uid] || Key <- Keys],
    qp(Commands),
    ok.


-spec cleanup() -> ok.
cleanup() ->
    ?INFO("Cleaning up active user zsets...", []),
    TotalNumActiveRemoved = lists:foldl(
        fun (Slot, Acc) ->
            cleanup_by_slot(Slot, get_active_users_key_slot) + Acc
        end,
        0,
        lists:seq(0, ?NUM_SLOTS - 1)
    ),
    ?INFO("Removed ~p entries from active user zsets", [TotalNumActiveRemoved]),

    ?INFO("Cleaning up engaged user zsets...", []),
    TotalNumEngagedRemoved = lists:foldl(
        fun (Slot, Acc) ->
            cleanup_by_slot(Slot, get_engaged_users_key_slot) + Acc
        end,
        0,
        lists:seq(0, ?NUM_SLOTS - 1)
    ),
    ?INFO("Removed ~p entries from engaged user zsets", [TotalNumEngagedRemoved]),
    ok.

%%====================================================================
%% Internal functions
%%====================================================================

-spec cleanup_by_slot(Slot :: non_neg_integer(), KeyFunction :: atom()) -> non_neg_integer().
cleanup_by_slot(Slot, KeyFunction) ->
    OldTs = util:now_ms() - (30 * ?DAYS_MS) - (1 * ?SECONDS_MS),
    [{ok, NumAll}, {ok, NumAndroid}, {ok, NumIos}] = qp([
        ["ZREMRANGEBYSCORE", apply(?MODULE, KeyFunction, [Slot, all]), 0, OldTs],
        ["ZREMRANGEBYSCORE", apply(?MODULE, KeyFunction, [Slot, android]), 0, OldTs],
        ["ZREMRANGEBYSCORE", apply(?MODULE, KeyFunction, [Slot, ios]), 0, OldTs]
    ]),
    binary_to_integer(NumAll) + binary_to_integer(NumAndroid) + binary_to_integer(NumIos).

-spec count_active_users_by_key(Key :: binary(), LowerBound :: non_neg_integer(),
        UpperBound :: non_neg_integer()) -> non_neg_integer().
count_active_users_by_key(Key, LowerBound, UpperBound) ->
    {ok, Result} = q(["ZCOUNT", Key, LowerBound, UpperBound]),
    binary_to_integer(Result).


hash(Key) ->
    crc16:crc16(Key) rem ?NUM_SLOTS.


get_active_users_key_slot(Slot, UserAgent) ->
    SlotBinary = integer_to_binary(Slot),
    Key = case UserAgent of
              ios -> ?ACTIVE_USERS_IOS_KEY;
              android -> ?ACTIVE_USERS_ANDROID_KEY;
              all -> ?ACTIVE_USERS_ALL_KEY
          end,
    <<Key/binary, "{", SlotBinary/binary, "}">>.


get_engaged_users_key_slot(Slot, UserAgent) ->
    SlotBinary = integer_to_binary(Slot),
    Key = case UserAgent of
        ios -> ?ENGAGED_USERS_IOS_KEY;
        android -> ?ENGAGED_USERS_ANDROID_KEY;
        all -> ?ENGAGED_USERS_ALL_KEY
    end,
    <<Key/binary, "{", SlotBinary/binary, "}">>.


% borrowed from model_accounts.erl
q(Command) -> ecredis:q(ecredis_accounts, Command).


% borrowed from model_accounts.erl
qp(Commands) ->
    ecredis:qp(ecredis_accounts, Commands).


