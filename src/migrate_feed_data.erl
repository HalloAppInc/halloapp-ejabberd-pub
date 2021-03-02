%%%-------------------------------------------------------------------
%%% Temporary file to extend ttl for feedposts and comments.
%%%
%%% Copyright (C) halloapp inc.
%%%
%%%-------------------------------------------------------------------
-module(migrate_feed_data).
-author('murali').

-include("logger.hrl").
-include("feed.hrl").

-export([
    extend_ttl_run/2
]).


%%% Stage 1. extend ttl for feed keys.

extend_ttl_run(Key, State) ->
    ?INFO_MSG("Key: ~p", [Key]),
    DryRun = maps:get(dry_run, State, false),
    Result = re:run(Key, "^(fp|fpa|rfp|fc|fcp|fpc):{.*", [global, {capture, none}]),
    case Result of
        match ->
            {ok, TTL} = qp(ecredis_feed, ["TTL", Key]),
            NewTTL = binary_to_integer(TTL) + ?DAYS,
            Command = ["EXPIRE", Key, NewTTL],
            case DryRun of
                true ->
                    ?INFO_MSG("would do: ~p", [Command]);
                false ->
                    [{ok, _}, {ok, FinalTTL}] = qp(
                            ecredis_feed,
                            [Command,
                            ["TTL", Key]]),
                    ?INFO_MSG("key ~p ttl: ~p", [Key, FinalTTL])
            end;
        _ -> ok
    end,
    State.

qp(Client, Commands) -> util_redis:qp(Client, Commands).

