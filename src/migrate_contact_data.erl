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
-include("account.hrl").

-export([
    remove_unregistered_numbers_run/2,
    remove_unregistered_numbers_verify/2,
    trigger_full_sync_run/2,
    find_empty_contact_list_accounts/2,
    remove_phone_hash_key/2,
    remove_stale_sync_key/2,
    mark_first_sync_run/2,
    cleanup_reverse_index_run/2,
    cleanup_codekey_run/2
]).


%% Stage1: Remove the unregistered phone numbers in our database.
remove_unregistered_numbers_run(Key, State) ->
    ?INFO("Key: ~p", [Key]),
    DryRun = maps:get(dry_run, State, false),
    Result = re:run(Key, "rev:{([0-9]+)}$", [global, {capture, all, binary}]),
    case Result of
        {match, [[_FullKey, Phone]]} ->
            {ok, Uid} = model_phone:get_uid(Phone, halloapp),
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
                            {ok, _} = q(ecredis_contacts, Command),
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
            {ok, Uid} = model_phone:get_uid(Phone, halloapp),
            case Uid of
                undefined -> ?ERROR("This key still exists: ~p, phone: ~p", [Key, Phone]);
                _ -> ok
            end;
        _ -> ok
    end,
    State.


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%                            Trigger full sync                                       %%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

trigger_full_sync_run(Key, State) ->
    ?INFO("Key: ~p", [Key]),
    DryRun = maps:get(dry_run, State, false),
    Result = re:run(Key, "^acc:{([0-9]+)}$", [global, {capture, all, binary}]),
    case Result of
        {match, [[_FullKey, Uid]]} ->
            ?INFO("Account uid: ~p", [Uid]),
            case DryRun of
                true ->
                    ?INFO("would send empty hash to: ~p", [Uid]);
                false ->
                    ok = mod_contacts:trigger_full_contact_sync(Uid),
                    ?INFO("sent empty hash to: ~p", [Uid])
            end;
        _ -> ok
    end,
    State.


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%                         Find number of users with no contacts                      %%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

find_empty_contact_list_accounts(Key, State) ->
    ?INFO("Key: ~p", [Key]),
    Result = re:run(Key, "^acc:{([0-9]+)}$", [global, {capture, all, binary}]),
    case Result of
        {match, [[_FullKey, Uid]]} ->
            ?INFO("Account uid: ~p", [Uid]),
            {ok, ContactList} = model_contacts:get_contacts(Uid),
            Version = case model_accounts:get_client_version(Uid) of
                {ok, V} -> V;
                _ -> undefined
            end,
            case ContactList of
                [] ->
                    ?INFO("Uid: ~p, version: ~p has empty contact list",
                        [Uid, Version]), % can be undefined version
                    migrate_utils:user_details(Uid); % prints details
                _ ->
                    ?INFO("Uid: ~p, version: ~p has contact list of length ~p",
                        [Uid, Version, length(ContactList)]) % can be undefined version
            end,
            ok;
        _ -> ok
    end,
    State.


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%                         Remove reverse keys of hashed phones                      %%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

remove_phone_hash_key(Key, State) ->
    ?INFO("Key: ~p", [Key]),
    DryRun = maps:get(dry_run, State, false),
    Result = re:run(Key, "^rph:.*", [global, {capture, all, binary}]),
    case Result of
        {match, _} ->
            Command = ["DEL", Key],
            case DryRun of
                true ->
                    ?INFO("Key: ~p, would run command: ~p", [Key, Command]);
                false ->
                    Res = ecredis:q(ecredis_contacts, Command),
                    ?INFO("Key: ~p, result: ~p", [Key, Res])
            end;
        _ -> ok
    end,
    State.


remove_stale_sync_key(Key, State) ->
%%    ?INFO("Key: ~p", [Key]),
    DryRun = maps:get(dry_run, State, false),
    Result = re:run(Key, "^sync:.*", [global, {capture, all, binary}]),
    case Result of
        {match, _} ->
            {ok, TTL} = q(ecredis_contacts, ["TTL", Key]),
            ?INFO("Key ~p has TTL ~p", [Key, TTL]),
            case TTL of
                <<"-1">> ->
                    Command = ["DEL", Key],
                    case DryRun of
                        true ->
                            ?INFO("Key: ~p, would run command: ~p", [Key, Command]);
                        false ->
                            Res = q(ecredis_contacts, Command),
                            ?INFO("Key: ~p, result: ~p", [Key, Res])
                    end;
                _ -> ok
            end;
        _ -> ok
    end,
    State.


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%                        Mark users with their first sync done                    %%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

mark_first_sync_run(Key, State) ->
    ?INFO("Key: ~p", [Key]),
    DryRun = maps:get(dry_run, State, false),
    Result = re:run(Key, "^acc:{([0-9]+)}$", [global, {capture, all, binary}]),
    case Result of
        {match, [[_FullKey, Uid]]} ->
            {ok, ContactList} = model_contacts:get_contacts(Uid),
            NumContacts = length(ContactList),
            case DryRun of
                false ->
                    {ok, IsFirstSync} = model_accounts:mark_first_sync_done(Uid),
                    ?INFO("Account uid: ~p, NumContacts: ~p, IsFirstSync: ~p",
                        [Uid, NumContacts, IsFirstSync]);
                true ->
                    ?INFO("Account uid: ~p, NumContacts: ~p", [Uid, NumContacts])
            end,
            ok;
        _ -> ok
    end,
    State.


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%                        Cleanup reverse index run                                  %%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

cleanup_reverse_index_run(Key, State) ->
    ?INFO("Key: ~p", [Key]),
    DryRun = maps:get(dry_run, State, false),
    Result = re:run(Key, "^rev:{([0-9]+)}$", [global, {capture, all, binary}]),
    case Result of
        {match, [[ReverseKey, Phone]]} ->
            {ok, ContactUids} = model_contacts:get_contact_uids(Phone),
            % _NumContactUids = length(ContactUids),
            lists:foreach(
                fun(ContactUid) ->
                    case model_accounts:get_account(ContactUid) of
                        {ok, _} -> ok;
                        {error, missing} ->
                            Command = ["SREM", ReverseKey, ContactUid],
                            case DryRun of
                                true ->
                                    ?INFO("Phone: ~p, ContactUid: ~p is missing, command: ~p",
                                        [Phone, ContactUid, Command]);
                                false ->
                                    {ok, Result2} = q(ecredis_contacts, Command),
                                    ?INFO("Phone: ~p, ContactUid: ~p is missing, removed res: ~p",
                                        [Phone, ContactUid, Result2])
                            end
                    end
                end, ContactUids);
        _ -> ok
    end,
    State.


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%                        Cleanup code_key run                               %%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

cleanup_codekey_run(Key, State) ->
    ?INFO("Key: ~p", [Key]),
    DryRun = maps:get(dry_run, State, false),
    Result = re:run(Key, "^pho:{([0-9]+)}$", [global, {capture, all, binary}]),
    case Result of
        {match, [[FullKey, Phone]]} ->
            Command = ["DEL", FullKey],
            case DryRun of
                true ->
                    ?INFO("Phone: ~p, Command: ~p", [Phone, Command]);
                false ->
                    {ok, Result2} = q(ecredis_phone, Command),
                    ?INFO("Phone: ~p, removed res: ~p", [Phone, Result2])
            end;
        _ -> ok
    end,
    State.


q(Client, Command) -> util_redis:q(Client, Command).
