%%%-------------------------------------------------------------------
%%% @author nikola
%%% @copyright (C) 2020, HalloApp, Inc.
%%% @doc
%%%
%%% @end
%%% Created : 15. Apr 2020 2:53 PM
%%%-------------------------------------------------------------------
-module(model_client_version).
-author("nikola").

-include("logger.hrl").
-include("redis_keys.hrl").
-include("ha_types.hrl").

%% API
-export([
    version_key/1,
    get_version_ts/1,
    set_version_ts/2,
    get_versions/2,
    get_all_versions/0,
    update_version_ts/2
]).

%%====================================================================
%% API
%%====================================================================

-spec get_version_ts(Version :: binary()) -> maybe(integer()).
get_version_ts(Version) ->
    {ok, Res} = q(["GET", version_key(Version)]),
    util_redis:decode_ts(Res).

-spec set_version_ts(Version :: binary(), Ts :: integer()) -> boolean().
set_version_ts(Version, Ts) ->
    {ok, Res} = q(["SETNX", version_key(Version), Ts]),
    NewVersion = (binary_to_integer(Res) =:= 1),
    case NewVersion of
        true ->
            {ok, <<"1">>} = q(["ZADD", all_versions_key(), Ts, Version]);
        false -> ok
    end,
    NewVersion.


-spec update_version_ts(Version :: binary(), Ts :: integer()) -> ok | {error, any()}.
update_version_ts(Version, Ts) ->
    {ok, _Res} = q(["SET", version_key(Version), Ts]),
    {ok, _Res2} = q(["ZADD", all_versions_key(), Ts, Version]),
    ok.


-spec get_versions(MinTs :: integer(), MaxTs :: integer()) -> {ok, [binary()]}.
get_versions(MinTs, MaxTs) ->
    {ok, Versions} = q(
        ["ZRANGEBYSCORE", all_versions_key(), integer_to_binary(MinTs), integer_to_binary(MaxTs)]),
    {ok, Versions}.


-spec get_all_versions() -> {ok, [binary()]}.
get_all_versions() ->
    {ok, Versions} = q(
        ["ZRANGEBYSCORE", all_versions_key(), "-inf", "+inf"]),
    {ok, Versions}.


-spec version_key(Version :: binary()) -> binary().
version_key(Version) ->
    <<?CLIENT_VERSION_KEY/binary, Version/binary>>.

-spec all_versions_key() -> binary().
all_versions_key() ->
    ?CLIENT_VERSION_ALL_KEY.


q(Command) -> ecredis:q(ecredis_accounts, Command).

