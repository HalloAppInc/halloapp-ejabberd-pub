%%%-------------------------------------------------------------------
%%% Invites related migration code
%%%
%%% Copyright (C) halloapp inc.
%%%
%%%-------------------------------------------------------------------
-module(migrate_invites).
-author('nikola').

-include("logger.hrl").

-export([
    migrate_invites_run/2
]).


migrate_invites_run(Key, State) ->
    ?INFO_MSG("Key: ~p", [Key]),
    DryRun = maps:get(dry_run, State, false),
    Result = re:run(Key, "^inb:{([0-9]+)}", [global, {capture, all, binary}]),
    case Result of
        {match, [[_OldKey, Phone]]} ->
            % The old key is hash inb:{PHONE} => {id: Uid, ts: Timestamp}
            % The new key is zset ibn:{PHONE} => zset of Uids ordered by Timestamp
            {ok, Uid, TsStr} = q(ecredis_phone, ["HGET", model_invites:ph_invited_by_key(Phone), "id", "ts"]),
            Command =  ["ZADD", model_invites:ph_invited_by_key_new(Phone),
                util:to_integer(TsStr), Uid],
            case DryRun of
                true ->
                    ?INFO("Migrated invite Phone: ~p, Uid: ~p, Ts: ~p, Command: ~p",
                        [Phone, Uid, TsStr, Command]);
                false ->
                    {ok, Res} = q(ecredis_phone, Command),
                    ?INFO("Migrated invite Phone: ~p, Uid: ~p, Ts: ~p, Command: ~p, Res: ~p",
                        [Phone, Uid, TsStr, Command, Res])
            end;
        _ -> ok
    end,
    State.

q(Client, Commands) -> util_redis:q(Client, Commands).

