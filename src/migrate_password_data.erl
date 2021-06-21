%%%-------------------------------------------------------------------
%%% Temporary file to delete pwd data.
%%%
%%% Copyright (C) halloapp inc.
%%%
%%%-------------------------------------------------------------------
-module(migrate_password_data).
-author('murali').

-include("logger.hrl").

-export([
    remove_password_key/2
]).


remove_password_key(Key, State) ->
    ?INFO("Key: ~p", [Key]),
    DryRun = maps:get(dry_run, State, false),
    Result = re:run(Key, "^pas:.*", [global, {capture, all, binary}]),
    case Result of
        {match, _} ->
            Command = ["DEL", Key],
            case DryRun of
                true ->
                    ?INFO("Key: ~p, would run command: ~p", [Key, Command]);
                false ->
                    ok = ecredis:q(ecredis_auth, Command)
            end;
        _ -> ok
    end,
    State.

