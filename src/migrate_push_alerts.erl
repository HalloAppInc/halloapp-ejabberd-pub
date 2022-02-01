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
-include("time.hrl").

-define(NG, <<"NG">>).
-define(GB, <<"GB">>).
-define(ZA, <<"ZA">>).
-define(CU, <<"CU">>).
-define(DE, <<"DE">>).
-define(PT, <<"PT">>).

-define(IR, <<"IR">>).
-define(IN, <<"IN">>).
-define(RU, <<"RU">>).
-define(US, <<"US">>).
-define(BR, <<"BR">>).

-define(MIN_BUCKET, 0).
-define(MAX_BUCKET, 10).

-define(INACTIVE_DAYS_THRESHOLD, 90).

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
    log_account_info_run_de/2,
    trigger_marketing_alert_pt/2,
    log_account_info_run_pt/2,
    trigger_marketing_alert_ir/2,
    log_account_info_run_ir/2,
    trigger_marketing_alert_in/2,
    log_account_info_run_in/2,
    trigger_marketing_alert_ru/2,
    log_account_info_run_ru/2,
    trigger_marketing_alert_us/2,
    log_account_info_run_us/2,
    trigger_marketing_alert_br/2,
    log_account_info_run_br/2,
    hash_to_bucket/1,
    get_last_activity/1
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

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%                           Portugal (PT)                                            %%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

trigger_marketing_alert_pt(Key, State) ->
    trigger_marketing_alert(Key, State, ?PT, fun is_lang_ok/1, fun alert_type_pt/1),
    State.


log_account_info_run_pt(Key, State) ->
    log_account_info(Key, ?PT),
    State.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%                           Iran (IR)                                                %%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

trigger_marketing_alert_ir(Key, State) ->
    trigger_marketing_alert(Key, State, ?IR, fun is_lang_ok/1, fun alert_type_inactive/1),
    State.


log_account_info_run_ir(Key, State) ->
    log_account_info(Key, ?IR),
    State.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%                           India (IN)                                               %%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

trigger_marketing_alert_in(Key, State) ->
    trigger_marketing_alert(Key, State, ?IN, fun is_lang_ok/1, fun alert_type_inactive/1),
    State.


log_account_info_run_in(Key, State) ->
    log_account_info(Key, ?IN),
    State.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%                           Russia (RU)                                               %%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

trigger_marketing_alert_ru(Key, State) ->
    trigger_marketing_alert(Key, State, ?RU, fun is_lang_ok/1, fun alert_type_inactive/1),
    State.


log_account_info_run_ru(Key, State) ->
    log_account_info(Key, ?RU),
    State.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%                           US (US)                                                  %%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

trigger_marketing_alert_us(Key, State) ->
    trigger_marketing_alert(Key, State, ?US, fun is_lang_ok/1, fun alert_type_inactive/1),
    State.


log_account_info_run_us(Key, State) ->
    log_account_info(Key, ?US),
    State.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%                           Brazil (BR)                                              %%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

trigger_marketing_alert_br(Key, State) ->
    trigger_marketing_alert(Key, State, ?BR, fun is_lang_ok/1, fun alert_type_inactive/1),
    State.


log_account_info_run_br(Key, State) ->
    log_account_info(Key, ?BR),
    State.

-spec log_account_info(Key :: string(), CC :: binary()) -> ok.
log_account_info(Key, CC) ->
    Result = re:run(Key, "^acc:{([0-9]+)}$", [global, {capture, all, binary}]),
    case Result of
        {match, [[FullKey, Uid]]} ->
            {ok, Phone} = q(ecredis_accounts, ["HGET", FullKey, <<"ph">>]),
            case mod_libphonenumber:get_region_id(Phone) =:= CC of
                true ->
                    {LastActivity, IsInactive} = get_last_activity(Uid),
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
                    ?INFO("CC: ~p, Account Uid: ~p, Phone: ~p, CC: ~p, NumContacts: ~p, "
                          "NumUidContacts: ~p, NumFriends: ~p, LastActivity: ~p, IsInactive: ~p",
                              [CC, Uid, Phone, CC, NumContacts, NumUidContacts, NumFriends,
                              LastActivity, IsInactive]);
                false ->
                    ok
            end;
        _ -> ok
    end.

get_last_activity(Uid) ->
    {ok, Activity} = model_accounts:get_last_activity(Uid),
    LastActivityTsMs = case Activity#activity.last_activity_ts_ms of
        undefined -> 0;
        TsMs -> TsMs
    end,
    IsInactive = (LastActivityTsMs < (util:now_ms() - ?INACTIVE_DAYS_THRESHOLD * ?DAYS_MS)),
    {LastActivityDate, _Time} = case LastActivityTsMs of
        0 -> util:ms_to_datetime_string(undefined);
        _ -> util:ms_to_datetime_string(LastActivityTsMs)
    end,
    {LastActivityDate, IsInactive}.

-spec trigger_marketing_alert(Key :: string(), State :: map(), CC :: binary(), IsLangOkFn :: fun()) -> ok.
trigger_marketing_alert(Key, State, CC, IsLangOkFn) ->
   trigger_marketing_alert(Key, State, CC, IsLangOkFn, fun alert_type/1). 


-spec trigger_marketing_alert(Key :: string(), State :: map(), CC :: binary(), IsLangOkFn :: fun(),
        AlertTypeFn :: fun()) -> ok.
trigger_marketing_alert(Key, State, CC, IsLangOkFn, AlertTypeFn) ->
    DryRun = maps:get(dry_run, State, true),
    Result = re:run(Key, "^acc:{([0-9]+)}$", [global, {capture, all, binary}]),
    case Result of
        {match, [[FullKey, Uid]]} ->
            {ok, [Phone, PushLangId, ClientVersion]} = q(ecredis_accounts, ["HMGET", FullKey, <<"ph">>, <<"pl">>, <<"cv">>]),
            UidBucket = hash_uid(Uid),
            IsLangOk = IsLangOkFn(PushLangId),
            case mod_libphonenumber:get_region_id(Phone) =:= CC of
                true ->
                    AlertType = AlertTypeFn(Uid),
                    ?INFO("Account uid: ~p, LangId: ~p, ClientVersion: ~p, AlertType: ~p, UidBucket: ~p",
                        [Uid, PushLangId, ClientVersion, AlertType, UidBucket]),
                    case IsLangOk andalso AlertType =/= none andalso UidBucket >= ?MIN_BUCKET andalso
                            UidBucket < ?MAX_BUCKET of
                        true ->
                            case DryRun of
                                true ->
                                    ?INFO("would send marketing alert to Uid: ~p, LangId: ~p",
                                        [Uid, PushLangId]);
                                false ->
                                    ok = mod_push_notifications:push_marketing_alert(Uid, AlertType),
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
            case mod_translate:shorten_lang_id(PushLangId) of
                <<"cs">> -> true;
                <<"de">> -> true;
                <<"fr">> -> true;
                <<"en">> -> true;
                <<"es">> -> true;
                <<"fa">> -> true;
                <<"nl">> -> true;
                <<"pl">> -> true;
                <<"pt">> -> true;
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

-spec alert_type_pt(Uid :: binary()) -> atom().
alert_type_pt(Uid) ->
    case alert_type(Uid) of
        invite_friends -> none;
        share_post ->
            case (hash_to_bucket(<<Uid/binary, <<"share_post_pt">>/binary>>) rem 2) =:= 0 of
                true -> share_post;
                false -> share_post_control
            end
    end.

-spec alert_type_inactive(Uid :: binary()) -> atom().
alert_type_inactive(Uid) ->
    {_LastActiveDate, IsInactive} = get_last_activity(Uid),
    case IsInactive of
        true -> alert_type(Uid);
        false -> none
    end.

-spec hash_to_bucket(Input :: binary()) -> integer().
hash_to_bucket(Input) ->
    Sha = crypto:hash(sha256, Input),
    FirstSize = byte_size(Sha) - 8,
    <<_Rest:FirstSize/binary, Last8:8/binary>> = Sha,
    <<LastInt:64>> = Last8,
    LastInt.

-spec hash_uid(Uid :: binary()) -> integer().
hash_uid(Uid) ->
    crc16_redis:crc16(util:to_list(Uid)) rem 100.

q(Client, Command) -> util_redis:q(Client, Command).
