%%%----------------------------------------------------------------------
%%% File    : util.erl
%%%
%%% Copyright (C) 2020 halloappinc.
%%%
%%% This module handles all the utility functions used in various other modules.
%%%----------------------------------------------------------------------

-module(util).
-include("logger.hrl").

-export([
    timestamp_to_binary/1,
    cur_timestamp/0,
    timestamp_secs_to_integer/1,
    get_feed_pubsub_node_name/1,
    get_host/0,
    get_metadata_pubsub_node_name/1]).

%% Export all functions for unit tests
-ifdef(TEST).
-compile(export_all).
-endif.

-spec get_host() -> binary().
get_host() ->
	[H | []] = ejabberd_option:hosts(),
	H.

-spec now_ms() -> integer().
now_ms() ->
    os:system_time(millisecond).

%% Combines the MegaSec and Seconds part of the timestamp into a binary and returns it.
%% Expects an erlang timestamp as input.
-spec timestamp_to_binary(erlang:timestamp()) -> binary().
timestamp_to_binary(Timestamp) ->
    {T1, T2, _} = Timestamp,
    list_to_binary(integer_to_list(T1*1000000 + T2)).


%% Returns current Erlang system time on the format {MegaSecs, Secs, MicroSecs}
-spec cur_timestamp() -> erlang:timestamp().
cur_timestamp() ->
    erlang:timestamp().


%% Converts an erlang timestamp to seconds in integer.
-spec timestamp_secs_to_integer(erlang:timestamp()) -> integer().
timestamp_secs_to_integer(Timestamp) ->
    binary_to_integer(timestamp_to_binary(Timestamp)).

%% Using 'feed-' as the start of feed-node's name for now.
-spec get_feed_pubsub_node_name(binary()) -> binary().
get_feed_pubsub_node_name(User) ->
	list_to_binary("feed-" ++ binary_to_list(User)).

%% Using 'metadata-' as the start of feed-node's name for now.
-spec get_metadata_pubsub_node_name(binary()) -> binary().
get_metadata_pubsub_node_name(User) ->
	list_to_binary("metadata-" ++ binary_to_list(User)).

