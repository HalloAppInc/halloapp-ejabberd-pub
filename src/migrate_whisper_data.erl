%%%-------------------------------------------------------------------
%%% Temporary file to delete whisper-subscriber data.
%%%
%%% Copyright (C) halloapp inc.
%%%
%%%-------------------------------------------------------------------
-module(migrate_whisper_data).
-author('murali').

-include("logger.hrl").

-export([
    remove_subscribers_key/2
]).


remove_subscribers_key(Key, State) ->
    ?INFO("Key: ~p", [Key]),
    DryRun = maps:get(dry_run, State, false),
    Result = re:run(Key, "^wsub:.*", [global, {capture, all, binary}]),
    case Result of
        {match, _} ->
            Command = ["DEL", Key],
            case DryRun of
                true ->
                    ?INFO("Key: ~p, would run command: ~p", [Key, Command]);
                false ->
                    ok = ecredis:q(ecredis_whisper, Command)
            end;
        _ -> ok
    end,
    State.

