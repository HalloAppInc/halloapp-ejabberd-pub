%%%-------------------------------------------------------------------
%%% Redis migrations to count langId for all accounts.
%%%
%%% Copyright (C) halloapp inc.
%%%
%%%-------------------------------------------------------------------
-module(migrate_lang_counters).
-author('murali').

-include("logger.hrl").
-include("util_redis.hrl").

-export([
    count_lang_run/2
]).


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%                         Count langId for all user accounts                        %%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

count_lang_run(Key, State) ->
    ?INFO("Key: ~p", [Key]),
    DryRun = maps:get(dry_run, State, false),
    Result = re:run(Key, "^acc:{([0-9]+)}$", [global, {capture, all, binary}]),
    case Result of
        {match, [[FullKey, Uid]]} ->
            ?INFO("Account uid: ~p", [Uid]),
            {ok, LangId} = q(ecredis_accounts, ["HGET", FullKey, <<"pl">>]),
            case LangId of
                undefined ->
                    ?ERROR("Uid: ~p, LangId is undefined!", [Uid]);
                _ ->
                    HashSlot = util_redis:eredis_hash(binary_to_list(Uid)),
                    Slot = HashSlot rem ?NUM_SLOTS,
                    Command = ["HINCRBY", model_accounts:lang_key(Slot), LangId, 1],
                    case DryRun of
                        true ->
                            ?INFO("Uid: ~p, would run command: ~p", [Uid, Command]);
                        false ->
                            Res = ecredis:q(ecredis_accounts, Command),
                            ?INFO("Uid: ~p, result: ~p", [Uid, Res])
                    end
            end;
        _ -> ok
    end,
    State.


q(Client, Command) -> util_redis:q(Client, Command).
qp(Client, Commands) -> util_redis:qp(Client, Commands).

