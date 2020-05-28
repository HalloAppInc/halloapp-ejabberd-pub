#!/usr/bin/env escript
%% -*- erlang -*-
%%! -smp enable -sname redis_hash -mnesia debug verbose
-mode(compile).

-include("../deps/eredis_cluster/include/eredis_cluster.hrl").

%% API.
-spec hash(string()) -> integer().
hash(Key) ->
    crc16_redis:crc16(Key) rem ?REDIS_CLUSTER_HASH_SLOTS.

main([]) ->
    true = code:add_pathz(filename:dirname(escript:script_name()) ++ "/../ebin"),
    M = compute_map(0, #{}),
    io:format("map: ~p~n", [M]),
    ok = file:write_file("redis_hash.data", term_to_binary(M)),
    io:format("map_size : ~p~n", [maps:size(M)]),
    ok;
main(_) ->
    usage().

usage() ->
    io:format("usage\n"),
    halt(1).

compute_map(N, Map) ->
    io:format("~p ~p~n", [N, maps:size(Map)]),
    case maps:size(Map) < ?REDIS_CLUSTER_HASH_SLOTS of
        false -> Map;
        true ->
            Slot = hash(integer_to_list(N)),
            NewMap = case maps:is_key(Slot, Map) of
                false ->
                    maps:put(Slot, N, Map);
                true -> Map
            end,
            compute_map(N + 1, NewMap)
    end.
