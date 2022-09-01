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

-define(MIN_BUCKET, 0).
-define(MAX_BUCKET, 10).

-define(INACTIVE_DAYS_THRESHOLD, 90).

-export([
    trigger_marketing_alert/2,
    trigger_marketing_alert_pt/2,
    trigger_marketing_alert_inactive/2,
    log_account_info/2,
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
%%                           Portugal (PT)                                            %%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% redis_migrate:start_migration("trigger_marketing_alert_pt", redis_accounts, {migrate_push_alerts, trigger_marketing_alert_pt}, [{execute, sequential}, {scan_count, 500}, {dry_run, true}, {params, {cc_ok, sets:from_list([<<"PT">>])}}]).

trigger_marketing_alert_pt(Key, State) ->
    trigger_marketing_alert(Key, State, fun is_lang_ok/1, fun alert_type_pt/1),
    State.


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%                           Example: Brazil (BR)                                     %%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%


%% redis_migrate:start_migration("trigger_marketing_alert_inactive", redis_accounts, {migrate_push_alerts, trigger_marketing_alert_inactive}, [{execute, sequential}, {scan_count, 500}, {dry_run, true}, {params, {cc_ok, sets:from_list([<<"BR">>])}}]).

%% redis_migrate:start_migration("log_account_info", redis_accounts, {migrate_push_alerts, log_account_info}, [{execute, sequential}, {scan_count, 500}, {dry_run, true}, {params, {cc_ok, sets:from_list([<<"BR">>])}}]).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%                           Example: DE, GB, CZ, NL
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% redis_migrate:start_migration("trigger_marketing_alert_inactive", redis_accounts, {migrate_push_alerts, trigger_marketing_alert_inactive}, [{execute, sequential}, {scan_count, 500}, {dry_run, true}, {params, {cc_ok, sets:from_list([<<"DE">>, <<"GB">>, <<"CZ">>, <<"NL">>])}}]).

%% redis_migrate:start_migration("log_account_info", redis_accounts, {migrate_push_alerts, log_account_info}, [{execute, sequential}, {scan_count, 500}, {dry_run, true}, {params, {cc_ok, sets:from_list([<<"DE">>, <<"GB">>, <<"CZ">>, <<"NL">>])}}]).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%                           Example: All countries other than
%%                           IR, IN, US, BR, RU, PT, ES, ID, MX, CU
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% redis_migrate:start_migration("trigger_marketing_alert_inactive", redis_accounts, {migrate_push_alerts, trigger_marketing_alert_inactive}, [{execute, sequential}, {scan_count, 500}, {dry_run, true},{params, {cc_not_ok, sets:from_list([<<"IR">>, <<"IN">>, <<"US">>, <<"BR">>, <<"RU">>, <<"PT">>, <<"ES">>, <<"ID">>, <<"MX">>, <<"CU">>])}}]). 

%% redis_migrate:start_migration("log_account_info", redis_accounts, {migrate_push_alerts, log_account_info}, [{execute, sequential}, {scan_count, 500}, {dry_run, true}, {params, {cc_not_ok, sets:from_list([<<"IR">>, <<"IN">>, <<"US">>, <<"BR">>, <<"RU">>, <<"PT">>, <<"ES">>, <<"ID">>, <<"MX">>, <<"CU">>])}}]).

-spec log_account_info(Key :: string(), State :: map()) -> map().
log_account_info(Key, State) ->
    {IsCCOkFun, CCSet} = get_cc_params(State),
    Result = re:run(Key, "^acc:{([0-9]+)}$", [global, {capture, all, binary}]),
    case Result of
        {match, [[FullKey, Uid]]} ->
            {ok, Phone} = q(ecredis_accounts, ["HGET", FullKey, <<"ph">>]),
            case IsCCOkFun(mod_libphonenumber:get_region_id(Phone), CCSet) of
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
    end,
    State.

trigger_marketing_alert_inactive(Key, State) ->
    trigger_marketing_alert(Key, State, fun is_lang_ok/1, fun alert_type_inactive/1),
    State.


-spec trigger_marketing_alert(Key :: string(), State :: map(), IsLangOkFn :: fun(),
        AlertTypeFn :: fun()) -> ok.
trigger_marketing_alert(Key, State, IsLangOkFn, AlertTypeFn) ->
    DryRun = maps:get(dry_run, State, true),
    {IsCCOkFun, CCSet} = get_cc_params(State),
    Result = re:run(Key, "^acc:{([0-9]+)}$", [global, {capture, all, binary}]),
    case Result of
        {match, [[FullKey, Uid]]} ->
            {ok, [Phone, PushLangId, ClientVersion]} = q(ecredis_accounts, ["HMGET", FullKey, <<"ph">>, <<"pl">>, <<"cv">>]),
            UidBucket = hash_uid(Uid),
            IsLangOk = IsLangOkFn(PushLangId),
            case IsCCOkFun(mod_libphonenumber:get_region_id(Phone), CCSet) of
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


get_cc_params(State) ->
    Params = maps:get(params, State, {}),
    case Params of
        {cc_ok, CCSet1} -> {fun is_cc_ok/2, CCSet1};
        {cc_not_ok, CCSet2} -> {fun is_cc_not_ok/2, CCSet2};
        _ ->
            ?WARNING("Params does not seem right: ~p", [Params]),
            {fun is_cc_ok/2, sets:new()}
    end.

is_cc_ok(CC, OKSet) ->
    sets:is_element(CC, OKSet). 

is_cc_not_ok(CC, NotOKSet) ->
    (not sets:is_element(CC, NotOKSet)). 

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
                %% "in" comes from the client, converted to "id" during push
                <<"in">> -> true;
                <<"id">> -> true;
                <<"nl">> -> true;
                <<"pl">> -> true;
                <<"pt">> -> true;
                <<"ru">> -> true;
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
