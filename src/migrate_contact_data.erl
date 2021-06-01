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
    rename_reverse_contacts_run/2,
    rename_reverse_contacts_verify/2,
    rename_reverse_contacts_cleanup/2,
    remove_unregistered_numbers_run/2,
    remove_unregistered_numbers_verify/2,
    trigger_full_sync_run/2,
    find_empty_contact_list_accounts/2,
    find_messy_accounts/2,
    fix_contacts_ttl/2
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
                    {ok, NumItems} = q(ecredis_contacts, Command),
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
            [{ok, OldItems}, {ok, NewItems}] = qp(ecredis_contacts, [
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
                    DelResult = q(ecredis_contacts, Command),
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
            {ok, Uid} = model_phone:get_uid(Phone),
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
        {match, [[FullKey, Uid]]} ->
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
%%          Finds accounts with zero contacts, but non-zero friends                   %%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

find_messy_accounts(Key, State) ->
    ?INFO("Key: ~p", [Key]),
    Result = re:run(Key, "^acc:{([0-9]+)}$", [global, {capture, all, binary}]),
    case Result of
        {match, [[FullKey, Uid]]} ->
            ?INFO("Account uid: ~p", [Uid]),
            {ok, ContactList} = model_contacts:get_contacts(Uid),
            {ok, FriendsList} = model_friends:get_friends(Uid),
            NumContactsList = length(ContactList),
            NumFriendsList = length(FriendsList),
            try
                case model_accounts:get_account(Uid) of
                    {ok, Account} ->
                        ClientVersion = Account#account.client_version,
                        LastSeenTsMs = Account#account.last_activity_ts_ms,
                        case NumContactsList =:= 0 andalso NumFriendsList =/= 0 of
                            true ->
                                ?INFO("Uid: ~p, NumContactsList: ~p, NumFriendsList: ~p, version: ~p, last_seen: ~p",
                                        [Uid, NumContactsList, NumFriendsList, ClientVersion, LastSeenTsMs]),
                                ok;
                            false ->
                                ok
                        end;
                    _ ->
                        ?ERROR("Uid: ~p, no account exists here", [Uid])
                end
            catch
                _:_ ->
                    ?ERROR("Uid: ~p, no account exception here", [Uid])
            end,
            ok;
        _ -> ok
    end,
    State.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%                                Fix messy accounts                                  %%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

fix_messy_accounts(Key, State) ->
    DryRun = maps:get(dry_run, State, false),
    Result = re:run(Key, "^acc:{([0-9]+)}$", [global, {capture, all, binary}]),
    case Result of
        {match, [[_FullKey, Uid]]} ->
            ?INFO("Account uid: ~p", [Uid]),
            try
                case model_accounts:get_account(Uid) of
                    {ok, Account} ->
                        {ok, ContactList} = model_contacts:get_contacts(Uid),
                        {ok, FriendsList} = model_friends:get_friends(Uid),
                        NumContactsList = length(ContactList),
                        NumFriendsList = length(FriendsList),
                        ClientVersion = Account#account.client_version,
                        LastSeenTsMs = Account#account.last_activity_ts_ms,
                        Phone = Account#account.phone,
                        case NumContactsList =:= 0 andalso NumFriendsList =/= 0 of
                            true ->
                                {ok, FriendUids} = model_friends:get_friends(Uid),
                                lists:foreach(
                                    fun(FriendUid) ->
                                        %% Re-add them as contacts both ways to ensure consistency in our database.
                                        case model_accounts:get_phone(FriendUid) of
                                            {ok, FriendPhone} when FriendPhone =/= undefined ->
                                                case DryRun of
                                                    true ->
                                                        ?INFO("Uid: ~p, FriendUid: ~p, phone: ~p, FriendPhone: ~p",
                                                            [Uid, FriendUid, Phone, FriendPhone]);
                                                    false ->
                                                        ok = model_contacts:add_contact(FriendUid, Phone),
                                                        ok = model_contacts:add_contact(Uid, FriendPhone),
                                                        ?INFO("added Uid: ~p, FriendUid: ~p, phone: ~p, FriendPhone: ~p",
                                                            [Uid, FriendUid, Phone, FriendPhone])
                                                end;
                                            _ ->
                                                ?ERROR("Invalid account uid: ~p", [FriendUid])
                                        end
                                    end, FriendUids),
                                ok;
                            false ->
                                ok
                        end;
                    _ ->
                        ?ERROR("Uid: ~p, no account exists here", [Uid])
                end
            catch
                _:_ ->
                    ?ERROR("Uid: ~p, no account exception here", [Uid])
            end,
            ok;
        _ -> ok
    end,
    State.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%                              Fix contacts keys ttl                                 %%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

fix_contacts_ttl(Key, State) ->
    ?INFO("Key: ~p", [Key]),
    DryRun = maps:get(dry_run, State, false),
    Result = re:run(Key, "^con:{([0-9]+)}$", [global, {capture, all, binary}]),
    case Result of
        {match, [[FullKey, Uid]]} ->
            ?INFO("uid: ~p", [Uid]),
            {ok, TTL} = q(ecredis_contacts, ["TTL", FullKey]),
            ?INFO("TTL ~p ~p", [FullKey, TTL]),
            Command = ["PERSIST", FullKey],
            case DryRun of
                true ->
                    ?INFO("Would execute ~p", [Command]);
                false ->
                    Res = q(ecredis_contacts, Command),
                    ?INFO("did ~p -> ~p", [Command, Res])
            end,
            ok;
        _ -> ok
    end,
    State.

q(Client, Command) -> util_redis:q(Client, Command).
qp(Client, Commands) -> util_redis:qp(Client, Commands).

