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

-include("eredis_cluster.hrl").

%% API
-export([
    count_key/2,
    count_fold/1
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

