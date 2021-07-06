%%%-------------------------------------------------------------------
%%% Temporary file to migrate messages
%%%
%%% Copyright (C) halloapp inc.
%%%
%%%-------------------------------------------------------------------
-module(migrate_messages).
-author('murali').

-include("logger.hrl").
-include("account.hrl").

-export([
    clean_messages_run/2
]).


%% Cleanup end-of-queue messages that were accidentally stored.
clean_messages_run(Key, State) ->
    DryRun = maps:get(dry_run, State, false),
    Result = re:run(Key, "msg:{([0-9]+)}:.*$", [global, {capture, all, binary}]),
    case Result of
        {match, [[FullKey, _Uid]]} ->
            [{ok, TTL}, {ok, DataArr}] = qp(ecredis_messages, [
                ["TTL", FullKey],
                ["HGETALL", FullKey]]),
            case {TTL, DataArr} of
                {<<"-1">>, [<<"rc">>, <<"1">>]} ->
                    delete_key(FullKey, DryRun);
                {<<"-1">>, [<<"snt">>, <<"1">>]} ->
                    delete_key(FullKey, DryRun);
                {<<"-1">>, Any} ->
                    ?INFO("unexpected-message Key:~p Items: ~p", [FullKey, Any]);
                _ ->
                    ?INFO("normal key ~p: TTL ~p", [FullKey, TTL])
            end;
        _ -> ok
    end,
    State.

delete_key(FullKey, DryRun) ->
    Command = ["DEL", FullKey],
    case DryRun of
        true ->
            ?INFO("Would execute ~p", [Command]);
        false ->
            Res = q(ecredis_messages, Command),
            ?INFO("Executing ~p res: ~p", [Command, Res])
    end.


q(Client, Command) -> util_redis:q(Client, Command).
qp(Client, Commands) -> util_redis:qp(Client, Commands).

