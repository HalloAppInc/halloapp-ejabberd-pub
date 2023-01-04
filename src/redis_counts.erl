%%%-------------------------------------------------------------------
%%% @author nikola
%%% @copyright (C) 2020, Halloapp Inc.
%%% @doc
%%%
%%% @end
%%% Created : 17. Aug 2020 5:22 PM
%%%-------------------------------------------------------------------
-module(redis_counts).
-author("nikola").

-include("crc16_redis.hrl").

%% API
-export([
    count_key/2,
    count_fold/1,
    count_by_slot/3
]).


count_key(Slot, Prefix) when is_integer(Slot), is_binary(Prefix) ->
    SlotKey = ha_redis:get_slot_key(Slot),
    SlotBinary = integer_to_binary(Slot),
    <<Prefix/binary, <<"{">>/binary, SlotKey/binary, <<"}.">>/binary,
        SlotBinary/binary>>.


count_fold(Fun) ->
    lists:foldl(
        fun (Slot, Acc) ->
            Acc + Fun(Slot)
        end,
        0,
        lists:seq(0, ?REDIS_CLUSTER_HASH_SLOTS -1)).

count_by_slot(ClusterName, Fun, AppType) ->
    SlotQueries = lists:map(fun(Slot) -> Fun(Slot, AppType) end, lists:seq(0, ?REDIS_CLUSTER_HASH_SLOTS - 1)),
    Res = ecredis:qmn(ClusterName, SlotQueries),
    Count = lists:foldl(
        fun(Result, Acc) ->
            case Result of
                {ok, undefined} ->
                    Acc;
                {ok, CountBin} ->
                    Acc + binary_to_integer(CountBin);
                {error, _} ->
                    Acc
            end
        end,
        0,
        Res),
    Count.

