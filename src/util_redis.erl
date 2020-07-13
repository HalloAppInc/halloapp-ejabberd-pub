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
    q/2,
    qp/2
]).

decode_ts(TsMsBinary) ->
    case TsMsBinary of
        undefined -> undefined;
        X -> binary_to_integer(X)
    end.

q(Client, Command) ->
    {ok, Result} = gen_server:call(Client, {q, Command}),
    Result.


qp(Client, Commands) ->
    {ok, Result} = gen_server:call(Client, {qp, Commands}),
    Result.

