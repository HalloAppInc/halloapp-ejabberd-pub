%%%-------------------------------------------------------------------
%%% Temporary file to delete pid data.
%%%
%%% Copyright (C) halloapp inc.
%%%
%%%-------------------------------------------------------------------
-module(migrate_session_data).
-author('murali').

-include("logger.hrl").

-export([
    remove_pid_key/2
]).


remove_pid_key(Key, State) ->
    ?INFO("Key: ~p", [Key]),
    DryRun = maps:get(dry_run, State, false),
    Result = re:run(Key, "^p:.*", [global, {capture, all, binary}]),
    case Result of
        {match, _} ->
            Command = ["DEL", Key],
            case DryRun of
                true ->
                    ?INFO("Key: ~p, would run command: ~p", [Key, Command]);
                false ->
                    ok = ecredis:q(ecredis_sessions, Command)
            end;
        _ -> ok
    end,
    State.

