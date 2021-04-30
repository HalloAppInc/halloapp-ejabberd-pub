%%%-------------------------------------------------------------------
%%% Invites related migration code
%%%
%%% Copyright (C) halloapp inc.
%%%
%%%-------------------------------------------------------------------
-module(migrate_invites).
-author('nikola').

-include("logger.hrl").
-include("time.hrl").

-export([
    expire_invites_run/2,
    cleanup_old_invites_sets_start/1,
    cleanup_old_invite_sets_run/2
]).

expire_invites_run(Key, #{service := RService} = State) ->
    DryRun = maps:get(dry_run, State, false),
    Result = re:run(Key, "^(in2|ibn):{([0-9]+)}$", [global, {capture, all, binary}]),
    case Result of
        {match, [[FullKey, _Prefix, _ID]]} ->
            TTL = 60 * ?DAYS,
            Command = ["EXPIRE", FullKey, TTL],
            case DryRun of
                true ->
                    ?INFO("would expire invite ~p", [Command]);
                false ->
                    {ok, Res} = q(ha_redis:get_client(RService), Command),
                    ?INFO("executing ~p Res: ~p", [Command, Res])
            end,
            ok;
        _ -> ok
    end,
    State.


-spec cleanup_old_invites_sets_start(Options :: redis_migrate:options()) -> ok.
cleanup_old_invites_sets_start(Options) ->
    redis_migrate:start_migration("cleanup_old_invites_sets", redis_accounts,
        {?MODULE, cleanup_old_invite_sets_run}, Options).


cleanup_old_invite_sets_run(Key, #{service := RService} = State) ->
    DryRun = maps:get(dry_run, State, false),
    Result = re:run(Key, "^inv:{([0-9]+)}$", [global, {capture, all, binary}]),
    case Result of
        {match, [[FullKey, _Uid]]} ->
            Command = ["DEL", FullKey],
            case DryRun of
                true ->
                    ?INFO("would delete old invites set ~p:~p", [RService, Command]);
                false ->
                    {ok, Res} = q(ecredis_accounts, Command),
                    ?INFO("executing ~p:~p Res: ~p", [RService, Command, Res])
            end,
            ok;
        _ -> ok
    end,
    State.

q(Client, Commands) -> util_redis:q(Client, Commands).

