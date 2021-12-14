%%%-------------------------------------------------------------------
%%% Temporary file to send alerts to all accounts.
%%%
%%% Copyright (C) 2021, halloapp inc.
%%%
%%%-------------------------------------------------------------------
-module(migrate_push_alerts).
-author('murali').

-include("logger.hrl").
-include("contacts.hrl").
-include("account.hrl").

-define(NG, <<"NG">>).
-define(GB, <<"GB">>).
-define(ZA, <<"ZA">>).
-define(CU, <<"CU">>).
-define(DE, <<"DE">>).

-define(MIN_BUCKET, 0).
-define(MAX_BUCKET, 10).

-export([
    trigger_marketing_alert/2,
    trigger_marketing_alert_nigeria/2,
    log_account_info_run_nigeria/2,
    trigger_marketing_alert_za/2,
    log_account_info_run_za/2,
    trigger_marketing_alert_gb/2,
    log_account_info_run_gb/2,
    trigger_marketing_alert_cu/2,
    log_account_info_run_cu/2,
    trigger_marketing_alert_de/2,
    log_account_info_run_de/2
]).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%                            Trigger marketing alerts                                %%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

trigger_marketing_alert(Key, State) ->
    ?INFO("Key: ~p", [Key]),
    DryRun = maps:get(dry_run, State, false),
    Result = re:run(Key, "^acc:{([0-9]+)}$", [global, {capture, all, binary}]),
    case Result of
        {match, [[_FullKey, Uid]]} ->
            %% Temporary check on dev_users for testing.
            %% TODO: update condition here if we want to send it for all users.
            case dev_users:is_dev_uid(Uid) of
                true ->
                    case DryRun of
                        true ->
                            ?INFO("would send marketing alert to: ~p", [Uid]);
                        false ->
                            ok = mod_push_notifications:push_marketing_alert(Uid, alert_type(Uid)),
                            ?INFO("sent marketing alert to: ~p", [Uid])
                    end;
                false -> ok
            end;
        _ -> ok
    end,
    State.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%                                  Nigeria (NG)                                      %%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

trigger_marketing_alert_nigeria(Key, State) ->
    trigger_marketing_alert(Key, State, ?NG, fun is_lang_en/1),
    State.



log_account_info_run_nigeria(Key, State) ->
    log_account_info(Key, ?NG),
    State.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%                                  South Africa (ZA)                                 %%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

trigger_marketing_alert_za(Key, State) ->
    trigger_marketing_alert(Key, State, ?ZA, fun is_lang_en/1),
    State.


log_account_info_run_za(Key, State) ->
    log_account_info(Key, ?ZA),
    State.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%                           Great Britain (GB)                                       %%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

trigger_marketing_alert_gb(Key, State) ->
    trigger_marketing_alert(Key, State, ?GB, fun is_lang_en/1),
    State.


log_account_info_run_gb(Key, State) ->
    log_account_info(Key, ?GB),
    State.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%                           Cuba (CU)                                                %%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

trigger_marketing_alert_cu(Key, State) ->
    trigger_marketing_alert(Key, State, ?CU, fun is_lang_ok/1),
    State.


log_account_info_run_cu(Key, State) ->
    log_account_info(Key, ?CU),
    State.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%                           Germany (DE)                                             %%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

trigger_marketing_alert_de(Key, State) ->
    trigger_marketing_alert(Key, State, ?DE, fun is_lang_ok/1),
    State.


log_account_info_run_de(Key, State) ->
    log_account_info(Key, ?DE),
    State.

-spec log_account_info(Key :: string(), CC :: binary()) -> ok.
log_account_info(Key, CC) ->
    Result = re:run(Key, "^acc:{([0-9]+)}$", [global, {capture, all, binary}]),
    case Result of
        {match, [[FullKey, Uid]]} ->
            {ok, Phone} = q(ecredis_accounts, ["HGET", FullKey, <<"ph">>]),
            case mod_libphonenumber:get_region_id(Phone) =:= CC of
                true ->
                    NumContacts = model_contacts:count_contacts(Uid),
                    {ok, Friends} = model_friends:get_friends(Uid),
                    {ok, Contacts} = model_contacts:get_contacts(Uid),
                    IsSelfContact = model_contacts:is_contact(Uid, Phone),
                    UidContacts = model_phone:get_uids(Contacts),
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
                    ?INFO("CC: ~p, Account Uid: ~p, Phone: ~p, CC: ~p, NumContacts: ~p, NumUidContacts: ~p, NumFriends: ~p",
                        [CC, Uid, Phone, CC, NumContacts, NumUidContacts, NumFriends]);
                false ->
                    ok
            end;
        _ -> ok
    end.

-spec trigger_marketing_alert(Key :: string(), State :: map(), CC :: binary(), IsLangOkFn :: fun()) -> ok.
trigger_marketing_alert(Key, State, CC, IsLangOkFn) ->
    DryRun = maps:get(dry_run, State, true),
    Result = re:run(Key, "^acc:{([0-9]+)}$", [global, {capture, all, binary}]),
    case Result of
        {match, [[FullKey, Uid]]} ->
            {ok, [Phone, PushLangId, ClientVersion]} = q(ecredis_accounts, ["HMGET", FullKey, <<"ph">>, <<"pl">>, <<"cv">>]),
            UidBucket = hash_uid(Uid),
            IsLangOk = IsLangOkFn(PushLangId),
            case mod_libphonenumber:get_region_id(Phone) =:= CC of
                true ->
                    ?INFO("Account uid: ~p, LangId: ~p, ClientVersion: ~p, UidBucket: ~p",
                        [Uid, PushLangId, ClientVersion, UidBucket]),
                    case IsLangOk andalso UidBucket >= ?MIN_BUCKET andalso UidBucket < ?MAX_BUCKET of
                        true ->
                            case DryRun of
                                true ->
                                    ?INFO("would send marketing alert to Uid: ~p, LangId: ~p",
                                        [Uid, PushLangId]);
                                false ->
                                    ok = mod_push_notifications:push_marketing_alert(Uid, alert_type(Uid)),
                                    ?INFO("sent marketing alert to: ~p", [Uid])
                            end;
                        false ->
                            ok
                    end;
                false ->
                    ok
            end;
        _ -> ok
    end.


-spec is_lang_en(PushLangId :: binary()) -> boolean().
is_lang_en(PushLangId) ->
    case PushLangId of
        undefined -> true;
        _ -> mod_translate:is_langid_english(PushLangId)
    end.

-spec is_lang_ok(PushLangId :: binary()) -> boolean().
is_lang_ok(PushLangId) ->
    case PushLangId of
        undefined -> true;
        _ ->
            case mod_translate:shorten_langid(PushLangId) of
                <<"de">> -> true;
                <<"en">> -> true;
                <<"es">> -> true;
                _ -> false
            end
    end.

-spec alert_type(Uid :: binary()) -> atom().
alert_type(Uid) ->
    {ok, Friends} = model_friends:get_friends(Uid),
    IsSelfFriends = model_friends:is_friend(Uid, Uid),
    NumFriends = case IsSelfFriends of
        true -> length(Friends) - 1;
        false -> length(Friends)
    end,
    case NumFriends of
        NF when NF >= 2 -> share_post;
        _ -> invite_friends
    end.
  

-spec hash_uid(Uid :: binary()) -> integer().
hash_uid(Uid) ->
    crc16_redis:crc16(util:to_list(Uid)) rem 100.

q(Client, Command) -> util_redis:q(Client, Command).
