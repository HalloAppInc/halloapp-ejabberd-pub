%%%-------------------------------------------------------------------
%%% Redis migrations that check the validity of uid -> phone and phone -> uid mappings
%%%
%%% Copyright (C) halloapp inc.
%%%
%%%-------------------------------------------------------------------
-module(migrate_check_accounts).
-author('murali').

-include("logger.hrl").
-include("client_version.hrl").

-export([
    check_accounts_run/2,
    log_account_info_run/2,
    check_phone_numbers_run/2,
    check_argentina_numbers_run/2,
    check_mexico_numbers_run/2,
    check_version_counters_run/2
]).


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%                         Check all user accounts                        %%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

check_accounts_run(Key, State) ->
    ?INFO("Key: ~p", [Key]),
    Result = re:run(Key, "^acc:{([0-9]+)}$", [global, {capture, all, binary}]),
    case Result of
        {match, [[FullKey, Uid]]} ->
            ?INFO("Account uid: ~p", [Uid]),
            {ok, Phone} = q(ecredis_accounts, ["HGET", FullKey, <<"ph">>]),
            case Phone of
                undefined ->
                    ?ERROR("Uid: ~p, Phone is undefined!", [Uid]);
                _ ->
                    {ok, PhoneUid} = model_phone:get_uid(Phone),
                    case PhoneUid =:= Uid of
                        true -> ok;
                        false ->
                            ?ERROR("uid mismatch for phone map Uid: ~s Phone: ~s PhoneUid: ~s",
                                [Uid, Phone, PhoneUid]),
                            ok
                    end
            end;
        _ -> ok
    end,
    State.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%                         Check all phone number accounts                        %%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

log_account_info_run(Key, State) ->
    ?INFO("Key: ~p", [Key]),
    Result = re:run(Key, "^acc:{([0-9]+)}$", [global, {capture, all, binary}]),
    case Result of
        {match, [[FullKey, Uid]]} ->
            {ok, Phone} = q(ecredis_accounts, ["HGET", FullKey, <<"ph">>]),
            case Phone of
                undefined ->
                    ?INFO("Uid: ~p, Phone is undefined!", [Uid]);
                _ ->
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
%%                         Check all phone number accounts                        %%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

check_phone_numbers_run(Key, State) ->
    ?INFO("Key: ~p", [Key]),
    Result = re:run(Key, "^pho.*:([0-9]+)$", [global, {capture, all, binary}]),
    case Result of
        {match, [[_FullKey, Phone]]} ->
            ?INFO("phone number: ~p", [Phone]),
            {ok, Uid} = model_phone:get_uid(Phone),
            case Uid of
                undefined ->
                    ?ERROR("Phone: ~p, Uid is undefined!", [Uid]);
                _ ->
                    {ok, UidPhone} = model_accounts:get_phone(Uid),
                    case UidPhone =/= undefined andalso UidPhone =:= Phone of
                        true -> ok;
                        false ->
                            ?ERROR("phone: ~p, uid: ~p, uidphone: ~p", [Uid, Phone, UidPhone]),
                            ok
                    end
            end;
        _ -> ok
    end,
    State.


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%                         Check all argentina accounts                        %%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

check_argentina_numbers_run(Key, State) ->
    ?INFO("Key: ~p", [Key]),
    Result = re:run(Key, "^acc:{([0-9]+)}$", [global, {capture, all, binary}]),
    case Result of
        {match, [[FullKey, Uid]]} ->
            {ok, Phone} = q(ecredis_accounts, ["HGET", FullKey, <<"ph">>]),
            case Phone of
                undefined ->
                    ?INFO("Uid: ~p, Phone is undefined!", [Uid]);
                <<"549", _Rest/binary>> ->
                    ?INFO("Account uid: ~p, phone: ~p - valid_phone", [Uid, Phone]);
                <<"54", _Rest/binary>> ->
                    ?INFO("Account uid: ~p, phone: ~p - invalid_phone", [Uid, Phone]);
                _ ->
                    ok
            end;
        _ -> ok
    end,
    State.


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%                         Check all mexico accounts                        %%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

check_mexico_numbers_run(Key, State) ->
    ?INFO("Key: ~p", [Key]),
    Result = re:run(Key, "^acc:{([0-9]+)}$", [global, {capture, all, binary}]),
    case Result of
        {match, [[FullKey, Uid]]} ->
            {ok, Phone} = q(ecredis_accounts, ["HGET", FullKey, <<"ph">>]),
            case Phone of
                undefined ->
                    ?INFO("Uid: ~p, Phone is undefined!", [Uid]);
                <<"521", _Rest/binary>> ->
                    ?INFO("Account uid: ~p, phone: ~p - invalid_phone", [Uid, Phone]);
                <<"52", _Rest/binary>> ->
                    ?INFO("Account uid: ~p, phone: ~p - valid_phone", [Uid, Phone]);
                _ ->
                    ok
            end;
        _ -> ok
    end,
    State.


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%                          Check all version counters                        %%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

check_version_counters_run(Key, State) ->
    ?INFO("Key: ~p", [Key]),
    DryRun = maps:get(dry_run, State, false),
    Result = re:run(Key, "^acc:{([0-9]+)}$", [global, {capture, all, binary}]),
    case Result of
        {match, [[FullKey, Uid]]} ->
            case q(ecredis_accounts, ["HGET", FullKey, <<"cv">>]) of
                {ok, undefined} -> ok;
                {ok, Version} ->
                    case util_ua:is_valid_ua(Version) of
                        false -> ?INFO("Uid: ~p, client_version: ~p, Invalid", [Uid, Version]);
                        true ->
                            case mod_client_version:is_valid_version(Version) of
                                true ->
                                    ?INFO("Uid: ~p, client_version: ~p, Ignoring", [Uid, Version]);
                                false ->
                                    %% increment version counter
                                    HashSlot = util_redis:eredis_hash(binary_to_list(Uid)),
                                    VersionSlot = HashSlot rem ?NUM_VERSION_SLOTS,
                                    Command = ["HINCRBY", model_accounts:version_key(VersionSlot), Version, 1],
                                    case DryRun of
                                        true ->
                                            ?INFO("Uid: ~p, client_version: ~p, Will execute command: ~p",
                                                [Uid, Version, Command]);
                                        false ->
                                            Res = q(ecredis_accounts, Command),
                                            ?INFO("Uid: ~p, client_version: ~p, Increment counter result: ~p",
                                                [Uid, Version, Res])
                                    end
                            end
                    end
            end;
        _ -> ok
    end,
    State.



q(Client, Command) -> util_redis:q(Client, Command).

