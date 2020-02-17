%%%----------------------------------------------------------------------
%%% File    : util.erl
%%%
%%% Copyright (C) 2020 halloappinc.
%%%
%%% This module handles all the utility functions used in various other modules.
%%%----------------------------------------------------------------------

-module(util).

-export([convert_timestamp_to_binary/1, cur_timestamp/0,
			convert_timestamp_secs_to_integer/1, convert_binary_to_integer/1]).

%% Combines the MegaSec and Seconds part of the timestamp into a binary and returns it.
%% Expects an erlang timestamp as input.
-spec convert_timestamp_to_binary(erlang:timestamp()) -> binary().
convert_timestamp_to_binary(Timestamp) ->
    {T1, T2, _} = Timestamp,
    list_to_binary(integer_to_list(T1*1000000 + T2)).


%% Returns current Erlang system time on the format {MegaSecs, Secs, MicroSecs}
-spec cur_timestamp() -> erlang:timestamp().
cur_timestamp() ->
    erlang:timestamp().


%% Converts an erlang timestamp to seconds in integer.
-spec convert_timestamp_secs_to_integer(erlang:timestamp()) -> integer().
convert_timestamp_secs_to_integer(Timestamp) ->
    list_to_integer(binary_to_list(convert_timestamp_to_binary(Timestamp))).


-spec convert_binary_to_integer(binary()) -> integer().
convert_binary_to_integer(BinaryInput) ->
	list_to_integer(binary_to_list(BinaryInput)).
