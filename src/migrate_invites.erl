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
    cleanup_older_invites/2
]).


cleanup_older_invites(Key, State) ->
    DryRun = maps:get(dry_run, State, false),
    Result = re:run(Key, "^inb:{([0-9]+)}", [global, {capture, all, binary}]),
    case Result of
        {match, [[OldKey, Phone]]} ->
            % The old key is hash inb:{PHONE} => {id: Uid, ts: Timestamp}
            % The new key is zset ibn:{PHONE} => zset of Uids ordered by Timestamp
            {ok, [Uid, TsStr]} = q(ecredis_phone, ["HMGET", OldKey, "id", "ts"]),

            % Check one more time the data is in the new datastructure
            {ok, Score} = q(ecredis_phone, ["ZSCORE", model_invites:ph_invited_by_key_new(Phone), Uid]),
            case Score of
                undefined -> ?ERROR("Old data not copied Phone: ~p Uid: ~p", [Phone, Uid]);
                TsStr -> ?INFO("data-migrated-ok, ~p", [Phone]);
                Score -> ?INFO("different score ~p for Phone:~p Uid:~p", [Score, Phone, Uid])
            end,

            Command =  ["DEL", OldKey],
            case DryRun of
                true ->
                    ?INFO("Will delete old invited struct Phone: ~p, Command: ~p",
                        [Phone, Command]);
                false ->
                    {ok, Res} = q(ecredis_phone, Command),
                    ?INFO("Deleted old invited struct Phone: ~p, Command: ~p Res: ~p",
                        [Phone, Command, Res])
            end;
        _ -> ok
    end,
    State.

q(Client, Commands) -> util_redis:q(Client, Commands).

