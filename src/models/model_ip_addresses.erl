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
    add_ip_address/2,
    get_ip_address_info/1,
    delete_ip_address/1,
    is_ip_blocked/1,
    add_blocked_ip_address/2,
    remove_blocked_ip_address/1,
    record_blocked_ip_address/2,
    clear_blocked_ip_address/1
]).
-compile([{nowarn_unused_function, [
    {q, 1},
    {qp, 1}
    ]}]).

%%====================================================================
%% API
%%====================================================================


-define(FIELD_COUNT, <<"ct">>).
-define(FIELD_TIMESTAMP, <<"ts">>).

%% TTL for ip address data: 1 day.
-define(TTL_IP_ADDRESS, 86400).


-spec add_ip_address(IPAddress :: list(), Timestamp :: integer()) -> ok  | {error, any()}.
add_ip_address(IPAddress, Timestamp) ->
    IPBin = util:to_binary(IPAddress),
    _Results = q([
        ["MULTI"],
        ["HINCRBY", ip_key(IPBin), ?FIELD_COUNT, 1],
        ["HSET", ip_key(IPBin), ?FIELD_TIMESTAMP, util:to_binary(Timestamp)],
        ["EXPIRE", ip_key(IPBin), ?TTL_IP_ADDRESS],
        ["EXEC"]
    ]),
    ok.


-spec get_ip_address_info(IPAddress :: list()) -> {ok, {maybe(integer()), maybe(integer())}}  | {error, any()}.
get_ip_address_info(IPAddress) ->
    IPBin = util:to_binary(IPAddress),
    {ok, [Count, Timestamp]} = q(["HMGET", ip_key(IPBin), ?FIELD_COUNT, ?FIELD_TIMESTAMP]),
    % TODO: if we return {0, 0} instead of {undefined, undefined} the caller code will be better
    {ok, {util_redis:decode_int(Count), util_redis:decode_ts(Timestamp)}}.


-spec delete_ip_address(IPAddress :: list()) -> ok  | {error, any()}.
delete_ip_address(IPAddress) ->
    IPBin = util:to_binary(IPAddress),
    _Results = q(["DEL", ip_key(IPBin)]),
    ok.


%% TODO: Improve this to work with multiple blocklists eventually.
-spec is_ip_blocked(IPAddress :: list()) -> {true, maybe(integer())} | false.
is_ip_blocked(IPAddress) ->
    BlockIPKey = block_ip_key(IPAddress),
    [{ok, Res1}, {ok, Res2}] = qp([
        ["EXISTS", BlockIPKey],
        ["HGET", BlockIPKey, ?FIELD_TIMESTAMP]]),
    case util_redis:decode_boolean(Res1) of
        true -> {true, util_redis:decode_int(Res2)};
        false -> false
    end.


%% FieldType refers to the blocklist name we got the ip from.
%% One ipaddress could belong to multiple of these types.
-spec add_blocked_ip_address(IPAddress :: list(), FieldType :: binary()) -> ok | {error, any()}.
add_blocked_ip_address(IPAddress, FieldType) ->
    BlockIPKey = block_ip_key(IPAddress),
    {ok, _Res} = q(["HSET", BlockIPKey, FieldType, <<"1">>]),
    ok.


-spec remove_blocked_ip_address(IPAddress :: list()) -> ok | {error, any()}.
remove_blocked_ip_address(IPAddress) ->
    BlockIPKey = block_ip_key(IPAddress),
    {ok, _Res} = q(["DEL", BlockIPKey]),
    ok.

-spec record_blocked_ip_address(IPAddress :: list(), Timestamp :: integer()) -> ok | {error, any()}.
record_blocked_ip_address(IPAddress, Timestamp) ->
    BlockIPKey = block_ip_key(IPAddress),
    {ok, _Res} = q(["HSET", BlockIPKey, ?FIELD_TIMESTAMP, util:to_binary(Timestamp)]),
    ok.


-spec clear_blocked_ip_address(IPAddress :: list()) -> ok | {error, any()}.
clear_blocked_ip_address(IPAddress) ->
    BlockIPKey = block_ip_key(IPAddress),
    {ok, _Res} = q(["HDEL", BlockIPKey, ?FIELD_TIMESTAMP]),
    ok.


q(Command) -> ecredis:q(ecredis_phone, Command).
qp(Commands) -> ecredis:qp(ecredis_phone, Commands).


-spec ip_key(IPBin :: binary()) -> binary().
ip_key(IPBin) ->
    <<?IP_KEY/binary, "{", IPBin/binary, "}:">>.



-spec block_ip_key(IPAddress :: list()) -> binary().
block_ip_key(IPAddress) ->
    IPBin = util:to_binary(IPAddress),
    <<?BLOCK_IP_KEY/binary, "{", IPBin/binary, "}">>.


