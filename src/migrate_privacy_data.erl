%%%-------------------------------------------------------------------
%%% Temporary file to migrate and rename privacy lists in our database.
%%%
%%% Copyright (C) halloapp inc.
%%%
%%%-------------------------------------------------------------------
-module(migrate_privacy_data).
-author('murali').

-include("logger.hrl").

-export([
	run/2,
	verify/2,
	cleanup/2
]).


%%% Stage 1. Rename the privacy lists: both exceptlist and onlylist.
run(Key, State) ->
    ?INFO("Key: ~p", [Key]),
    DryRun = maps:get(dry_run, State, false),
    Result = re:run(Key, "^(bla|whi):{([0-9]+)}$", [global, {capture, all, binary}]),
    case Result of
        {match, [[OldKey, Prefix, Uid]]} ->
            NewKey = get_buddy_privacy_key(Prefix, Uid),
            ?INFO("Migrating ~s -> ~s Uid: ~s", [OldKey, NewKey, Uid]),
            Command = ["SUNIONSTORE", NewKey, OldKey, NewKey],
            case DryRun of
                true ->
                    ?INFO("would do: ~p", [Command]);
                false ->
                    {ok, NumItems} = q(ecredis_accounts, Command),
                    ?INFO("stored ~p uids", [NumItems])
            end;
        _ -> ok
    end,
    State.


%%% Stage 2. Check if the migrated data is in sync
verify(Key, State) ->
    ?INFO("Key: ~p", [Key]),
    Result = re:run(Key, "^(bla|whi|exc|onl):{([0-9]+)}$", [global, {capture, all, binary}]),
    case Result of
        {match, [[Key1, Prefix, Uid]]} ->
            Key2 = get_buddy_privacy_key(Prefix, Uid),
            ?INFO("Checking ~s vs ~s Uid: ~s", [Key1, Key2, Uid]),
            [{ok, Items1}, {ok, Items2}] = qp(ecredis_accounts, [
                ["SMEMBERS", Key1],
                ["SMEMBERS", Key2]
            ]),
            case Items1 =:= Items2 of
                true ->
                    ?INFO("match ~s ~s items: ~p", [Key1, Key2, length(Items2)]);
                false ->
                    ?ERROR("NO match ~s : ~p, vs ~s : ~p", [Key1, Items1, Key2, Items2])
            end;
        _ -> ok
    end,
    State.


%%% Stage 3. Delete the old data
cleanup(Key, State) ->
    ?INFO("Key: ~p", [Key]),
    DryRun = maps:get(dry_run, State, false),
    Result = re:run(Key, "^(bla|whi):{([0-9]+)}$", [global, {capture, all, binary}]),
    case Result of
        {match, [[_FullKey, _Prefix, Uid]]} ->
            ?INFO("Cleaning ~s Uid: ~s", [Key, Uid]),
            Command = ["DEL", Key],
            case DryRun of
                true ->
                    ?INFO("would do: ~p", [Command]);
                false ->
                    DelResult = q(ecredis_accounts, Command),
                    ?INFO("delete result ~p", [DelResult])
            end;
        _ -> ok
    end,
    State.


-spec get_buddy_privacy_key(Prefix :: binary(), Uid :: binary()) -> binary().
get_buddy_privacy_key(<<"exc">>, Uid) ->
    list_to_binary("bla:{" ++ binary_to_list(Uid) ++ "}");
get_buddy_privacy_key(<<"onl">>, Uid) ->
    list_to_binary("whi:{" ++ binary_to_list(Uid) ++ "}");
get_buddy_privacy_key(<<"whi">>, Uid) ->
    list_to_binary("onl:{" ++ binary_to_list(Uid) ++ "}");
get_buddy_privacy_key(<<"bla">>, Uid) ->
    list_to_binary("exc:{" ++ binary_to_list(Uid) ++ "}").


q(Client, Command) -> util_redis:q(Client, Command).
qp(Client, Commands) -> util_redis:qp(Client, Commands).

