%%%-------------------------------------------------------------------
%%% @author nikola
%%% @copyright (C) 2020, Halloapp Inc.
%%% @doc
%%%
%%% @end
%%% Created : 08. Jun 2020 1:30 PM
%%%-------------------------------------------------------------------
-module(util_redis).
-author("nikola").

-include("util_redis.hrl").

%% API
-export([
    decode_ts/1,
    decode_int/1,
    decode_maybe_binary/1,
    encode_maybe_binary/1,
    q/2,
    qp/2,
    eredis_hash/1,
    encode_boolean/1,
    decode_boolean/1,
    decode_boolean/2,
    parse_zrange_with_scores/1,
    get_redis_client/1
]).


%% TODO(murali@): Update to use this util function in other redis model files.
eredis_hash(Key) when is_list(Key) ->
    eredis_cluster_hash:hash(Key) rem ?NUM_SLOTS;
eredis_hash(Key) when is_binary(Key) ->
    eredis_cluster_hash:hash(binary_to_list(Key)) rem ?NUM_SLOTS.


decode_ts(TsMsBinary) ->
    decode_int(TsMsBinary).


decode_int(Bin) ->
    case Bin of
        undefined -> undefined;
        _ -> binary_to_integer(Bin)
    end.


-spec decode_maybe_binary(Bin :: binary()) -> undefined | binary().
decode_maybe_binary(<<>>) -> undefined;
decode_maybe_binary(Bin) -> Bin.


-spec encode_maybe_binary(Bin :: undefined | binary()) -> binary().
encode_maybe_binary(undefined) -> <<>>;
encode_maybe_binary(Bin) -> Bin.


q(Client, Command) ->
    {ok, Result} = gen_server:call(Client, {q, Command}),
    Result.


qp(Client, Commands) ->
    {ok, Result} = gen_server:call(Client, {qp, Commands}),
    Result.


encode_boolean(true) -> <<"1">>;
encode_boolean(false) -> <<"0">>.

decode_boolean(<<"1">>) -> true;
decode_boolean(<<"0">>) -> false.

decode_boolean(<<"1">>, _DefaultValue) -> true;
decode_boolean(<<"0">>, _DefaultValue) -> false;
decode_boolean(_, DefaultValue) -> DefaultValue.


-spec parse_zrange_with_scores(L :: []) -> [{term(), term()}].
parse_zrange_with_scores(L) ->
    parse_zrange_with_scores(L, []).

parse_zrange_with_scores([], Res) ->
    lists:reverse(Res);
parse_zrange_with_scores([El, Score | Rest], Res) ->
    parse_zrange_with_scores(Rest, [{El, Score} | Res]).

%% used only in migration modules
%% example of a service is redis_accounts
get_redis_client(Service) ->
    list_to_atom(atom_to_list(Service) ++"_client").
