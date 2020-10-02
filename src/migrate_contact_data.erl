%%%-------------------------------------------------------------------
%%% Temporary file to migrate contact data and remove unregistered phone numbers.
%%%
%%% Copyright (C) halloapp inc.
%%%
%%%-------------------------------------------------------------------
-module(migrate_contact_data).
-author('murali').

-include("logger.hrl").
-include("contacts.hrl").

-export([
    rename_reverse_contacts_run/2,
    rename_reverse_contacts_verify/2,
    rename_reverse_contacts_cleanup/2,
    remove_unregistered_numbers_run/2,
    remove_unregistered_numbers_verify/2,
    expire_sync_keys_run/2
]).


%%% Stage 1. Move the data.
rename_reverse_contacts_run(Key, State) ->
    ?INFO("Key: ~p", [Key]),
    DryRun = maps:get(dry_run, State, false),
    Result = re:run(Key, "^sync:{([0-9]+)}$", [global, {capture, all, binary}]),
    case Result of
        {match, [[_FullKey, Phone]]} ->
            NewKey = list_to_binary("rev:{" ++ binary_to_list(Phone) ++ "}"),
            ?INFO("Migrating ~s -> ~s phone: ~s", [Key, NewKey, Phone]),
            Command = ["SUNIONSTORE", NewKey, Key, NewKey],
            case DryRun of
                true ->
                    ?INFO("would do: ~p", [Command]);
                false ->
                    {ok, NumItems} = q(redis_contacts_client, Command),
                    ?INFO("stored ~p uids", [NumItems])
            end;
        _ -> ok
    end,
    State.


%%% Stage 2. Check if the migrated data is in sync
rename_reverse_contacts_verify(Key, State) ->
    ?INFO("Key: ~p", [Key]),
    Result = re:run(Key, "^(sync|rev):{([0-9]+)}$", [global, {capture, all, binary}]),
    case Result of
        {match, [[_FullKey, _Prefix, Phone]]} ->
            OldKey = list_to_binary("sync:{" ++ binary_to_list(Phone) ++ "}"),
            NewKey = list_to_binary("rev:{" ++ binary_to_list(Phone) ++ "}"),
            ?INFO("Checking ~s vs ~s phone: ~s", [OldKey, NewKey, Phone]),
            [{ok, OldItems}, {ok, NewItems}] = qp(redis_contacts_client, [
                ["SMEMBERS", OldKey],
                ["SMEMBERS", NewKey]
            ]),
            case OldItems =:= NewItems of
                true ->
                    ?INFO("match ~s ~s items: ~p", [OldKey, NewKey, length(NewItems)]);
                false ->
                    ?ERROR("NO match ~s : ~p, vs ~s : ~p", [OldKey, OldItems, NewKey, NewItems])
            end;
        _ -> ok
    end,
    State.


%%% Stage 3. Delete the old data
rename_reverse_contacts_cleanup(Key, State) ->
    ?INFO("Key: ~p", [Key]),
    DryRun = maps:get(dry_run, State, false),
    Result = re:run(Key, "^sync:{([0-9]+)}$", [global, {capture, all, binary}]),
    case Result of
        {match, [[_FullKey, Phone]]} ->
            ?INFO("Cleaning ~s phone: ~s", [Key, Phone]),
            Command = ["DEL", Key],
            case DryRun of
                true ->
                    ?INFO("would do: ~p", [Command]);
                false ->
                    DelResult = q(redis_contacts_client, Command),
                    ?INFO("delete result ~p", [DelResult])
            end;
        _ -> ok
    end,
    State.


%% Stage1: Remove the unregistered phone numbers in our database.
remove_unregistered_numbers_run(Key, State) ->
    ?INFO("Key: ~p", [Key]),
    DryRun = maps:get(dry_run, State, false),
    Result = re:run(Key, "rev:{([0-9]+)}$", [global, {capture, all, binary}]),
    case Result of
        {match, [[_FullKey, Phone]]} ->
            {ok, Uid} = model_phone:get_uid(Phone),
            case Uid of
                undefined ->
                    ?INFO("Removing key ~s, phone: ~s", [Key, Phone]),
                    {ok, ContactUids} = model_contacts:get_contact_uids(Phone),
                    Command = ["DEL", Key],
                    case DryRun of
                        true ->
                            ?INFO("would do: ~p, and cleanup forward index for ~p",
                                    [Command, ContactUids]);
                        false ->
                            lists:foreach(
                                fun(ContactUid) ->
                                    model_contacts:remove_contact(ContactUid, Phone)
                                end, ContactUids),
                            {ok, _} = q(redis_contacts_client, Command),
                            ?INFO("deleted key: ~p", [Key])
                    end;
                _ -> ok
            end;
        _ -> ok
    end,
    State.


%%% Stage 2. Check if the remaining data is correct.
remove_unregistered_numbers_verify(Key, State) ->
    ?INFO("Key: ~p", [Key]),
    Result = re:run(Key, "^rev:{([0-9]+)}$", [global, {capture, all, binary}]),
    case Result of
        {match, [[_FullKey, Phone]]} ->
            {ok, Uid} = model_phone:get_uid(Phone),
            case Uid of
                undefined -> ?ERROR("This key still exists: ~p, phone: ~p", [Key, Phone]);
                _ -> ok
            end;
        _ -> ok
    end,
    State.


%%% Stage 1. Set expiry for the data.
expire_sync_keys_run(Key, State) ->
    ?INFO("Key: ~p", [Key]),
    DryRun = maps:get(dry_run, State, false),
    Result = re:run(Key, "^sync:{([0-9]+)}$", [global, {capture, none}]),
    case Result of
        match ->
            Command = ["EXPIRE", Key, ?SYNC_KEY_TTL],
            case DryRun of
                true ->
                    ?INFO("would do: ~p", [Command]);
                false ->
                    [{ok, _}, {ok, TTL}] = qp(
                            redis_contacts_client,
                            [Command,
                            ["TTL", Key]]),
                    ?INFO("key ~p ttl: ~p", [Key, TTL])
            end;
        _ -> ok
    end,
    State.


q(Client, Command) -> util_redis:q(Client, Command).
qp(Client, Commands) -> util_redis:qp(Client, Commands).

