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
    get_active_users_key/2
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
            Acc + count_active_users_by_slot(Slot, LowerBound, UpperBound, Type)
        end,
        0,
        lists:seq(0, ?NUM_SLOTS - 1)
    ).


-spec get_active_users_key(Uid :: uid()) -> binary().
get_active_users_key(Uid) ->
    Slot = hash(binary_to_list(Uid)),
    get_active_users_key_slot(Slot).


-spec get_active_users_key(Uid :: uid(), Type :: activity_type()) -> binary().
get_active_users_key(Uid, Type) ->
    Slot = hash(binary_to_list(Uid)),
    get_active_users_key_slot(Slot, Type).


-spec set_activity(Uid :: uid(), TimestampMs :: integer(), Keys :: list()) -> ok.
set_activity(Uid, TimestampMs, Keys) ->
    Commands = [["ZADD", Key, TimestampMs, Uid] || Key <- Keys],
    qp(Commands),
    ok.


-spec cleanup() -> ok.
cleanup() ->
    ?INFO_MSG("Cleaning up active user zsets...", []),
    TotalNumRemoved = lists:foldl(
        fun (Slot, Acc) ->
            cleanup_by_slot(Slot) + Acc
        end,
        0,
        lists:seq(0, ?NUM_SLOTS - 1)
    ),
    ?INFO_MSG("Removed ~p entries from active user zsets", [TotalNumRemoved]),
    ok.

%%====================================================================
%% Internal functions
%%====================================================================

-spec cleanup_by_slot(Slot :: non_neg_integer()) -> non_neg_integer().
cleanup_by_slot(Slot) ->
    OldTs = util:now_ms() - (30 * ?DAYS_MS) - (1 * ?SECONDS_MS),
    [{ok, NumAll}, {ok, NumAndroid}, {ok, NumIos}] = qp([
        ["ZREMRANGEBYSCORE", get_active_users_key_slot(Slot, all), 0, OldTs],
        ["ZREMRANGEBYSCORE", get_active_users_key_slot(Slot, android), 0, OldTs],
        ["ZREMRANGEBYSCORE", get_active_users_key_slot(Slot, ios), 0, OldTs]
    ]),
    binary_to_integer(NumAll) + binary_to_integer(NumAndroid) + binary_to_integer(NumIos).

-spec count_active_users_by_slot(Slot :: non_neg_integer(), LowerBound :: non_neg_integer(),
        UpperBound :: non_neg_integer(), Type :: activity_type()) -> non_neg_integer().
count_active_users_by_slot(Slot, LowerBound, UpperBound, Type) ->
    {ok, Result} = q(["ZCOUNT", get_active_users_key_slot(Slot, Type), LowerBound, UpperBound]),
    binary_to_integer(Result).


hash(Key) ->
    crc16:crc16(Key) rem ?NUM_SLOTS.


get_active_users_key_slot(Slot) ->
    get_active_users_key_slot(Slot, all).


get_active_users_key_slot(Slot, UserAgent) ->
    SlotBinary = integer_to_binary(Slot),
    Key = case UserAgent of
              ios -> ?ACTIVE_USERS_IOS_KEY;
              android -> ?ACTIVE_USERS_ANDROID_KEY;
              all -> ?ACTIVE_USERS_ALL_KEY
          end,
    <<Key/binary, "{", SlotBinary/binary, "}">>.


% borrowed from model_accounts.erl
q(Command) -> ecredis:q(ecredis_accounts, Command).


% borrowed from model_accounts.erl
qp(Commands) ->
    ecredis:qp(ecredis_accounts, Commands).


