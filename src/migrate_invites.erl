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
    verify_invites_run/2,
    copy_invites_run/2,
    cleanup_older_invites/2
]).

verify_invites_run(Key, State) ->
    Result = re:run(Key, "^inv:{([0-9]+)}", [global, {capture, all, binary}]),
    case Result of
        {match, [[_OldKey, Uid]]} ->
            % The old key is hash inb:{PHONE} => {id: Uid, ts: Timestamp}
            {ok, Phones1} = q(ecredis_account, ["SMEMBERS", model_invites:acc_invites_key(Uid)]),
            {ok, Phones2} = q(ecredis_account, ["ZRANGEBYSCORE", model_invites:invites_key(Uid), "-inf", "+inf"]),
            Phones1Sorted = lists:sort(Phones1),
            Phones2Sorted = lists:sort(Phones2),
            case Phones1Sorted =:= Phones2Sorted of
                true -> ?INFO("Invites match Uid: ~p Phones: ~p", [Uid, Phones1Sorted]);
                false -> ?WARNING("Invites mismatch Uid: ~p, OldPhones: ~p NewPhones: ~p",
                    [Uid, Phones1Sorted, Phones2Sorted])
            end,
            ok;
        _ -> ok
    end,
    State.


copy_invites_run(Key, State) ->
    DryRun = maps:get(dry_run, State, false),
    Result = re:run(Key, "^ibn:{([0-9]+)}", [global, {capture, all, binary}]),
    case Result of
        {match, [[_OldKey, Phone]]} ->
            {ok, InvitersList} = model_invites:get_inviters_list(Phone),
            lists:foreach(
                fun({Uid, TsBin}) ->
                    Command = ["ZADD", model_invites:invites_key(Uid), TsBin, Phone],
                    case DryRun of
                        true ->
                            ?INFO("would copy invite ~p", [Command]);
                        false ->
                            {ok, Res} = q(ecredis_accounts, Command),
                            ?INFO("executing ~p Res: ~p", [Command, Res])
                    end
                end,
                InvitersList),
            ok;
        _ -> ok
    end,
    State.


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

