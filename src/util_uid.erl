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
    get_app_type/1,
    generate_uid/1,
    generate_uid/3,
    uid_size/0,
    looks_like_uid/1
]).


-define(MIN_REGION, 1).
-define(MAX_REGION, 9).
-define(DEFAULT_REGION, 1).
-define(REGION_BASE, 1000000000000000000).  %% 19 digits
-define(UID_SIZE, 19).

-define(MIN_APP_ID, 0).
-define(MAX_APP_ID, 999).
-define(APP_ID_BASE, 1000000000000000). %% 16 digits.

-define(MIN_SHARD, 0).
-define(MAX_SHARD, 99999).
-define(SHARD_BASE, 1000000000).  % 10 digits

-define(MAX_UIDS_PEP_SHARD, ?SHARD_BASE).

-type generate_uid_result() :: {ok, uid()} | {error, invalid_region | invalid_shard}.


-spec get_app_type(RawUserAgent :: maybe(binary())) -> maybe(app_type()).
get_app_type(undefined) -> undefined;
get_app_type(Uid) ->
    case Uid of
        <<"1000", _Rest/binary>> -> halloapp;
        <<"1001", _Rest/binary>> -> katchup;
        _ -> halloapp %% tests use weird uids. need to fix them.
    end.


generate_uid(UserAgent) ->
    case util_ua:is_halloapp(UserAgent) of
        true -> generate_uid(1, 0, 0);
        false ->
            case util_ua:is_katchup(UserAgent) of
                true -> generate_uid(1, 1, 0);
                false -> {error, invalid_ua}
            end
    end.


-spec generate_uid(integer(), integer(), integer()) -> generate_uid_result().
generate_uid(Region, _AppId, _Shard)
        when not is_integer(Region); Region > ?MAX_REGION; Region < ?MIN_REGION ->
    ?ERROR("Invalid Region = ~w", [Region]),
    {error, invalid_region};

generate_uid(_Region, _AppId, Shard)
        when not is_integer(Shard); Shard > ?MAX_SHARD; Shard < ?MIN_SHARD ->
    ?ERROR("Invalid Shard = ~w", [Shard]),
    {error, invalid_shard};

generate_uid(_Region, AppId, _Shard)
        when not is_integer(AppId); AppId > ?MAX_APP_ID; AppId < ?MIN_APP_ID ->
    ?ERROR("Invalid AppId = ~w", [AppId]),
    {error, invalid_appid};

generate_uid(Region, AppId, Shard)
        when is_integer(Region), is_integer(Shard) ->
    RegionPart = Region * ?REGION_BASE,
    AppIdPart = AppId * ?APP_ID_BASE,
    ShardPart = Shard * ?SHARD_BASE,
    RandomPart = crypto:rand_uniform(0, ?MAX_UIDS_PEP_SHARD),
    UidInt = RegionPart + AppIdPart + ShardPart + RandomPart,
    Uid = integer_to_binary(UidInt),
    {ok, Uid}.

-spec uid_size() -> non_neg_integer().
uid_size() ->
    ?UID_SIZE.


-spec looks_like_uid(binary()) -> boolean().
looks_like_uid(Bin) when not is_binary(Bin) orelse byte_size(Bin) =/= ?UID_SIZE->
    false;
looks_like_uid(Bin) ->
    case re:run(Bin, "100[0-1]{1}000000[0-9]{9}") of
        {match, [{0, 19}]} -> true;
        _ -> false
    end.

