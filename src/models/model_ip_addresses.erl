%%%------------------------------------------------------------------------------------
%%% File: model_ip_addresses.erl
%%% Copyright (C) 2021, HalloApp, Inc.
%%%
%%% This model handles all the redis db queries that are related with ip addresses.
%%%
%%%------------------------------------------------------------------------------------
-module(model_ip_addresses).
-author("vipin").

-include("logger.hrl").
-include("ha_types.hrl").
-include("redis_keys.hrl").
-include_lib("stdlib/include/assert.hrl").


%% API
-export([
    add_ip_address/3,
    get_ip_address_info/2,
    delete_ip_address/2
]).

%%====================================================================
%% API
%%====================================================================


-define(FIELD_COUNT, <<"ct">>).
-define(FIELD_TIMESTAMP, <<"ts">>).

%% TTL for ip address data: 1 day.
-define(TTL_IP_ADDRESS, 86400).

-spec add_ip_address(IPAddress :: list(), CC :: binary(), Timestamp :: integer()) -> ok  | {error, any()}.
add_ip_address(IPAddress, CC, Timestamp) ->
    IPBin = util:to_binary(IPAddress),
    _Results = q([
        ["MULTI"],
        ["HINCRBY", ip_key(IPBin, CC), ?FIELD_COUNT, 1],
        ["HSET", ip_key(IPBin, CC), ?FIELD_TIMESTAMP, util:to_binary(Timestamp)],
        ["EXPIRE", ip_key(IPBin, CC), ?TTL_IP_ADDRESS],
        ["EXEC"]
    ]),
    ok.


-spec get_ip_address_info(IPAddress :: list(), CC :: binary()) -> {ok, {maybe(integer()), maybe(integer())}}  | {error, any()}.
get_ip_address_info(IPAddress, CC) ->
    IPBin = util:to_binary(IPAddress),
    {ok, [Count, Timestamp]} = q(["HMGET", ip_key(IPBin, CC), ?FIELD_COUNT, ?FIELD_TIMESTAMP]),
    {ok, {util_redis:decode_int(Count), util_redis:decode_ts(Timestamp)}}.


-spec delete_ip_address(IPAddress :: list(), CC :: binary()) -> ok  | {error, any()}.
delete_ip_address(IPAddress, CC) ->
    IPBin = util:to_binary(IPAddress),
    _Results = q(["DEL", ip_key(IPBin, CC)]),
    ok.

q(Command) -> ecredis:q(ecredis_phone, Command).
qp(Commands) -> ecredis:qp(ecredis_phone, Commands).


-spec ip_key(IPBin :: binary(), CC :: binary()) -> binary().
ip_key(IPBin, CC) ->
    <<?IP_KEY/binary, <<"{">>/binary, IPBin/binary, <<"}:">>/binary, CC/binary>>.


