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
    verify_invites_run/2,
    copy_invites_run/2,
    cleanup_older_invites/2,
    copy_from_set_to_zset_run/2,
    expire_invites_run/2,
    cleanup_old_invites_sets_start/1,
    cleanup_old_invite_sets_run/2
]).

verify_invites_run(Key, State) ->
    Result = re:run(Key, "^inv:{([0-9]+)}", [global, {capture, all, binary}]),
    case Result of
        {match, [[_OldKey, Uid]]} ->
            % The old key is hash inb:{PHONE} => {id: Uid, ts: Timestamp}
            {ok, Phones1} = q(ecredis_accounts, ["SMEMBERS", model_invites:acc_invites_key(Uid)]),
            {ok, Phones2} = q(ecredis_accounts, ["ZRANGEBYSCORE", model_invites:invites_key(Uid), "-inf", "+inf"]),
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

copy_from_set_to_zset_run(Key, State) ->
    DryRun = maps:get(dry_run, State, false),
    Result = re:run(Key, "^inv:{([0-9]+)}", [global, {capture, all, binary}]),
    case Result of
        {match, [[InvitesSetKey, Uid]]} ->
            % We have some invites stored here, but we don't know the timestamp store in the zsets
            {ok, Phones} = q(ecredis_accounts, ["SMEMBERS", InvitesSetKey]),

            lists:foreach(
                fun(Phone) ->
                    {ok, Score1} = q(ecredis_phone, ["ZSCORE", model_invites:ph_invited_by_key_new(Phone), Uid]),
                    {ok, Score2} = q(ecredis_accounts, ["ZSCORE", model_invites:invites_key(Uid), Phone]),
                    case {Score1, Score2} of
                        % invite is old and missing from the zsets. Insert in both
                        {undefined, undefined} ->
                            ?INFO("Uid: ~p invited Phone: ~p, at unknown time", [Uid, Phone]),
                            Ts = util:now() - 60 * ?DAYS, % just something old. It will be expired soon anyway
                            Command1 = ["ZADD", model_invites:ph_invited_by_key_new(Phone), Ts, Uid],
                            Command2 = ["ZADD", model_invites:invites_key(Uid), Ts, Phone],
                            case DryRun of
                                true ->
                                    ?INFO("Would run ~p", [Command1]),
                                    ?INFO("Would run ~p", [Command2]);
                                false ->
                                    Res1 = q(ecredis_phone, Command1),
                                    ?INFO("Running ~p -> ~p", [Command1, Res1]),
                                    Res2 = q(ecredis_accounts, Command2),
                                    ?INFO("Running ~p -> ~p", [Command2, Res2]),
                                    ok
                            end;
                        % if the score is the same in both zsets everything is good.
                        {Score1, Score1} ->
                            ?INFO("All good for Uid: ~p Phone: ~p", [Uid, Phone]);
                        % if the scores are not the same something is bad, hopefully this does not happen.
                        Scores ->
                            ?WARNING("Uid: ~p Phone: ~p Scores: ~p", [Uid, Phone, Scores])
                    end
                end,
                Phones
            );
        _ -> ok
    end,
    State.


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
                    {ok, Res} = q(RService, Command),
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
                    {ok, Res} = q(RService, Command),
                    ?INFO("executing ~p:~p Res: ~p", [RService, Command, Res])
            end,
            ok;
        _ -> ok
    end,
    State.

q(Client, Commands) -> util_redis:q(Client, Commands).

