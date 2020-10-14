%%%-------------------------------------------------------------------
%%% Temporary file to expire messages.
%%%
%%% Copyright (C) halloapp inc.
%%%
%%%-------------------------------------------------------------------
-module(migrate_message_data).
-author('murali').

-include("logger.hrl").
-include("time.hrl").
-include("offline_message.hrl").

-export([
    expire_message_keys_run/2
]).


%%% Stage 1. Set expiry for the data.
expire_message_keys_run(Key, State) ->
    ?INFO_MSG("Key: ~p", [Key]),
    DryRun = maps:get(dry_run, State, false),
    Result = re:run(Key, "^(msg|mq):{.*", [global, {capture, none}]),
    case Result of
        match ->
            Command = ["EXPIRE", Key, ?MSG_EXPIRATION],
            case DryRun of
                true ->
                    ?INFO_MSG("would do: ~p", [Command]);
                false ->
                    [{ok, _}, {ok, TTL}] = qp(
                            redis_messages_client,
                            [Command,
                            ["TTL", Key]]),
                    ?INFO_MSG("key ~p ttl: ~p", [Key, TTL])
            end;
        _ -> ok
    end,
    State.


qp(Client, Commands) -> util_redis:qp(Client, Commands).

