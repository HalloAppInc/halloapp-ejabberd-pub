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

-include("logger.hrl").
-include("redis_keys.hrl").
-include("time.hrl").

%% API
-export([
    count_active_users_1day/0,
    count_active_users_7day/0,
    count_active_users_28day/0,
    count_active_users_30day/0,
    count_recent_active_users/1,
    count_active_users_between/2,
    get_active_users_key/1
]).

-define(NUM_SLOTS, 256).

%%====================================================================
%% API
%%====================================================================

count_active_users_1day() ->
    count_recent_active_users(1 * ?DAYS_MS).


count_active_users_7day() ->
    count_recent_active_users(7 * ?DAYS_MS).


count_active_users_28day() ->
    count_recent_active_users(28 * ?DAYS_MS).


count_active_users_30day() ->
    count_recent_active_users(30 * ?DAYS_MS).


-spec count_recent_active_users(IntervalMs :: non_neg_integer()) -> non_neg_integer().
count_recent_active_users(IntervalMs) ->
    Now = util:now_ms(),
    count_active_users_between(Now - IntervalMs, Now + (1 * ?MINUTES_MS)).


-spec count_active_users_between(LowerBound :: non_neg_integer(), UpperBound :: non_neg_integer())
        -> non_neg_integer().
count_active_users_between(LowerBound, UpperBound) ->
    lists:foldl(
        fun (Slot, Acc) ->
            Acc + count_active_users_by_slot(Slot, LowerBound, UpperBound)
        end,
        0,
        lists:seq(0, ?NUM_SLOTS - 1)
    ).


get_active_users_key(Uid) ->
    Slot = hash(binary_to_list(Uid)),
    get_active_users_key_slot(Slot).

%%====================================================================
%% Internal functions
%%====================================================================

-spec count_active_users_by_slot(Slot :: non_neg_integer(), LowerBound :: non_neg_integer(),
        UpperBound :: non_neg_integer()) -> non_neg_integer().
count_active_users_by_slot(Slot, LowerBound, UpperBound) ->
    {ok, Result} = q(["ZCOUNT", get_active_users_key_slot(Slot), LowerBound, UpperBound]),
    binary_to_integer(Result).


hash(Key) ->
    crc16:crc16(Key) rem ?NUM_SLOTS.


get_active_users_key_slot(Slot) ->
    SlotBinary = integer_to_binary(Slot),
    <<?ACTIVE_USERS_KEY/binary, "{", SlotBinary/binary, "}">>.


% borrowed from model_accounts.erl
q(Command) ->
    {ok, Result} = gen_server:call(redis_accounts_client, {q, Command}),
    Result.

