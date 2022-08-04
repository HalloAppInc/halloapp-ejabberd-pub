%%%-------------------------------------------------------------------
%%% Redis migrations to migrate argentina accounts
%%%
%%% Copyright (C) halloapp inc.
%%%
%%%-------------------------------------------------------------------
-module(migrate_argentina_accounts).
-author('murali').

-include("logger.hrl").
-include("packets.hrl").

-export([
    log_account_info_run/2,
    adjust_phones_run/2,
    adjust_account_and_readd_contacts_run/2,
    readd_friends_run/2,
    trigger_full_sync_run/2,
    send_new_user_notifications_run/2,
    delete_old_keys_run/2,
    renormalize/1
]).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%          Step1 - Log basic account info about argentina accounts                   %%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

log_account_info_run(Key, State) ->
    ?INFO("Key: ~p", [Key]),
    Result = re:run(Key, "^pho.*:([0-9]+)$", [global, {capture, all, binary}]),
    case Result of
        {match, [[_FullKey, Phone]]} ->
            CheckPhone = case Phone of
                <<"549", _Rest/binary>> -> Phone;
                <<"54", _Rest/binary>> -> Phone;
                _ -> undefined
            end,
            case CheckPhone of
                undefined -> ok;
                _ ->
                    {ok, Uid} = model_phone:get_uid(CheckPhone),
                    NumContacts = model_contacts:count_contacts(Uid),
                    {ok, Friends} = model_friends:get_friends(Uid),
                    {ok, Contacts} = model_contacts:get_contacts(Uid),
                    UidContacts = model_phone:get_uids(Contacts),
                    NumUidContacts = length(maps:to_list(UidContacts)),
                    NumFriends = length(Friends),
                    CC = mod_libphonenumber:get_cc(Phone),
                    ?INFO("Account Uid: ~p, Phone: ~p, CC: ~p, NumContacts: ~p, NumUidContacts: ~p, NumFriends: ~p",
                        [Uid, Phone, CC, NumContacts, NumUidContacts, NumFriends])
            end;
        _ -> ok
    end,
    State.


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%             Step2 - Update PhoneKeys to point to the correct Uid                   %%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

adjust_phones_run(Key, State) ->
    ?INFO("Key: ~p", [Key]),
    Result = re:run(Key, "^pho.*:([0-9]+)$", [global, {capture, all, binary}]),
    DryRun = maps:get(dry_run, State, false),
    case Result of
        {match, [[_FullKey, Phone]]} ->
            case Phone of
                <<"549", _Rest/binary>> -> ok;
                <<"54", Rest/binary>> ->
                    NewPhone = <<"549", Rest/binary>>,
                    {ok, Uid} = model_phone:get_uid(Phone),
                    case DryRun of
                        true ->
                            ?INFO("Phone: ~p, NewPhone: ~p, would set to uid: ~p",
                                [Phone, NewPhone, Uid]);
                        false ->
                            ok = model_phone:add_phone(NewPhone, Uid),
                            {ok, Uid2} = model_phone:get_uid(NewPhone),
                            ?INFO("Phone: ~p, NewPhone: ~p, set to uid: ~p",
                                [Phone, NewPhone, Uid2])
                    end;
                _ ->
                    ok
            end;
        _ -> ok
    end,
    State.


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%         Step3 - Update Uid->Phone mapping and renormalize contacts                 %%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

adjust_account_and_readd_contacts_run(Key, State) ->
    ?INFO("Key: ~p", [Key]),
    Result = re:run(Key, "^pho.*:([0-9]+)$", [global, {capture, all, binary}]),
    DryRun = maps:get(dry_run, State, false),
    case Result of
        {match, [[_FullKey, Phone]]} ->
            case Phone of
                <<"549", _Rest/binary>> ->
                    {ok, Uid} = model_phone:get_uid(Phone),
                    Command = ["HSET", model_accounts:account_key(Uid), <<"ph">>, Phone],
                    {ok, Contacts} = model_contacts:get_contacts(Uid),
                    NewContacts = renormalize_contacts(Contacts),
                    case DryRun of
                        true ->
                            ?INFO("Phone: ~p, Uid: ~p, would run command: ~p",
                                [Phone, Uid, Command]),
                            ?INFO("Uid: ~p, Num: ~p, Contacts: ~p",
                                [Uid, length(Contacts), Contacts]),
                            ?INFO("Uid: ~p, Num: ~p, NewContacts: ~p",
                                [Uid, length(NewContacts), NewContacts]);
                        false ->
                            Result2 = q(ecredis_accounts, Command),
                            ?INFO("Phone: ~p, Uid: ~p, result: ~p",
                                [Phone, Uid, Result2]),
                            ok = model_contacts:add_contacts(Uid, NewContacts)
                    end;
                _ ->
                    ok
            end;
        _ -> ok
    end,
    State.


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%            Step4 - Run through the add_contacts logic to readd friends            %%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

readd_friends_run(Key, State) ->
    ?INFO("Key: ~p", [Key]),
    Result = re:run(Key, "^pho.*:([0-9]+)$", [global, {capture, all, binary}]),
    DryRun = maps:get(dry_run, State, false),
    case Result of
        {match, [[_FullKey, Phone]]} ->
            case Phone of
                <<"549", _Rest/binary>> ->
                    {ok, Uid} = model_phone:get_uid(Phone),
                    {ok, Contacts} = model_contacts:get_contacts(Uid),
                    case DryRun of
                        true ->
                            ?INFO("Uid: ~p, Num: ~p, Contacts: ~p",
                                [Uid, length(Contacts), Contacts]);
                        false ->
                            ContactList = lists:map(fun(Number) -> #pb_contact{raw = Number} end, Contacts),
                            mod_contacts:normalize_and_insert_contacts(Uid, <<>>, ContactList, undefined),
                            ok
                    end;
                _ ->
                    ok
            end;
        _ -> ok
    end,
    State.


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%                    Step5 - Trigger full sync run for these accounts                %%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

trigger_full_sync_run(Key, State) ->
    ?INFO("Key: ~p", [Key]),
    Result = re:run(Key, "^pho.*:([0-9]+)$", [global, {capture, all, binary}]),
    DryRun = maps:get(dry_run, State, false),
    case Result of
        {match, [[_FullKey, Phone]]} ->
            case Phone of
                <<"549", _Rest/binary>> ->
                    {ok, Uid} = model_phone:get_uid(Phone),
                    case DryRun of
                        true ->
                            ?INFO("would send empty hash to: ~p", [Uid]);
                        false ->
                            ok = mod_contacts:trigger_full_contact_sync(Uid),
                            ?INFO("sent empty hash to: ~p", [Uid])
                    end;
                _ ->
                    ok
            end;
        _ -> ok
    end,
    State.


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%            Step6 - Send new user notifications for these accounts            %%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

send_new_user_notifications_run(Key, State) ->
    ?INFO("Key: ~p", [Key]),
    Result = re:run(Key, "^pho.*:([0-9]+)$", [global, {capture, all, binary}]),
    DryRun = maps:get(dry_run, State, false),
    case Result of
        {match, [[_FullKey, Phone]]} ->
            case Phone of
                <<"549", _Rest/binary>> -> ok;
                <<"54", _Rest/binary>> ->
                    {ok, Uid} = model_phone:get_uid(Phone),
                    case DryRun of
                        true ->
                            ?INFO("would send_new_user_notifications to: ~p", [Uid]);
                        false ->
                            ok = mod_contacts:register_user(Uid, <<>>, Phone, <<"undefined">>),
                            ?INFO("sent_new_user_notifications to: ~p", [Uid])
                    end;
                _ ->
                    ok
            end;
        _ -> ok
    end,
    State.


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%                       Step7 - Delete old phone keys                                %%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

delete_old_keys_run(Key, State) ->
    ?INFO("Key: ~p", [Key]),
    Result = re:run(Key, "^pho.*:([0-9]+)$", [global, {capture, all, binary}]),
    DryRun = maps:get(dry_run, State, false),
    case Result of
        {match, [[_FullKey, Phone]]} ->
            case Phone of
                <<"549", _Rest/binary>> -> ok;
                <<"54", _Rest/binary>> ->
                    {ok, Uid} = model_phone:get_uid(Phone),
                    case model_accounts:get_phone(Uid) of
                        {ok, UidPhone} ->
                            Match = UidPhone =:= Phone,
                            ?INFO("Uid: ~p, UidPhone: ~p, Phone: ~p, Match: ~p", [Uid, UidPhone, Phone, Match]),
                            case DryRun of
                                true ->
                                    ?INFO("would delete_phone to: ~p", [Phone]);
                                false ->
                                    ok = model_phone:delete_phone(Phone),
                                    ?INFO("deleted phone: ~p", [Phone])
                            end;
                        _ ->
                            ok
                    end;
                _ ->
                    ok
            end;
        _ -> ok
    end,
    State.


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% ReverseIndexes of these affected phones in model_contacts will be
%% automatically cleared when these clients do a full sync.
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%


q(Client, Command) -> util_redis:q(Client, Command).


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Renormalize contacts %%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%


renormalize_contacts(Phones) ->
    NormPhones = lists:map(fun renormalize/1, Phones),
    NewNormPhones = lists:filter(fun(Phone) -> Phone =/= undefined end, NormPhones),
    NewNormPhones.


renormalize(Phone) ->
    NewPhone = case Phone of
        <<"549", _Rest/binary>> -> Phone;
        <<"54", _Rest/binary>> -> Phone;
        <<"1", Rest/binary>> -> Rest;
        _ -> Phone
    end,
    mod_libphonenumber:normalized_number(NewPhone, <<"AR">>).

