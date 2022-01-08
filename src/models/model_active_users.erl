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
    active_users_cc_types/0,
    engaged_users_types/0
]).
-compile([{nowarn_unused_function, [
    {q, 1},
    {qp, 1}
]}]).

%%====================================================================
%% API
%%====================================================================

-spec count_active_users_between(Type :: activity_type(), LowerBound :: non_neg_integer(),
        UpperBound :: non_neg_integer()) -> non_neg_integer().
count_active_users_between(Type, LowerBound, UpperBound) ->
    Commands = lists:map(
        fun (Slot) ->
            Key = get_active_users_key_slot(Slot, Type),
            ["ZCOUNT", Key, LowerBound, UpperBound]
        end, lists:seq(0, ?NUM_SLOTS - 1)),
    Results = qmn(Commands),
    lists:foldl(fun({ok, Result}, Sum) -> binary_to_integer(Result) + Sum end, 0, Results).


-spec count_engaged_users_between(Type :: activity_type(), LowerBound :: non_neg_integer(),
        UpperBound :: non_neg_integer()) -> non_neg_integer().
count_engaged_users_between(Type, LowerBound, UpperBound) ->
    Commands = lists:map(
        fun (Slot) ->
            Key = get_engaged_users_key_slot(Slot, Type),
            ["ZCOUNT", Key, LowerBound, UpperBound]
        end, lists:seq(0, ?NUM_SLOTS - 1)),
    Results = qmn(Commands),
    lists:foldl(fun({ok, Result}, Sum) -> binary_to_integer(Result) + Sum end, 0, Results).


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

-spec active_users_types() -> list(activity_type()).
active_users_types() ->
    [
        all,
        android,
        ios
    ].

-spec active_users_cc_types() -> list(activity_type()).
active_users_cc_types() ->
    [{cc, CC} || CC <- countries:all()].

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
    CountryUsersKeys = [get_active_users_key_slot(Slot, Type) || Type <- active_users_cc_types()],
    EngagedUsersKeys = [get_engaged_users_key_slot(Slot, Type) || Type <- engaged_users_types()],
    AllKeys = ActiveUsersKeys ++ EngagedUsersKeys ++ CountryUsersKeys,
    Queries = [["ZREMRANGEBYSCORE", Key, 0, OldTs] || Key <- AllKeys],
    Results = qp(Queries),
    Count = lists:foldl(fun ({ok, C}, Acc) -> Acc + binary_to_integer(C) end, 0, Results),
    Count.


hash(Key) ->
    crc16:crc16(Key) rem ?NUM_SLOTS.


-spec get_active_users_key_slot(Slot :: integer(), Type :: activity_type()) -> binary().
get_active_users_key_slot(Slot, Type) ->
    SlotBinary = integer_to_binary(Slot),
    Key = case Type of
        ios -> ?ACTIVE_USERS_IOS_KEY;
        android -> ?ACTIVE_USERS_ANDROID_KEY;
        all -> ?ACTIVE_USERS_ALL_KEY;
        {cc, CC} -> <<?ACTIVE_USERS_CC_KEY/binary, CC/binary, ":">>
    end,
    <<Key/binary, "{", SlotBinary/binary, "}">>.


-spec get_engaged_users_key_slot(Slot :: integer(), Type :: activity_type()) -> binary().
get_engaged_users_key_slot(Slot, Type) ->
    SlotBinary = integer_to_binary(Slot),
    Key = case Type of
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


% borrowed from model_accounts.erl
qmn(Commands) ->
    util_redis:run_qmn(ecredis_accounts, Commands).

