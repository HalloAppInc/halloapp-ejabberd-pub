%%%-------------------------------------------------------------------
%%% Redis migrations that check the validity of uid -> phone and phone -> uid mappings
%%%
%%% Copyright (C) halloapp inc.
%%%
%%%-------------------------------------------------------------------
-module(migrate_check_accounts).
-author('murali').

-include("logger.hrl").
-include("account.hrl").
-include("time.hrl").
-include("client_version.hrl").

-export([
    check_accounts_run/2,
    log_account_info_run/2,
    check_phone_numbers_run/2,
    check_argentina_numbers_run/2,
    check_mexico_numbers_run/2,
    check_version_counters_run/2,
    log_os_version_counters_run/2,
    log_recent_account_info_run2/2,
    check_push_name_run/2,
    set_registration_ts/2,
    print_devices/2,
    set_login_run/2,
    cleanup_offline_queue_run/2,
    check_huawei_token_run/2,
    update_zone_offset/2,
    update_name_index/2,
    sync_latest_notification/2
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
                    {ok, PhoneUid} = model_phone:get_uid(Phone, halloapp),
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
                    IsSelfContact = model_contacts:is_contact(Uid, Phone),
                    UidContacts = model_phone:get_uids(Contacts, halloapp),
                    case IsSelfContact of
                        true -> NumUidContacts = length(maps:to_list(UidContacts)) - 1;
                        false -> NumUidContacts = length(maps:to_list(UidContacts))
                    end,
                    IsSelfFriends = model_friends:is_friend(Uid, Uid),
                    case IsSelfFriends of
                        true -> NumFriends = length(Friends) - 1;
                        false -> NumFriends = length(Friends)
                    end,
                    CC = mod_libphonenumber:get_cc(Phone),
                    {ok, NumOfflineMessages} = model_messages:count_user_messages(Uid),
                    NumGroups = length(model_groups:get_groups(Uid)),
                    ?INFO("Account Uid: ~p, Phone: ~p, CC: ~p, NumContacts: ~p, NumUidContacts: ~p, NumFriends: ~p, NumGroups: ~p, NumOfflineMessages: ~p",
                        [Uid, Phone, CC, NumContacts, NumUidContacts, NumFriends, NumGroups, NumOfflineMessages])
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
            {ok, Uid} = model_phone:get_uid(Phone, halloapp),
            case Uid of
                undefined ->
                    ?ERROR("Phone: ~p, Uid is undefined!", [Uid]);
                _ ->
                    case model_accounts:get_phone(Uid) of
                        {ok, UidPhone} ->
                            case UidPhone =/= undefined andalso UidPhone =:= Phone of
                                true -> ok;
                                false ->
                                    ?ERROR("phone: ~p, uid: ~p, uidphone: ~p", [Phone, Uid, UidPhone]),
                                    ok
                            end;
                        {error, missing} ->
                            ?ERROR("phone: ~p, Invalid uid: ~p", [Phone, Uid])
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


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%                          Log all os version counters                               %%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

log_os_version_counters_run(Key, State) ->
    DryRun = maps:get(dry_run, State, false),
    Result = re:run(Key, "^acc:{([0-9]+)}$", [global, {capture, all, binary}]),
    case Result of
        {match, [[FullKey, Uid]]} ->
            ?INFO("Uid: ~p", [Uid]),
            case q(ecredis_accounts, ["HGET", FullKey, <<"osv">>]) of
                {ok, undefined} ->
                    ?INFO("Uid: ~p, os version is undefined", [Uid]),
                    ok;
                {ok, Version} ->
                    AppType = util_uid:get_app_type(Uid),
                    HashSlot = util_redis:eredis_hash(binary_to_list(Uid)),
                    VersionSlot = HashSlot rem ?NUM_VERSION_SLOTS,
                    Command = ["HINCRBY", model_accounts:os_version_key(VersionSlot, AppType), Version, 1],
                    case DryRun of
                        true ->
                            ?INFO("Uid: ~p, os_version: ~p, Will execute command: ~p",
                                [Uid, Version, Command]);
                        false ->
                            Res = q(ecredis_accounts, Command),
                            ?INFO("Uid: ~p, os_version: ~p, Increment counter result: ~p",
                                [Uid, Version, Res])
                    end
            end;
        _ -> ok
    end,
    State.


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%                          Log all recent account info counts                      %%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

log_recent_account_info_run2(Key, State) ->
    ?INFO("Key: ~p", [Key]),
    Result = re:run(Key, "^acc:{([0-9]+)}$", [global, {capture, all, binary}]),
    case Result of
        {match, [[FullKey, Uid]]} ->
            {ok, [Phone, CreationTimeMsBin]} = q(ecredis_accounts, ["HMGET", FullKey, <<"ph">>, <<"ct">>]),
            case Phone of
                undefined ->
                    ?INFO("Uid: ~p, Phone is undefined!", [Uid]);
                _ ->
                    CreationTimeMs = util:to_integer(CreationTimeMsBin),
                    RegisteredInLastMonth = CreationTimeMs > util:now_ms() - 31 * ?DAYS_MS,
                    RegisteredInLastTwoWeeks = CreationTimeMs > util:now_ms() - 15 * ?DAYS_MS,
                    case RegisteredInLastMonth of
                        true ->
                            NumContacts = model_contacts:count_contacts(Uid),
                            {ok, Friends} = model_friends:get_friends(Uid),
                            {ok, Contacts} = model_contacts:get_contacts(Uid),
                            IsSelfContact = model_contacts:is_contact(Uid, Phone),
                            UidContacts = model_phone:get_uids(Contacts, halloapp),
                            case IsSelfContact of
                                true -> NumUidContacts = length(maps:to_list(UidContacts)) - 1;
                                false -> NumUidContacts = length(maps:to_list(UidContacts))
                            end,
                            IsSelfFriends = model_friends:is_friend(Uid, Uid),
                            case IsSelfFriends of
                                true -> NumFriends = length(Friends) - 1;
                                false -> NumFriends = length(Friends)
                            end,
                            CC = mod_libphonenumber:get_cc(Phone),
                            ?INFO("Account Uid: ~p, Phone: ~p, CC: ~p, RegisteredInLastMonth: ~p, RegisteredInLastTwoWeeks: ~p, NumContacts: ~p, NumUidContacts: ~p, NumFriends: ~p",
                                [Uid, Phone, CC, RegisteredInLastMonth, RegisteredInLastTwoWeeks, NumContacts, NumUidContacts, NumFriends]);
                        false ->
                            ok
                    end
            end;
        _ -> ok
    end,
    State.


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%                          Check push name run for accounts                      %%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

check_push_name_run(Key, State) ->
    ?INFO("Key: ~p", [Key]),
    Result = re:run(Key, "^acc:{([0-9]+)}$", [global, {capture, all, binary}]),
    DryRun = maps:get(dry_run, State, false),
    case Result of
        {match, [[_FullKey, Uid]]} ->
            {ok, Name} = model_accounts:get_name(Uid),
            case unicode:characters_to_nfc_list(Name) of
                {error, _, _} ->
                    FinalName = util:repair_utf8(Name),
                    ?INFO("Uid: ~p, Invalid PushName: ~p, FinalName: ~p", [Uid, Name, FinalName]),
                    case DryRun of
                        false -> ok = model_accounts:set_name(Uid, FinalName);
                        true -> ok
                    end;
                _ -> ok
            end;
        _ -> ok
    end,
    State.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%                       Check all user accounts for login status                      %%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

set_registration_ts(Key, State) ->
    DryRun = maps:get(dry_run, State, false),
    Result = re:run(Key, "^acc:{([0-9]+)}$", [global, {capture, all, binary}]),
    case Result of
        {match, [[_FullKey, Uid]]} ->
            ?INFO("Key: ~p", [Key]),
            case model_accounts:get_account(Uid) of
                {ok, Account} ->
                    try
                        case Account#account.last_registration_ts_ms of
                            undefined ->
                                CreationTsMs = Account#account.creation_ts_ms,
                                case DryRun of
                                    false ->
                                        ok = model_accounts:set_last_registration_ts_ms(Uid, CreationTsMs),
                                        ?INFO("Uid: ~p finished set_last_registration_ts_ms to: ~p",
                                            [Uid, CreationTsMs]);
                                    true ->
                                        ?INFO("Uid: ~p will set_last_registration_ts_ms to: ~p",
                                            [Uid, CreationTsMs]),
                                        ok
                                end;
                            _ -> ok
                        end
                    catch
                        Class : Reason : Stacktrace ->
                            ?ERROR("Uid: ~p failed to clean: ~s",
                                [Uid, lager:pr_stacktrace(Stacktrace, {Class, Reason})])
                    end;
                {error, missing} ->
                    ?ERROR("Unexpected, invalid_uid: ~p", [Uid])
            end;
        _ -> ok
    end,
    State.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%                       Print device for all users                                   %%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

print_devices(Key, State) ->
    Result = re:run(Key, "^acc:{([0-9]+)}$", [global, {capture, all, binary}]),
    case Result of
        {match, [[_FullKey, Uid]]} ->
            ?INFO("Key: ~p", [Key]),
            case model_accounts:get_device(Uid) of
                {error, missing} -> ?INFO("Uid: ~p device missing", [Uid]);
                {ok, Device} -> ?INFO("Uid: ~p device ~p", [Uid, Device])
            end;
        _ -> ok
    end,
    State.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%                       Check all user accounts for login status                      %%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

set_login_run(Key, State) ->
    ?INFO("Key: ~p", [Key]),
    DryRun = maps:get(dry_run, State, false),
    Result = re:run(Key, "^acc:{([0-9]+)}$", [global, {capture, all, binary}]),
    case Result of
        {match, [[FullKey, Uid]]} ->
            {ok, ActivityStatus} = q(ecredis_accounts, ["HGET", FullKey, <<"st">>]),
            case ActivityStatus of
                undefined -> ?INFO("Uid: ~s, ActivityStatus is undefined");
                _ ->
                    case DryRun of
                        false ->
                            Result1 = model_auth:set_login(Uid),
                            ?INFO("Uid: ~s, Result: ~p", [Uid, Result1]);
                        true ->
                            ?INFO("Uid: ~s, will login status")
                    end
            end;
        _ -> ok
    end,
    State.


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%                         Cleanup offline queue run                                %%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

cleanup_offline_queue_run(Key, State) ->
    ?INFO("Key: ~p", [Key]),
    DryRun = maps:get(dry_run, State, false),
    Result = re:run(Key, "^acc:{([0-9]+)}$", [global, {capture, all, binary}]),
    case Result of
        {match, [[FullKey, Uid]]} ->
            {ok, [Phone, ClientVersion]} = q(ecredis_accounts, ["HMGET", FullKey, <<"ph">>, <<"cv">>]),
            case Phone =:= undefined orelse ClientVersion =:= undefined of
                true ->
                    ?INFO("Uid: ~p, Phone: ~p, ClientVersion: ~p - invalid data",
                        [Uid, Phone, ClientVersion]);
                false ->
                    {ok, OldNumMsgs} = model_messages:count_user_messages(Uid),
                    case OldNumMsgs >= 20 of
                        true ->
                            try
                                case DryRun of
                                    false ->
                                        mod_offline_halloapp:cleanup_offline_queue(Uid, ClientVersion),
                                        {ok, NewNumMsgs} = model_messages:count_user_messages(Uid),
                                        ?INFO("Uid: ~s finished cleaning, OldNumMsgs: ~p, NewNumMsgs: ~p",
                                            [Uid, OldNumMsgs, NewNumMsgs]);
                                    true ->
                                        ?INFO("Uid: ~s will cleanup offline queue, OldNumMsgs: ~p",
                                            [Uid, OldNumMsgs])
                                end
                            catch
                                Class : Reason : Stacktrace ->
                                    ?ERROR("Uid: ~p failed to clean: ~s",
                                        [Uid, lager:pr_stacktrace(Stacktrace, {Class, Reason})])
                            end;
                        false ->
                            ?INFO("Uid: ~s ignoring, small queue, OldNumMsgs: ~p",
                                [Uid, OldNumMsgs])
                    end
            end;
        _ -> ok
    end,
    State.


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%                         Check huawei user accounts                        %%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

check_huawei_token_run(Key, State) ->
    Result = re:run(Key, "^acc:{([0-9]+)}$", [global, {capture, all, binary}]),
    case Result of
        {match, [[_FullKey, Uid]]} ->
            {ok, PushInfo} = model_accounts:get_push_info(Uid),
            ?INFO("Uid: ~p PushToken: ~p HuaweiToken: ~p",
                [Uid, PushInfo#push_info.token, PushInfo#push_info.huawei_token]);
        _ -> ok
    end,
    State.


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%                         Update Zone Offset Tag                        %%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

update_zone_offset(Key, State) ->
    DryRun = maps:get(dry_run, State, false),
    MappedToRegionSet = maps:get(params, State),
    Result = re:run(Key, "^acc:{1001000000[0-9]{9}}$", [global, {capture, all, binary}]),
    case Result of
        {match, [[_FullKey, Uid]]} ->
            case sets:is_element(Uid, MappedToRegionSet) of
                true -> ?INFO("Skipping ~s (already mapped to region)");
                false ->
                    case model_accounts:get_phone(Uid) of
                        {error, missing} ->
                            ?WARNING("Uid ~s has no phone, skipping", [Uid]);
                        {ok, Phone} ->
                            ZoneOffsetSec = model_accounts:get_zone_offset(Uid),
                            ZoneOffsetTag = ?HOURS * mod_moment_notification:get_four_zone_offset_hr(ZoneOffsetSec, Phone),
                            case DryRun of
                                false ->
                                    model_accounts:update_zone_offset_tag2(Uid, ZoneOffsetTag, undefined),
                                    ?INFO("Uid: ~s, new zone offset: ~p", [Uid, ZoneOffsetTag]);
                                true ->
                                    ?INFO("[DRY RUN] Uid: ~s, new zone offset: ~p", [Uid, ZoneOffsetTag])
                            end
                    end
            end;
        _ -> ok
    end,
    State.


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%                         Update account Name index                       %%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

update_name_index(Key, State) ->
    DryRun = maps:get(dry_run, State, false),
    Result = re:run(Key, "^acc:{(1001[0-9]+)}$", [global, {capture, all, binary}]),
    case Result of
        {match, [[_FullKey, Uid]]} ->
            case util_uid:get_app_type(Uid) of
                katchup ->
                    Name = model_accounts:get_name_binary(Uid),
                    case Name =/= undefined andalso Name =/= <<>> of
                        true ->
                            case DryRun of
                                false ->
                                    model_accounts:set_name(Uid, Name),
                                    ?INFO("Uid: ~p, updated index for name: ~p", [Uid, Name]);
                                true ->
                                    ?INFO("Uid: ~p, will update index for name: ~p", [Uid, Name])
                            end;
                        false ->
                            ?INFO("Uid: ~p Name is empty", [Uid])
                    end;
                halloapp ->
                    ok
            end;
        _ -> ok
    end,
    State.


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%                             update feed index                            %%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

sync_latest_notification(Key, State) ->
    DryRun = maps:get(dry_run, State, false),
    Result = re:run(Key, "^acc:{(1001[0-9]+)}$", [global, {capture, all, binary}]),
    case Result of
        {match, [[_FullKey, Uid]]} ->
            case util_uid:get_app_type(Uid) of
                katchup ->
                    {ok, Phone} = model_accounts:get_phone(Uid),
                    mod_moment_notification:sync_latest_notification(Uid, Phone, DryRun),
                    ok;
                halloapp ->
                    ok
            end;
        _ -> ok
    end,
    State.


q(Client, Command) -> util_redis:q(Client, Command).

