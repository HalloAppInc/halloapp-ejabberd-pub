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
    decode_ts/1
]).

decode_ts(TsMsBinary) ->
    case TsMsBinary of
        undefined -> undefined;
        X -> binary_to_integer(X)
    end.

