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
-include("util_redis.hrl").

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
    get_engaged_users_key_slot/2,
    active_users_types/0,
    engaged_users_types/0
]).

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
    ?INFO("Cleaning up active/enaged user zsets...", []),
    TotalRemoved = lists:foldl(
        fun (Slot, Acc) ->
            cleanup_by_slot(Slot) + Acc
        end,
        0,
        lists:seq(0, ?NUM_SLOTS - 1)
    ),
    ?INFO("Removed ~p entries from active/enaged user zsets", [TotalRemoved]),
    ok.

%%====================================================================
%% Internal functions
%%====================================================================

active_users_types() ->
    [
        all,
        android,
        ios
    ].

engaged_users_types() ->
    [
        all,
        android,
        ios,
        post
    ].

-spec cleanup_by_slot(Slot :: non_neg_integer()) -> non_neg_integer().
cleanup_by_slot(Slot) ->
    OldTs = util:now_ms() - (30 * ?DAYS_MS) - (1 * ?SECONDS_MS),
    ActiveUsersKeys = [get_active_users_key_slot(Slot, Type) || Type <- active_users_types()],
    EngagedUsersKeys = [get_engaged_users_key_slot(Slot, Type) || Type <- engaged_users_types()],
    Queries = [["ZREMRANGEBYSCORE", Key, 0, OldTs] || Key <- ActiveUsersKeys ++ EngagedUsersKeys],
    Results = qp(Queries),
    Count = lists:foldl(fun ({ok, C}, Acc) -> Acc + binary_to_integer(C) end, 0, Results),
    Count.


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
        all -> ?ENGAGED_USERS_ALL_KEY;
        post -> ?ENGAGED_USERS_POST_KEY
    end,
    <<Key/binary, "{", SlotBinary/binary, "}">>.


% borrowed from model_accounts.erl
q(Command) -> ecredis:q(ecredis_accounts, Command).


% borrowed from model_accounts.erl
qp(Commands) ->
    ecredis:qp(ecredis_accounts, Commands).


