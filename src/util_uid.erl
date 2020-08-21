%%%-------------------------------------------------------------------
%%% @author nikola
%%% @copyright (C) 2020, Halloapp Inc.
%%% @doc
%%%  Utility functions related to uid (User ID) generation and parsing.
%%% @end
%%% Created : 27. Mar 2020 2:47 PM
%%%-------------------------------------------------------------------
-module(util_uid).
-author("nikola").

-include("logger.hrl").
-include("ha_types.hrl").


%% API
-export([
    generate_uid/0,
    generate_uid/2
]).


-define(MIN_REGION, 1).
-define(MAX_REGION, 9).
-define(DEFAULT_REGION, 1).
-define(REGION_BASE, 1000000000000000000).  % 19 digits

-define(MIN_SHARD, 0).
-define(MAX_SHARD, 99999).
-define(SHARD_BASE, 1000000000).  % 10 digits

-define(MAX_UIDS_PEP_SHARD, ?SHARD_BASE).

-type generate_uid_result() :: {ok, uid()} | {error, invalid_region | invalid_shard}.

-spec generate_uid() -> generate_uid_result().
generate_uid() ->
    generate_uid(1, 0).

-spec generate_uid(integer(), integer()) -> generate_uid_result().
generate_uid(Region, _Shard)
        when not is_integer(Region); Region > ?MAX_REGION; Region < ?MIN_REGION ->
    ?ERROR_MSG("Invalid Region = ~w", [Region]),
    {error, invalid_region};

generate_uid(_Region, Shard)
        when not is_integer(Shard); Shard > ?MAX_SHARD; Shard < ?MIN_SHARD ->
    ?ERROR_MSG("Invalid Shard = ~w", [Shard]),
    {error, invalid_shard};

generate_uid(Region, Shard)
        when is_integer(Region), is_integer(Shard) ->
    RegionPart = Region * ?REGION_BASE,
    ShardPart = Shard * ?SHARD_BASE,
    RandomPart = crypto:rand_uniform(0, ?MAX_UIDS_PEP_SHARD),
    UidInt = RegionPart + ShardPart + RandomPart,
    Uid = integer_to_binary(UidInt),
    {ok, Uid}.

