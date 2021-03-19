%%%-------------------------------------------------------------------
%%% @author nikola
%%% @copyright (C) 2020, Halloapp Inc.
%%% @doc
%%%
%%% @end
%%% Created : 26. May 2020 11:47 AM
%%%-------------------------------------------------------------------
-module(crc16_redis).
-author("nikola").

-include("crc16_redis.hrl").
%% API
-export([
    hash/1,
    crc16/1
]).


%% API.
-spec hash(string()) -> integer().
hash(Key) ->
    crc16(Key) rem ?REDIS_CLUSTER_HASH_SLOTS.

-spec crc16(string()) -> integer().
crc16(Key) ->
    crc16(Key,0).

-spec crc16(string(), integer()) -> integer().
crc16([B|T], Crc) ->
    Index = (((Crc bsr 8) bxor B) band 16#ff),
    NewCrc = ((Crc bsl 8) band 16#ffff) bxor crc_index(Index),
    crc16(T,NewCrc);
crc16([],Crc) ->
    Crc.

-spec crc_index(integer()) -> integer().
crc_index(N) ->
    <<Crc:16>> = binary:part(?CRCDEF,N*2,2),
    Crc.
