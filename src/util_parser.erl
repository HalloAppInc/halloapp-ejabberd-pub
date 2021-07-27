%%%----------------------------------------------------------------------
%%% File    : util_parser.erl
%%%
%%% Copyright (C) 2020 halloappinc.
%%%
%%% This module handles utility functions related to parser modules.
%%%----------------------------------------------------------------------

-module(util_parser).
-author('murali').

-export([
    maybe_convert_to_binary/1,
    maybe_convert_to_integer/1,
    maybe_base64_encode_binary/1
]).

%% Export all functions for unit tests
-ifdef(TEST).
-compile(export_all).
-endif.


maybe_convert_to_binary(undefined) -> undefined;
maybe_convert_to_binary(Data) -> util:to_binary(Data).

maybe_convert_to_integer(undefined) -> undefined;
maybe_convert_to_integer(<<>>) -> undefined;
maybe_convert_to_integer(Data) -> util:to_integer(Data).


maybe_base64_encode_binary(undefined) -> <<>>;
maybe_base64_encode_binary(Data) -> base64:encode(Data).

