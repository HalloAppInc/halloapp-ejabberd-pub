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

-define(NUM_SLOTS, 256).

%% API
-export([
    decode_ts/1,
    decode_int/1,
    decode_maybe_binary/1,
    encode_maybe_binary/1,
    q/2,
    qp/2,
    eredis_hash/1
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

