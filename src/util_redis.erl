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

%% API
-export([
    decode_ts/1,
    decode_int/1,
    decode_maybe_binary/1,
    encode_maybe_binary/1,
    q/2,
    qp/2
]).


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

