%%%-------------------------------------------------------------------
%%% @author nikola
%%% @copyright (C) 2020, HalloApp, Inc.
%%% @doc
%%%
%%% @end
%%% Created : 09. Apr 2020 2:29 PM
%%%-------------------------------------------------------------------
-module(model_accounts).
-author("nikola").

-include("logger.hrl").
-include("account.hrl").
-include("redis_keys.hrl").
-include("ha_types.hrl").
-include("time.hrl").
-include("client_version.hrl").
-include("util_redis.hrl").
-include("feed.hrl").

-ifdef(TEST).
%% debugging purposes
-include_lib("eunit/include/eunit.hrl").
-define(dbg(S, As), io:fwrite(user, <<"~ts\n">>, [io_lib:format((S), (As))])).
-endif.

-define(DELETED_ACCOUNT_TTL, 2 * ?WEEKS).

%% Validity period for transient keys created during inactive accounts deletion.
-define(INACTIVE_UIDS_VALIDITY, 12 * ?HOURS).

-define(EXPORT_TTL, 10 * ?DAYS).

-define(MARKETING_TAG_TTL, 90 * ?DAYS).

-define(REJECTED_SUGGESTION_EXPIRATION, 90 * ?DAYS).

%% Thresholds for defining an active user for purposes of campus ambassador recruitment
-define(ACTIVE_USER_MIN_FOLLOWERS, 5).
-define(ACTIVE_USER_MIN_POSTS, 1).

-ifdef(TEST).
-export([
    deleted_account_key/1,
    subscribe_key/1,
    broadcast_key/1,
    count_registrations_key/1,
    count_accounts_key/1
    ]).
-endif.

-export([
    account_key/1,
    version_key/1,
    os_version_key/2,
    lang_key/2,
    uids_to_delete_key/1
]).


%% API
-export([
    create_account/3,
    create_account/4,
    create_account/5, % CommonTest
    delete_account/1,
    account_exists/1,
    accounts_exist/1,
    filter_nonexisting_uids/1,
    is_account_deleted/1,
    get_deleted_account/1,
    get_account/1,
    get_phone/1,
    get_phones/1,
    set_name/2,
    get_name/1,
    get_name_binary/1,
    get_names/1,
    get_avatar_ids/1,
    get_creation_ts_ms/1,
    get_last_registration_ts_ms/1,
    mark_first_non_empty_sync_done/1,
    is_first_non_empty_sync_done/1,
    delete_first_non_empty_sync_status/1,
    mark_first_sync_done/1,
    is_first_sync_done/1,
    delete_first_sync_status/1,
    delete_name/1,
    set_avatar_id/2,
    delete_avatar_id/1,
    get_avatar_id/1,
    get_avatar_id_binary/1,
    get_last_activity/1,
    get_last_activity_ts_ms/1,
    set_last_activity/3,
    set_last_ip_and_connection_time/3,
    get_last_ipaddress/1,
    get_last_connection_time/1,
    set_user_agent/2,
    set_last_registration_ts_ms/2,
    get_signup_user_agent/1,
    set_client_info/4,
    set_client_version/2,
    get_client_version/1,
    set_device_info/3,
    get_os_version/1,
    get_device/1,
    get_push_info/1,
    set_push_token/5,
    set_push_token/6,
    set_voip_token/5,
    set_huawei_token/5,
    get_lang_id/1,
    remove_android_token/1,
    remove_huawei_token/1,
    remove_push_info/1,
    set_push_post_pref/2,
    get_push_post_pref/1,
    remove_push_post_pref/1,
    set_push_comment_pref/2,
    get_push_comment_pref/1,
    remove_push_comment_pref/1,
    set_push_mention_pref/2,
    set_push_fire_pref/2,
    set_push_new_user_pref/2,
    set_push_follower_pref/2,
    get_zone_offset/1,
    presence_subscribe/2,
    presence_unsubscribe/2,
    presence_unsubscribe_all/1,
    get_subscribed_uids/1,
    get_broadcast_uids/1,
    count_registrations/0,
    count_registrations/2,
    count_registration_query/2,
    count_accounts_query/2,
    count_accounts/0,
    count_accounts/2,
    get_traced_uids/0,
    add_uid_to_trace/1,
    remove_uid_from_trace/1,
    is_uid_traced/1,
    get_traced_phones/0,
    add_phone_to_trace/1,
    remove_phone_from_trace/1,
    is_phone_traced/1,
    count_version_keys/0,
    cleanup_version_keys/1,
    count_os_version_keys/1,
    count_lang_keys/1,
    add_uid_to_delete/1,
    get_uids_to_delete/1,
    count_uids_to_delete/0,
    cleanup_uids_to_delete_keys/0,
    mark_inactive_uids_gen_start/0,
    mark_inactive_uids_deletion_start/0,
    mark_inactive_uids_check_start/0,
    get_export/1,
    start_export/2,
    test_set_export_time/2, % For tests only
    add_geo_tag/3,
    get_latest_geo_tag/1,
    get_all_geo_tags/1,
    add_marketing_tag/2,
    get_marketing_tags/1,
    add_uid_to_psa_tag/2,
    get_psa_tagged_uids/2,
    count_psa_tagged_uids/1,
    cleanup_psa_tagged_uids/1,
    mark_psa_post_sent/2,
    mark_moment_notification_sent/2,
    delete_moment_notification_sent/2,
    get_node_list/0,
    scan/3,
    get_user_activity_info/1,
    update_zone_offset_tag2/3,  %% for migration
    update_zone_offset_tag/3,
    get_zone_offset_tag_uids/1,
    del_zone_offset/1,
    delete_zone_offset_tag/2,
    is_username_available/1,
    set_username/2,
    get_username/1,
    get_username_uid/1,
    get_username_uids/1,
    search_username_prefix/2,
    get_basic_user_profiles/2,
    get_user_profiles/2,
    add_rejected_suggestions/2,
    get_all_rejected_suggestions/1,
    set_bio/2,
    get_bio/1,
    set_links/2,
    get_links/1,
    delete_old_username/1,
    get_geotag_uids/1,
    update_geo_tag_index/2
]).

%%====================================================================
%% API
%%====================================================================


-define(FIELD_PHONE, <<"ph">>).
-define(FIELD_NAME, <<"na">>).
-define(FIELD_AVATAR_ID, <<"av">>).
-define(FIELD_CREATION_TIME, <<"ct">>).
-define(FIELD_LAST_REGISTRATION_TIME, <<"rt">>).
-define(FIELD_DELETION_TIME, <<"dt">>).
-define(FIELD_SYNC_STATUS, <<"fsy">>).
-define(FIELD_NON_EMPTY_SYNC_STATUS, <<"sy">>).
-define(FIELD_NUM_INV, <<"in">>).  % from model_invites, but is part of the account structure
-define(FIELD_SINV_TS, <<"it">>).  % from model_invites, but is part of the account structure
-define(FIELD_LAST_IPADDRESS, <<"lip">>).
-define(FIELD_LAST_CONNECTION_TIME, <<"cot">>).
-define(FIELD_LAST_ACTIVITY, <<"la">>).
-define(FIELD_ACTIVITY_STATUS, <<"st">>).
-define(FIELD_USER_AGENT, <<"ua">>).
-define(FIELD_CAMPAIGN_ID, <<"cmp">>).
-define(FIELD_CLIENT_VERSION, <<"cv">>).
-define(FIELD_PUSH_OS, <<"pos">>).
-define(FIELD_PUSH_TOKEN, <<"ptk">>).
-define(FIELD_PUSH_TIMESTAMP, <<"pts">>).
-define(FIELD_PUSH_POST, <<"pp">>).
-define(FIELD_PUSH_COMMENT, <<"pc">>).
-define(FIELD_PUSH_MENTION, <<"pm">>).
-define(FIELD_PUSH_FIRE, <<"pr">>).
-define(FIELD_PUSH_NEW_USER, <<"pn">>).
-define(FIELD_PUSH_FOLLOWER, <<"pf">>).
-define(FIELD_PUSH_LANGUAGE_ID, <<"pl">>).
-define(FIELD_ZONE_OFFSET, <<"tz">>).
-define(FIELD_VOIP_TOKEN, <<"pvt">>).
-define(FIELD_HUAWEI_TOKEN, <<"ht">>).
-define(FIELD_DEVICE, <<"dvc">>).
-define(FIELD_OS_VERSION, <<"osv">>).
-define(FIELD_USERNAME, <<"un">>).
-define(FIELD_USERNAME_UID, <<"unu">>).
-define(FIELD_BIO, <<"bio">>).
-define(FIELD_LINKS, <<"lnk">>).

%% Field to capture creation of list with inactive uids and their deletion.
-define(FIELD_INACTIVE_UIDS_STATUS, <<"ius">>).

%% Export Field
-define(FIELD_EXPORT_START_TS, <<"est">>).
-define(FIELD_EXPORT_ID, <<"eur">>).

-define(FIELD_PSA_POST_STATUS, <<"pps">>).
-define(FIELD_MOMENT_NOFITICATION_STATUS, <<"mns">>).

%%====================================================================
%% Account related API
%%====================================================================

-spec create_account(Uid :: uid(), Phone :: phone(),
        UserAgent :: binary()) -> ok | {error, exists}.
create_account(Uid, Phone, UserAgent) ->
    create_account(Uid, Phone, UserAgent, <<>>, util:now_ms()).

-spec create_account(Uid :: uid(), Phone :: phone(),
        UserAgent :: binary(), CampaignId :: binary()) -> ok | {error, exists}.
create_account(Uid, Phone, UserAgent, CampaignId) ->
    create_account(Uid, Phone, UserAgent, CampaignId, util:now_ms()).


-spec create_account(Uid :: uid(), Phone :: phone(),
        UserAgent :: binary(), CampaignId :: binary(),
        CreationTsMs :: integer()) -> ok | {error, exists | deleted}.
create_account(Uid, Phone, UserAgent, CampaignId, CreationTsMs) ->
    {ok, Deleted} = q(["EXISTS", deleted_account_key(Uid)]),
    case binary_to_integer(Deleted) == 1 of
        true -> {error, deleted};
        false ->
            {ok, Exists} = q(["HSETNX", account_key(Uid), ?FIELD_PHONE, Phone]),
            case binary_to_integer(Exists) > 0 of
                true ->
                    Res = qp([
                        ["HSET", account_key(Uid),
                            ?FIELD_USER_AGENT, UserAgent,
                            ?FIELD_CAMPAIGN_ID, CampaignId,
                            ?FIELD_CREATION_TIME, integer_to_binary(CreationTsMs),
                            ?FIELD_LAST_REGISTRATION_TIME, integer_to_binary(CreationTsMs)],
                        ["INCR", count_registrations_key(Uid)],
                        ["INCR", count_accounts_key(Uid)]
                    ]),
                    [{ok, _FieldCount}, {ok, _}, {ok, _}] = Res,
                    ok;
                false ->
                    {error, exists}
            end
    end.


%% We copy unidentifiable information to a new key.
%% The renamed key with rest of the info like phone etc.. will expire in 2 weeks.
-spec delete_account(Uid :: uid()) -> ok.
delete_account(Uid) ->
    DeletionTsMs = util:now_ms(),
    %% TODO(murali@): this code is kind of ugly.
    %% Just get all fields and use map.
    case q(["HMGET", account_key(Uid), ?FIELD_PHONE,
            ?FIELD_CREATION_TIME, ?FIELD_LAST_REGISTRATION_TIME, ?FIELD_LAST_ACTIVITY, ?FIELD_ACTIVITY_STATUS,
            ?FIELD_USER_AGENT, ?FIELD_CAMPAIGN_ID, ?FIELD_CLIENT_VERSION, ?FIELD_PUSH_LANGUAGE_ID,
            ?FIELD_DEVICE, ?FIELD_OS_VERSION, ?FIELD_USERNAME]) of
        {ok, [undefined | _]} ->
            ?WARNING("Looks like it is already deleted, Uid: ~p", [Uid]),
            ok;
        {ok, [_Phone, CreationTsMsBin, RegistrationTsMsBin, LastActivityTsMs, ActivityStatus,
                UserAgent, CampaignId, ClientVersion, LangId, Device, OsVersion, Username]} ->
            [{ok, _}, RenameResult, {ok, _}, DecrResult] = qp([
                ["HSET", deleted_uid_key(Uid),
                            ?FIELD_CREATION_TIME, CreationTsMsBin,
                            ?FIELD_LAST_REGISTRATION_TIME, RegistrationTsMsBin,
                            ?FIELD_LAST_ACTIVITY, LastActivityTsMs,
                            ?FIELD_ACTIVITY_STATUS, ActivityStatus,
                            ?FIELD_USER_AGENT, UserAgent,
                            ?FIELD_CAMPAIGN_ID, CampaignId,
                            ?FIELD_CLIENT_VERSION, ClientVersion,
                            ?FIELD_DELETION_TIME, integer_to_binary(DeletionTsMs),
                            ?FIELD_DEVICE, Device,
                            ?FIELD_OS_VERSION, OsVersion,
                            ?FIELD_USERNAME, Username],
                ["RENAME", account_key(Uid), deleted_account_key(Uid)],
                ["EXPIRE", deleted_account_key(Uid), ?DELETED_ACCOUNT_TTL],
                ["DECR", count_accounts_key(Uid)]
            ]),
            case Username =/= undefined andalso util_uid:get_app_type(Uid) =/= halloapp of
                true -> delete_username_index(Username);
                false -> ok
            end,
            case RenameResult of
                {ok, <<"OK">>} ->
                    ?INFO("Uid: ~s deleted", [Uid]);
                {error, Error} ->
                    ?ERROR("Uid: ~s account delete failed ~p", [Uid, Error])
            end,
            decrement_version_and_lang_counters(Uid, ClientVersion, LangId),
            {ok, _} = DecrResult;
        {error, _} ->
            ?ERROR("Error, fetching details: ~p", [Uid]),
            ok
    end,
    ok.


-spec decrement_version_and_lang_counters(Uid :: binary(), ClientVersion :: binary(), LangId :: binary()) -> ok.
decrement_version_and_lang_counters(Uid, ClientVersion, LangId) ->
    %% Decrement version counter
    HashSlot = util_redis:eredis_hash(binary_to_list(Uid)),
    VersionSlot = HashSlot rem ?NUM_VERSION_SLOTS,
    {ok, _} = q(["HINCRBY", version_key(VersionSlot), ClientVersion, -1]),
    AppType = util_uid:get_app_type(Uid),
    case LangId =/= undefined of
        true ->
            %% Decrement lang counter
            LangSlot = HashSlot rem ?NUM_SLOTS,
            {ok, _} = q(["HINCRBY", lang_key(LangSlot, AppType), LangId, -1]);
        _ ->
            ok
    end,
    ok.


-spec set_name(Uid :: uid(), Name :: binary()) -> ok  | {error, any()}.
set_name(Uid, Name) ->
    {ok, _Res} = q(["HSET", account_key(Uid), ?FIELD_NAME, Name]),
    ok.


-spec get_name(Uid :: uid()) -> binary() | {ok, maybe(binary())} | {error, any()}.
get_name(Uid) ->
    {ok, Res} = q(["HGET", account_key(Uid), ?FIELD_NAME]),
    {ok, Res}.


-spec delete_name(Uid :: uid()) -> ok  | {error, any()}.
delete_name(Uid) ->
    {ok, _Res} = q(["HDEL", account_key(Uid), ?FIELD_NAME]),
    ok.


-spec get_name_binary(Uid :: uid()) -> binary().
get_name_binary(Uid) ->
    {ok, Name} = get_name(Uid),
    case Name of
        undefined ->  <<>>;
        _ -> Name
    end.

-spec get_names(Uids :: [uid()]) -> map() | {error, any()}.
get_names([]) -> #{};
get_names(Uids) ->
    Commands = lists:map(fun(Uid) -> ["HGET", account_key(Uid), ?FIELD_NAME] end, Uids),
    Res = qmn(Commands),
    Result = lists:foldl(
        fun({Uid, {ok, Name}}, Acc) ->
            case Name of
                undefined -> Acc;
                _ -> Acc#{Uid => Name}
            end
        end, #{}, lists:zip(Uids, Res)),
    Result.


-spec get_avatar_ids(Uids :: [uid()]) -> map() | {error, any()}.
get_avatar_ids([]) -> #{};
get_avatar_ids(Uids) ->
    Commands = lists:map(fun(Uid) -> ["HGET", account_key(Uid), ?FIELD_AVATAR_ID] end, Uids),
    Res = qmn(Commands),
    Result = lists:foldl(
        fun({Uid, {ok, AvatarId}}, Acc) ->
            case AvatarId of
                undefined -> Acc;
                _ -> Acc#{Uid => AvatarId}
            end
        end, #{}, lists:zip(Uids, Res)),
    Result.


-spec set_avatar_id(Uid :: uid(), AvatarId :: binary()) -> ok  | {error, any()}.
set_avatar_id(Uid, AvatarId) ->
    {ok, _Res} = q(["HSET", account_key(Uid), ?FIELD_AVATAR_ID, AvatarId]),
    ok.


-spec delete_avatar_id(Uid :: uid()) -> ok.
delete_avatar_id(Uid) ->
    {ok, _Res} = q(["HDEL", account_key(Uid), ?FIELD_AVATAR_ID]),
    ok.


-spec get_avatar_id(Uid :: uid()) -> binary() | {ok, maybe(binary())} | {error, any()}.
get_avatar_id(Uid) ->
    {ok, Res} = q(["HGET", account_key(Uid), ?FIELD_AVATAR_ID]),
    {ok, Res}.

-spec get_avatar_id_binary(Uid :: uid()) -> binary().
get_avatar_id_binary(Uid) ->
    {ok, AvatarId} = get_avatar_id(Uid),
    case AvatarId of
        undefined ->  <<>>;
        _ -> AvatarId
    end.


-spec is_username_available(Username :: binary()) -> boolean() | {error, any()}.
is_username_available(Username) ->
    {ok, Res} = q(["HGET", username_uid_key(Username), ?FIELD_USERNAME_UID]),
    Res =:= undefined.


-spec set_username(Uid :: uid(), Username :: binary()) -> true | {false, any()} | {error, any()}.
set_username(Uid, Username) ->
    case get_username(Uid) of
        {ok, Username} ->
            {ok, _} = q(["HSETNX", username_uid_key(Username), ?FIELD_USERNAME_UID, Uid]),
            add_username_prefix(Username, byte_size(Username)),
            true;
        _ ->
            {ok, NotExists} = q(["HSETNX", username_uid_key(Username), ?FIELD_USERNAME_UID, Uid]),
            case NotExists =:= <<"1">> of
                true ->
                    delete_old_username(Uid),
                    {ok, _} = q(["HSET", account_key(Uid), ?FIELD_USERNAME, Username]),
                    add_username_prefix(Username, byte_size(Username)),
                    true;
                false ->
                    {false, notuniq}
            end
    end.


-spec get_username(Uid :: uid()) -> {ok, maybe(binary())} | {error, any()}.
get_username(Uid) ->
    {ok, Res} = q(["HGET", account_key(Uid), ?FIELD_USERNAME]),
    {ok, Res}.

-spec get_username_uid(Username :: binary()) -> {ok, maybe(binary())} | {error, any()}.
get_username_uid(Username) ->
    Map = get_username_uids([Username]),
    {ok, maps:get(Username, Map, undefined)}.

-spec get_username_uids(Usernames :: [binary()]) -> map() | {error, any()}.
get_username_uids([]) -> #{};
get_username_uids(Usernames) ->
    Commands = lists:map(fun(Username) -> ["HGET", username_uid_key(Username), ?FIELD_USERNAME_UID] end, Usernames),
    Res = qmn(Commands),
    Result = lists:foldl(
        fun({Username, {ok, Uid}}, Acc) ->
            case Uid of
                undefined -> Acc;
                _ -> Acc#{Username => Uid}
            end
        end, #{}, lists:zip(Usernames, Res)),
    Result.

-spec delete_old_username(Uid :: uid()) -> ok | {error, any()}.
delete_old_username(Uid) ->
    {ok, OldUsername} = get_username(Uid),
    case OldUsername =/= undefined of
        false -> ok;
        true ->
            delete_username_index(OldUsername)
    end.


-spec delete_username_index(Username :: binary()) -> ok | {error, any()}.
delete_username_index(Username) ->
    {ok, _} = q(["HDEL", username_uid_key(Username), ?FIELD_USERNAME_UID]),
    delete_username_prefix(Username, byte_size(Username)),
    ok.

add_username_prefix(_Username, PrefixLen) when PrefixLen =< 2 ->
    ok;
add_username_prefix(Username, PrefixLen) ->
    <<UsernamePrefix:PrefixLen/binary, _T/binary>> = Username,
    {ok, _Res} = q(["ZADD", username_index_key(UsernamePrefix), 1, Username]),
    add_username_prefix(Username, PrefixLen - 1).

delete_username_prefix(_Username, PrefixLen) when PrefixLen =< 2 ->
    ok;
delete_username_prefix(Username, PrefixLen) ->
    <<UsernamePrefix:PrefixLen/binary, _T/binary>> = Username,
    {ok, _Res} = q(["ZREM", username_index_key(UsernamePrefix), Username]),
    delete_username_prefix(Username, PrefixLen - 1).

-spec search_username_prefix(Prefix :: binary(), Limit :: integer()) -> {ok, [binary()]} | {error, any()}.
search_username_prefix(Prefix, Limit) ->
    {ok, Usernames} = q(["ZRANGEBYLEX", username_index_key(Prefix), "-", "+", "LIMIT", 0, Limit]),
    {ok, Usernames}.


-spec set_bio(Uid :: uid(), Bio :: binary()) -> ok.
set_bio(Uid, Bio) ->
    {ok, _} = q(["HSET", account_key(Uid), ?FIELD_BIO, Bio]),
    ok.


-spec get_bio(Uid :: uid()) -> Bio :: maybe(binary()).
get_bio(Uid) ->
    {ok, Res} = q(["HGET", account_key(Uid), ?FIELD_BIO]),
    util_redis:decode_binary(Res).


-spec set_links(Uid :: uid(), Links :: map()) -> ok.
set_links(Uid, Links) ->
    JsonLinks = jiffy:encode(Links),
    {ok, _} = q(["HSET", account_key(Uid), ?FIELD_LINKS, JsonLinks]),
    ok.


-spec get_links(Uid :: uid()) -> Links :: map().
get_links(Uid) ->
    {ok, Res} = q(["HGET", account_key(Uid), ?FIELD_LINKS]),
    case util_redis:decode_binary(Res) of
        undefined -> #{};
        BinRes ->
            {ResListRaw} = jiffy:decode(BinRes),
            ResList = lists:map(fun({K, V}) -> {util:to_atom(K), V} end, ResListRaw),
            maps:from_list(ResList)
    end.


-spec get_phone(Uid :: uid()) -> {ok, binary()} | {error, missing}.
get_phone(Uid) ->
    {ok, Res} = q(["HGET", account_key(Uid), ?FIELD_PHONE]),
    case Res of
        undefined -> {error, missing};
        Res -> {ok, Res}
    end.


get_phones(Uids) ->
    Commands = lists:map(
        fun(Uid) ->
            ["HGET", account_key(Uid), ?FIELD_PHONE]
        end, Uids),
    Results = qmn(Commands),
    lists:map(fun({ok, Result}) -> Result end, Results).


-spec get_creation_ts_ms(Uid :: uid()) -> {ok, integer()} | {error, missing}.
get_creation_ts_ms(Uid) ->
    {ok, Res} = q(["HGET", account_key(Uid), ?FIELD_CREATION_TIME]),
    ts_reply(Res).


-spec get_last_registration_ts_ms(Uid :: uid()) -> {ok, integer()} | {error, missing}.
get_last_registration_ts_ms(Uid) ->
    {ok, Res} = q(["HGET", account_key(Uid), ?FIELD_LAST_REGISTRATION_TIME]),
    ts_reply(Res).


-spec mark_first_non_empty_sync_done(Uid :: uid()) -> {ok, boolean()} | {error, missing}.
mark_first_non_empty_sync_done(Uid) ->
    {ok, Exists} = q(["HSETNX", account_key(Uid), ?FIELD_NON_EMPTY_SYNC_STATUS, 1]),
    {ok, Exists =:= <<"1">>}.


-spec is_first_non_empty_sync_done(Uid :: uid()) -> boolean() | {error, missing}.
is_first_non_empty_sync_done(Uid) ->
    {ok, Res} = q(["HGET", account_key(Uid), ?FIELD_NON_EMPTY_SYNC_STATUS]),
    Res =:= <<"1">>.


-spec delete_first_non_empty_sync_status(Uid :: uid()) -> ok | {error, missing}.
delete_first_non_empty_sync_status(Uid) ->
    {ok, _} = q(["HDEL", account_key(Uid), ?FIELD_NON_EMPTY_SYNC_STATUS]),
    ok.


-spec mark_first_sync_done(Uid :: uid()) -> {ok, boolean()} | {error, missing}.
mark_first_sync_done(Uid) ->
    {ok, Exists} = q(["HSETNX", account_key(Uid), ?FIELD_SYNC_STATUS, 1]),
    {ok, Exists =:= <<"1">>}.


-spec is_first_sync_done(Uid :: uid()) -> boolean() | {error, missing}.
is_first_sync_done(Uid) ->
    {ok, Res} = q(["HGET", account_key(Uid), ?FIELD_SYNC_STATUS]),
    Res =:= <<"1">>.


-spec delete_first_sync_status(Uid :: uid()) -> ok | {error, missing}.
delete_first_sync_status(Uid) ->
    {ok, _} = q(["HDEL", account_key(Uid), ?FIELD_SYNC_STATUS]),
    ok.


-spec set_user_agent(Uid :: uid(), UserAgent :: binary()) -> ok.
set_user_agent(Uid, UserAgent) ->
    {ok, _Res} = q(["HSET", account_key(Uid), ?FIELD_USER_AGENT, UserAgent]),
    ok.


-spec set_last_registration_ts_ms(Uid :: uid(), RegistrationTsMs :: integer()) -> ok.
set_last_registration_ts_ms(Uid, RegistrationTsMs) ->
    {ok, _Res} = q(["HSET", account_key(Uid), ?FIELD_LAST_REGISTRATION_TIME, util:to_binary(RegistrationTsMs)]),
    ok.


-spec get_signup_user_agent(Uid :: uid()) -> {ok, binary()} | {error, missing}.
get_signup_user_agent(Uid) ->
    {ok, Res} = q(["HGET", account_key(Uid), ?FIELD_USER_AGENT]),
    case Res of
        undefined -> {error, missing};
        Res -> {ok, Res}
    end.


-spec set_client_info(Uid :: uid(), Version :: binary(), Device :: binary(), OsVersion :: binary()) -> ok.
set_client_info(Uid, Version, Device, OsVersion) ->
    Slot = util_redis:eredis_hash(binary_to_list(Uid)),
    NewSlot = Slot rem ?NUM_VERSION_SLOTS,
    AppType = util_uid:get_app_type(Uid),
    VersionCommands = case get_client_and_os_version(Uid) of
        {ok, OldClient, OldOs} ->
            [["HINCRBY", version_key(NewSlot), OldClient, -1],
            ["HINCRBY", os_version_key(NewSlot, AppType), OldOs, -1]];
        _ -> []
    end,
    qmn([["HMSET", account_key(Uid), ?FIELD_DEVICE, Device, ?FIELD_OS_VERSION, OsVersion, ?FIELD_CLIENT_VERSION, Version],
        ["HINCRBY", os_version_key(NewSlot, AppType), OsVersion, 1],
        ["HINCRBY", version_key(NewSlot), Version, 1]] ++ VersionCommands),
    ok.


-spec get_client_and_os_version(Uid :: uid()) -> {ok, binary(), binary()} | {error, missing}.
get_client_and_os_version(Uid) ->
    {ok, Res} = q(["HMGET", account_key(Uid), ?FIELD_CLIENT_VERSION, ?FIELD_OS_VERSION]),
    case Res of
        [undefined, undefined] -> {error, missing};
        [Client, Os] -> {ok, Client, Os}
    end.


-spec set_client_version(Uid :: uid(), Version :: binary()) -> ok.
set_client_version(Uid, Version) ->
    Slot = util_redis:eredis_hash(binary_to_list(Uid)),
    NewSlot = Slot rem ?NUM_VERSION_SLOTS,
    VersionCommands = case get_client_version(Uid) of
        {ok, OldVersion} ->
            [["HINCRBY", version_key(NewSlot), OldVersion, -1]];
        _ -> []
    end,
    {ok, _} = q(["HSET", account_key(Uid), ?FIELD_CLIENT_VERSION, Version]),
    [{ok, _} | _] = qp([
            ["HINCRBY", version_key(NewSlot), Version, 1] | VersionCommands]),
    ok.


-spec get_client_version(Uid :: uid()) -> {ok, maybe(binary())} | {error, missing}.
get_client_version(Uid) ->
    {ok, Res} = q(["HGET", account_key(Uid), ?FIELD_CLIENT_VERSION]),
    case Res of
        undefined -> {error, missing};
        Res -> {ok, Res}
    end.


-spec set_device_info(Uid :: uid(), Device :: maybe(binary()), OsVersion :: maybe(binary())) -> ok.
set_device_info(Uid, Device, OsVersion) ->
    Slot = util_redis:eredis_hash(binary_to_list(Uid)),
    NewSlot = Slot rem ?NUM_VERSION_SLOTS,
    AppType = util_uid:get_app_type(Uid),
    OldVersionCommands = case get_os_version(Uid) of
        {ok, OldVersion} ->
            [["HINCRBY", os_version_key(NewSlot, AppType), OldVersion, -1]];
        _ -> []
    end,
    {ok, _} = q(["HMSET", account_key(Uid), ?FIELD_DEVICE, Device, ?FIELD_OS_VERSION, OsVersion]),
    [{ok, _} | _] = qp([
            ["HINCRBY", os_version_key(NewSlot, AppType), OsVersion, 1] | OldVersionCommands]),
    ok.


-spec get_os_version(Uid :: uid()) -> {ok, binary()} | {error, missing}.
get_os_version(Uid) ->
    {ok, Res} = q(["HGET", account_key(Uid), ?FIELD_OS_VERSION]),
    case Res of
        undefined -> {error, missing};
        Res -> {ok, Res}
    end.


-spec get_device(Uid :: uid()) -> {ok, binary()} | {error, missing}.
get_device(Uid) ->
    case q(["HGET", account_key(Uid), ?FIELD_DEVICE]) of
        {ok, undefined} -> {error, missing};
        {ok, Res} -> {ok, Res}
    end.


-spec get_account(Uid :: uid()) -> {ok, account()} | {error, missing}.
get_account(Uid) ->
    {ok, Res} = q(["HGETALL", account_key(Uid)]),
    M = util:list_to_map(Res),
    Phone = maps:get(?FIELD_PHONE, M, undefined),
    case Phone of
        undefined -> {error, missing};
        _ ->
            Account = #account{
                    uid = Uid,
                    phone = Phone,
                    name = maps:get(?FIELD_NAME, M, undefined),
                    signup_user_agent = maps:get(?FIELD_USER_AGENT, M, undefined),
                    campaign_id = maps:get(?FIELD_CAMPAIGN_ID, M, <<>>),
                    creation_ts_ms = util_redis:decode_ts(maps:get(?FIELD_CREATION_TIME, M, undefined)),
                    last_registration_ts_ms = util_redis:decode_ts(maps:get(?FIELD_LAST_REGISTRATION_TIME, M, undefined)),
                    last_activity_ts_ms = util_redis:decode_ts(maps:get(?FIELD_LAST_ACTIVITY, M, undefined)),
                    activity_status = util:to_atom(maps:get(?FIELD_ACTIVITY_STATUS, M, undefined)),
                    client_version = maps:get(?FIELD_CLIENT_VERSION, M, undefined),
                    lang_id = maps:get(?FIELD_PUSH_LANGUAGE_ID, M, undefined),
                    zone_offset = util_redis:decode_int(maps:get(?FIELD_ZONE_OFFSET, M, undefined)),
                    device = maps:get(?FIELD_DEVICE, M, undefined),
                    os_version = maps:get(?FIELD_OS_VERSION, M, undefined),
                    last_ipaddress = util:to_list(maps:get(?FIELD_LAST_IPADDRESS, M, undefined)),
                    avatar_id = maps:get(?FIELD_AVATAR_ID, M, undefined),
                    username = maps:get(?FIELD_USERNAME, M, undefined)
                },
            {ok, Account}
    end.

%%====================================================================
%% Push-tokens related API
%%====================================================================

-spec get_lang_id(Uid :: binary()) -> {ok, binary() | undefined}.
get_lang_id(Uid) ->
    {ok, LangId} = q(["HGET", account_key(Uid), ?FIELD_PUSH_LANGUAGE_ID]),
    {ok, LangId}.



-spec set_push_token(Uid :: uid(), TokenType :: binary(), PushToken :: binary(),
        TimestampMs :: integer(), LangId :: binary()) -> ok.
set_push_token(Uid, TokenType, PushToken, TimestampMs, LangId) ->
    set_push_token(Uid, TokenType, PushToken, TimestampMs, LangId, undefined).


%% We will first run a migration to set values appropriately for lang_id keys on all slots.
%% Then set the value for lang_id key in persistent_term storage.
%% In the next diff - we can cleanup this code.
-spec set_push_token(Uid :: uid(), TokenType :: binary(), PushToken :: binary(),
        TimestampMs :: integer(), LangId :: binary(), ZoneOffset :: maybe(integer())) -> ok.
set_push_token(Uid, TokenType, PushToken, TimestampMs, LangId, ZoneOffset) ->
    {ok, OldPushInfo} = get_push_info(Uid),
    OldLangId = OldPushInfo#push_info.lang_id,
    OldZoneOffset = OldPushInfo#push_info.zone_offset,
    {ok, _Res} = q([
            "HMSET", account_key(Uid),
            ?FIELD_PUSH_OS, TokenType,
            ?FIELD_PUSH_TOKEN, PushToken,
            ?FIELD_PUSH_TIMESTAMP, integer_to_binary(TimestampMs),
            ?FIELD_PUSH_LANGUAGE_ID, LangId,
            ?FIELD_ZONE_OFFSET, util:to_binary(ZoneOffset)
        ]),
    update_lang_counters(Uid, LangId, OldLangId),
    update_zone_offset_tag(Uid, ZoneOffset, OldZoneOffset),
    ok.


-spec set_huawei_token(Uid :: binary(), HuaweiToken :: binary(),
    TimestampMs :: integer(), LangId :: binary(), ZoneOffset :: integer()) -> ok.
set_huawei_token(Uid, HuaweiToken, TimestampMs, LangId, ZoneOffset) ->
    {ok, OldLangId} = get_lang_id(Uid),
    {ok, _Res} = q([
            "HMSET", account_key(Uid),
            ?FIELD_PUSH_OS, ?ANDROID_HUAWEI_TOKEN_TYPE,
            ?FIELD_HUAWEI_TOKEN, HuaweiToken,
            ?FIELD_PUSH_TIMESTAMP, integer_to_binary(TimestampMs),
            ?FIELD_PUSH_LANGUAGE_ID, LangId,
            ?FIELD_ZONE_OFFSET, util:to_binary(ZoneOffset)
        ]),
    update_lang_counters(Uid, LangId, OldLangId),
    ok.


-spec set_voip_token(Uid :: binary(), VoipToken :: binary(),
    TimestampMs :: integer(), LangId :: binary(), ZoneOffset :: integer()) -> ok.
set_voip_token(Uid, VoipToken, TimestampMs, LangId, ZoneOffset) ->
    {ok, OldLangId} = get_lang_id(Uid),
    {ok, _Res} = q([
            "HMSET", account_key(Uid),
            ?FIELD_VOIP_TOKEN, VoipToken,
            ?FIELD_PUSH_TIMESTAMP, integer_to_binary(TimestampMs),
            ?FIELD_PUSH_LANGUAGE_ID, LangId,
            ?FIELD_ZONE_OFFSET, util:to_binary(ZoneOffset)
        ]),
    update_lang_counters(Uid, LangId, OldLangId),
    ok.


-spec update_lang_counters(Uid :: binary(), LangId :: binary(), OldLangId :: binary()) -> ok.
update_lang_counters(Uid, LangId, OldLangId) ->
    HashSlot = util_redis:eredis_hash(binary_to_list(Uid)),
    LangSlot = HashSlot rem ?NUM_SLOTS,
    AppType = util_uid:get_app_type(Uid),
    case OldLangId of
        undefined ->
            [{ok, _}] = qp([["HINCRBY", lang_key(LangSlot, AppType), LangId, 1]]),
            ok;
        LangId -> ok;
        OldLangId ->
            [{ok, _}, {ok, _}] = qp([
                    ["HINCRBY", lang_key(LangSlot, AppType), LangId, 1],
                    ["HINCRBY", lang_key(LangSlot, AppType), OldLangId, -1]
                ]),
            ok
    end,
    ok.


update_zone_offset_tag2(Uid, ZoneOffsetSec, OldZoneOffsetSec) when is_integer(ZoneOffsetSec) ->
    HashSlot = util_redis:eredis_hash(binary_to_list(Uid)),
    Slot = HashSlot rem ?NUM_SLOTS,
    ZoneOffsetTag = util:to_binary(mod_moment_notification:get_four_zone_offset_hr(ZoneOffsetSec)),
    Commands = case OldZoneOffsetSec of
        undefined ->
            [["SADD", zone_offset_tag_key(Slot, ZoneOffsetTag), Uid]];
        _ ->
            OldOffsetTag = util:to_binary(OldZoneOffsetSec div ?MOMENT_TAG_INTERVAL_SEC),
            [["SREM", zone_offset_tag_key(Slot, OldOffsetTag), Uid],
            ["SADD", zone_offset_tag_key(Slot, ZoneOffsetTag), Uid]]
    end,
    qp(Commands),
    ok.

-spec update_zone_offset_tag(Uid :: binary(), ZoneOffsetSec :: maybe(integer()), OldZoneOffsetSec :: maybe(integer())) -> ok.
update_zone_offset_tag(Uid, ZoneOffsetSec, OldZoneOffsetSec) when is_integer(ZoneOffsetSec) andalso ZoneOffsetSec =/= OldZoneOffsetSec ->
    HashSlot = util_redis:eredis_hash(binary_to_list(Uid)),
    Slot = HashSlot rem ?NUM_SLOTS,
    ZoneOffsetTag = util:to_binary(mod_moment_notification:get_four_zone_offset_hr(ZoneOffsetSec)),
    Commands = case OldZoneOffsetSec of
        undefined ->
            [["SADD", zone_offset_tag_key(Slot, ZoneOffsetTag), Uid]];
        _ ->
            OldOffsetTag = util:to_binary(mod_moment_notification:get_four_zone_offset_hr(OldZoneOffsetSec)),
            [["SREM", zone_offset_tag_key(Slot, OldOffsetTag), Uid],
            ["SADD", zone_offset_tag_key(Slot, ZoneOffsetTag), Uid]]
    end,
    qp(Commands),
    ok;
update_zone_offset_tag(_Uid, _ZoneOffsetSec, _OldZoneOffsetSec) ->
    ok.

-spec delete_zone_offset_tag(Uid :: binary(), ZoneOffsetSec :: integer()) -> ok.
delete_zone_offset_tag(Uid, ZoneOffsetSec) when is_integer(ZoneOffsetSec) ->
    HashSlot = util_redis:eredis_hash(binary_to_list(Uid)),
    Slot = HashSlot rem ?NUM_SLOTS,
    ZoneOffsetTag = util:to_binary(mod_moment_notification:get_four_zone_offset_hr(ZoneOffsetSec)),
    q(["SREM", zone_offset_tag_key(Slot, ZoneOffsetTag), Uid]),
    ok.
 
-spec get_zone_offset_tag_uids(ZoneOffsetSec :: integer()) -> {ok, [binary()]}.
get_zone_offset_tag_uids(ZoneOffsetSec) ->
    ZoneOffsetTag = util:to_binary(ZoneOffsetSec div ?MOMENT_TAG_INTERVAL_SEC),
    ListUids = lists:foldl(
        fun (Slot, Acc) ->
            {ok, Res} = q(["SMEMBERS", zone_offset_tag_key(Slot, ZoneOffsetTag)]),
            Acc ++ Res
        end,
        [],
        lists:seq(0, ?NUM_SLOTS - 1)),
    {ok, ListUids}.

-spec del_zone_offset(ZoneOffsetSec :: integer()) -> ok.
del_zone_offset(ZoneOffsetSec) ->
    ZoneOffsetTag = util:to_binary(ZoneOffsetSec div ?MOMENT_TAG_INTERVAL_SEC),
    lists:foreach(
        fun(Slot) ->
            {ok, _} = q(["DEL", zone_offset_tag_key(Slot, ZoneOffsetTag)])
        end, lists:seq(0, ?NUM_SLOTS - 1)),
    ok.

-spec remove_android_token(Uid :: uid()) -> ok | {error, missing}.
remove_android_token(Uid) ->
    {ok, _Res} = q(["HDEL", account_key(Uid), ?FIELD_PUSH_TOKEN]),
    ok.


-spec remove_huawei_token(Uid :: uid()) -> ok | {error, missing}.
remove_huawei_token(Uid) ->
    {ok, _Res} = q(["HDEL", account_key(Uid), ?FIELD_HUAWEI_TOKEN]),
    ok.


-spec get_push_info(Uid :: uid()) -> {ok, maybe(push_info())}.
get_push_info(Uid) ->
    {ok, [Os, Token, TimestampMs, PushPost, PushComment, ClientVersion, LangId, VoipToken, HuaweiToken, ZoneOffset]} = q(
            ["HMGET", account_key(Uid), ?FIELD_PUSH_OS, ?FIELD_PUSH_TOKEN, ?FIELD_PUSH_TIMESTAMP,
            ?FIELD_PUSH_POST, ?FIELD_PUSH_COMMENT, ?FIELD_CLIENT_VERSION, ?FIELD_PUSH_LANGUAGE_ID,
            ?FIELD_VOIP_TOKEN, ?FIELD_HUAWEI_TOKEN, ?FIELD_ZONE_OFFSET]),
    Res = #push_info{
            uid = Uid,
            os = Os,
            token = Token,
            voip_token = VoipToken,
            huawei_token = HuaweiToken,
            timestamp_ms = util_redis:decode_ts(TimestampMs),
            post_pref = boolean_decode(PushPost, true),
            comment_pref = boolean_decode(PushComment, true),
            client_version = ClientVersion,
            lang_id = LangId,
            zone_offset = util_redis:decode_int(ZoneOffset)
        },
    {ok, Res}.


-spec remove_push_info(Uid :: uid()) -> ok | {error, missing}.
remove_push_info(Uid) ->
    {ok, _Res} = q(["HDEL", account_key(Uid), ?FIELD_PUSH_OS, ?FIELD_PUSH_TOKEN,
        ?FIELD_PUSH_TIMESTAMP, ?FIELD_PUSH_LANGUAGE_ID, ?FIELD_VOIP_TOKEN, ?FIELD_HUAWEI_TOKEN]),
    ok.


-spec set_push_post_pref(Uid :: uid(), PushPost :: boolean()) -> ok.
set_push_post_pref(Uid, PushPost) ->
    PushPostValue = boolean_encode(PushPost),
    {ok, _Res} = q(["HSET", account_key(Uid), ?FIELD_PUSH_POST, PushPostValue]),
    ok.


-spec get_push_post_pref(Uid :: uid()) -> {ok, boolean()}.
get_push_post_pref(Uid) ->
    {ok, PushPostValue} = q(["HGET", account_key(Uid), ?FIELD_PUSH_POST]),
    Res = boolean_decode(PushPostValue, true),
    {ok, Res}.


-spec remove_push_post_pref(Uid :: uid()) -> ok | {error, missing}.
remove_push_post_pref(Uid) ->
    {ok, _Res} = q(["HDEL", account_key(Uid), ?FIELD_PUSH_POST]),
    ok.


-spec set_push_comment_pref(Uid :: uid(), PushComment :: boolean()) -> ok.
set_push_comment_pref(Uid, PushComment) ->
    PushCommentValue = boolean_encode(PushComment),
    {ok, _Res} = q(["HMSET", account_key(Uid), ?FIELD_PUSH_COMMENT, PushCommentValue]),
    ok.


-spec get_push_comment_pref(Uid :: uid()) -> {ok, boolean()}.
get_push_comment_pref(Uid) ->
    {ok, [PushCommentValue]} = q(["HMGET", account_key(Uid), ?FIELD_PUSH_COMMENT]),
    Res = boolean_decode(PushCommentValue, true),
    {ok, Res}.


-spec remove_push_comment_pref(Uid :: uid()) -> ok | {error, missing}.
remove_push_comment_pref(Uid) ->
    {ok, _Res} = q(["HDEL", account_key(Uid), ?FIELD_PUSH_COMMENT]),
    ok.

-spec set_push_mention_pref(Uid :: uid(), PushPref :: boolean()) -> ok.
set_push_mention_pref(Uid, PushPref) ->
    PushPrefValue = boolean_encode(PushPref),
    {ok, _Res} = q(["HSET", account_key(Uid), ?FIELD_PUSH_MENTION, PushPrefValue]),
    ok.

-spec set_push_fire_pref(Uid :: uid(), PushPref :: boolean()) -> ok.
set_push_fire_pref(Uid, PushPref) ->
    PushPrefValue = boolean_encode(PushPref),
    {ok, _Res} = q(["HSET", account_key(Uid), ?FIELD_PUSH_FIRE, PushPrefValue]),
    ok.

-spec set_push_new_user_pref(Uid :: uid(), PushPref :: boolean()) -> ok.
set_push_new_user_pref(Uid, PushPref) ->
    PushPrefValue = boolean_encode(PushPref),
    {ok, _Res} = q(["HSET", account_key(Uid), ?FIELD_PUSH_NEW_USER, PushPrefValue]),
    ok.

-spec set_push_follower_pref(Uid :: uid(), PushPref :: boolean()) -> ok.
set_push_follower_pref(Uid, PushPref) ->
    PushPrefValue = boolean_encode(PushPref),
    {ok, _Res} = q(["HSET", account_key(Uid), ?FIELD_PUSH_FOLLOWER, PushPrefValue]),
    ok.


-spec get_zone_offset(Uid :: uid()) -> maybe(integer()).
get_zone_offset(Uid) ->
    {ok, Res} = q(["HGET", account_key(Uid), ?FIELD_ZONE_OFFSET]),
    util_redis:decode_int(Res).


-spec account_exists(Uid :: uid()) -> boolean().
account_exists(Uid) ->
    {ok, Res} = q(["HEXISTS", account_key(Uid), ?FIELD_PHONE]),
    binary_to_integer(Res) > 0.


-spec accounts_exist(Uids :: [uid()]) -> [{uid(), boolean()}].
accounts_exist(Uids) ->
    Commands = lists:map(fun (Uid) -> 
            ["HEXISTS", account_key(Uid), ?FIELD_PHONE] 
        end, 
        Uids),
    Res = qmn(Commands),
    lists:map(
        fun({Uid, {ok, Exists}}) ->
            {Uid, binary_to_integer(Exists) > 0}
        end, lists:zip(Uids, Res)).


-spec filter_nonexisting_uids(Uids :: [uid()]) -> [uid()].
filter_nonexisting_uids(Uids) ->
    UidExistence = model_accounts:accounts_exist(Uids),
    lists:foldr(
        fun ({Uid, Exists}, Acc) ->
            case Exists of
                true -> [Uid | Acc];
                false -> Acc
            end
        end,
        [],
        UidExistence).


-spec is_account_deleted(Uid :: uid()) -> boolean().
is_account_deleted(Uid) ->
    {ok, Res} = q(["EXISTS", deleted_uid_key(Uid)]),
    binary_to_integer(Res) > 0.


-spec get_deleted_account(Uid :: uid()) ->
        {error, not_deleted} | {DeletionTsMs :: non_neg_integer(), account()}.
get_deleted_account(Uid) ->
    case is_account_deleted(Uid) of
        false -> {error, not_deleted};
        true ->
            {ok, Res} = q(["HMGET",
                deleted_uid_key(Uid),
                ?FIELD_CREATION_TIME,
                ?FIELD_LAST_REGISTRATION_TIME,
                ?FIELD_LAST_ACTIVITY,
                ?FIELD_ACTIVITY_STATUS,
                ?FIELD_USER_AGENT,
                ?FIELD_CAMPAIGN_ID,
                ?FIELD_CLIENT_VERSION,
                ?FIELD_DELETION_TIME,
                ?FIELD_DEVICE,
                ?FIELD_OS_VERSION
            ]),
            [CreationTime, LastRegTime, LastActivity, ActivityStatus,
                UserAgent, CampaignId, ClientVersion, DeletionTsMs, Device, Os] = Res,
            Account = #account{
                uid = Uid,
                creation_ts_ms = util:to_integer(CreationTime),
                last_registration_ts_ms = util:to_integer(LastRegTime),
                signup_user_agent = UserAgent,
                campaign_id = CampaignId,
                client_version = ClientVersion,
                last_activity_ts_ms = util:to_integer_maybe(LastActivity),
                activity_status = ActivityStatus,
                device = Device,
                os_version = Os
            },
            {util:to_integer(DeletionTsMs), Account}
    end.


%%====================================================================
%% Store Last IP address
%%====================================================================

-spec set_last_ip_and_connection_time(Uid :: uid(), IPAddress :: list(), TsMs :: integer()) -> ok.
set_last_ip_and_connection_time(Uid, IPAddress, TsMs) ->
    {ok, _Res1} = q(["HSET", account_key(Uid),
        ?FIELD_LAST_IPADDRESS, util:to_binary(IPAddress),
        ?FIELD_LAST_CONNECTION_TIME, TsMs]),
    ok.


-spec get_last_ipaddress(Uid :: uid()) -> maybe(binary()).
get_last_ipaddress(Uid) ->
    {ok, IPAddress} = q(["HGET", account_key(Uid), ?FIELD_LAST_IPADDRESS]),
    util_redis:decode_binary(IPAddress).


-spec get_last_connection_time(Uid :: uid()) -> maybe(integer()).
get_last_connection_time(Uid) ->
    {ok, LastConnTime} = q(["HGET", account_key(Uid), ?FIELD_LAST_CONNECTION_TIME]),
    util_redis:decode_ts(LastConnTime).

%%====================================================================
%% Presence related API
%%====================================================================


-spec set_last_activity(Uid :: uid(), TimestampMs :: integer(),
        ActivityStatus :: maybe(activity_status())) -> ok | {error, any()}.
set_last_activity(Uid, TimestampMs, ActivityStatus) ->
    Res = q(
            ["HMSET", account_key(Uid),
            ?FIELD_LAST_ACTIVITY, integer_to_binary(TimestampMs),
            ?FIELD_ACTIVITY_STATUS, util:to_binary(ActivityStatus)]),
    util_redis:verify_ok(Res).


-spec get_last_activity(Uid :: uid()) -> {ok, activity()} | {error, missing}.
get_last_activity(Uid) ->
    {ok, [TimestampMs, ActivityStatus]} = q(
            ["HMGET", account_key(Uid), ?FIELD_LAST_ACTIVITY, ?FIELD_ACTIVITY_STATUS]),
    Res = case util_redis:decode_ts(TimestampMs) of
            undefined ->
                #activity{uid = Uid};
            TsMs ->
                #activity{uid = Uid, last_activity_ts_ms = TsMs,
                        status = util:to_atom(ActivityStatus)}
        end,
    {ok, Res}.


-spec get_last_activity_ts_ms(Uids :: [uid()]) -> map() | {error, any()}.
get_last_activity_ts_ms([]) -> #{};
get_last_activity_ts_ms(Uids) ->
    Commands = lists:map(fun(Uid) -> ["HGET", account_key(Uid), ?FIELD_LAST_ACTIVITY] end, Uids),
    Res = qmn(Commands),
    Result = lists:foldl(
        fun({Uid, {ok, TimestampMs}}, Acc) ->
            case util_redis:decode_ts(TimestampMs) of
                undefined -> Acc;
                TsMs -> Acc#{Uid => TsMs}
            end
        end, #{}, lists:zip(Uids, Res)),
    Result.


-spec presence_subscribe(Uid :: uid(), Buid :: binary()) -> ok.
presence_subscribe(Uid, Buid) ->
    {ok, _Res1} = q(["SADD", subscribe_key(Uid), Buid]),
    {ok, _Res2} = q(["SADD", broadcast_key(Buid), Uid]),
    ok.


-spec presence_unsubscribe(Uid :: uid(), Buid :: binary()) -> ok.
presence_unsubscribe(Uid, Buid) ->
    {ok, _Res1} = q(["SREM", subscribe_key(Uid), Buid]),
    {ok, _Res2} = q(["SREM", broadcast_key(Buid), Uid]),
    ok.


-spec presence_unsubscribe_all(Uid :: uid()) -> ok.
presence_unsubscribe_all(Uid) ->
    {ok, Buids} = q(["SMEMBERS", subscribe_key(Uid)]),
    UnsubscribeCommands = lists:map(fun (Buid) ->
            ["SREM", broadcast_key(Buid), Uid]
        end,
        Buids),
    qmn(UnsubscribeCommands),
    {ok, _} = q(["DEL", subscribe_key(Uid)]),
    ok.


-spec get_subscribed_uids(Uid :: uid()) -> {ok, [binary()]}.
get_subscribed_uids(Uid) ->
    {ok, Buids} = q(["SMEMBERS", subscribe_key(Uid)]),
    {ok, Buids}.


-spec get_broadcast_uids(Uid :: uid()) -> {ok, [binary()]}.
get_broadcast_uids(Uid) ->
    {ok, Buids} = q(["SMEMBERS", broadcast_key(Uid)]),
    {ok, Buids}.


-spec get_basic_user_profiles(Uid :: uid(), Ouids :: uid() | list(uid()))
        -> pb_basic_user_profile() | list(pb_basic_user_profile()).
get_basic_user_profiles(Uid, Ouids) when is_list(Ouids) ->
    lists:map(
        fun(Ouid) ->
            case model_follow:is_blocked_any(Uid, Ouid) of
                true -> get_blocked_basic_user_profile(Uid, Ouid);
                false -> get_basic_user_profile(Uid, Ouid)
            end
        end,
        Ouids);

get_basic_user_profiles(Uid, Ouid) ->
    [BasicUserProfile] = get_basic_user_profiles(Uid, [Ouid]),
    BasicUserProfile.


get_basic_user_profile(Uid, Ouid) ->
    [{ok, Username}, {ok, Name}, {ok, AvatarId}, {ok, IsFollower}, {ok, IsFollowing}, {ok, IsBlocked}] = qmn([
        ["HGET", account_key(Ouid), ?FIELD_USERNAME],
        ["HGET", account_key(Ouid), ?FIELD_NAME],
        ["HGET", account_key(Ouid), ?FIELD_AVATAR_ID],
        ["ZSCORE", model_follow:follower_key(Uid), Ouid],
        ["ZSCORE", model_follow:following_key(Uid), Ouid],
        ["SISMEMBER", model_follow:blocked_key(Uid), Ouid]
    ]),
    FollowerStatus = case util_redis:decode_int(IsFollower) of
        undefined -> none;
        0 -> none;
        _ -> following
    end,
    FollowingStatus = case util_redis:decode_int(IsFollowing) of
        undefined -> none;
        0 -> none;
        _ -> following
    end,
    Following = sets:from_list(model_follow:get_all_following(Uid)),
    OFollowing = sets:from_list(model_follow:get_all_following(Ouid)),
    #pb_basic_user_profile{
        uid = Ouid,
        username = Username,
        name = Name,
        avatar_id = AvatarId,
        follower_status = FollowerStatus,
        following_status = FollowingStatus,
        num_mutual_following = sets:size(sets:intersection(OFollowing, Following)),
        blocked = util_redis:decode_boolean(IsBlocked)
    }.


get_blocked_basic_user_profile(Uid, Ouid) ->
    {ok, Username} = get_username(Ouid),
    #pb_basic_user_profile{
        uid = Ouid,
        username = Username,
        following_status = none,
        follower_status = none,
        blocked = model_follow:is_blocked(Uid, Ouid)
    }.


-spec get_user_profiles(uid(), uid() | list(uid())) -> pb_user_profile() | list(pb_user_profile()).
get_user_profiles(Uid, Ouids) when is_list(Ouids) ->
    lists:map(
        fun(Ouid) ->
            case model_follow:is_blocked_any(Uid, Ouid) of
                true -> get_blocked_user_profile(Uid, Ouid);
                false -> get_user_profile(Uid, Ouid)
            end
        end,
        Ouids);

get_user_profiles(Uid, Ouid) ->
    [UserProfile] = get_user_profiles(Uid, [Ouid]),
    UserProfile.


get_user_profile(Uid, Ouid) ->
    [{ok, Username}, {ok, Name}, {ok, AvatarId}, {ok, RawBio}, {ok, LinksJson},
            {ok, IsFollower}, {ok, IsFollowing}, {ok, IsBlocked}] = qmn([
        ["HGET", account_key(Ouid), ?FIELD_USERNAME],
        ["HGET", account_key(Ouid), ?FIELD_NAME],
        ["HGET", account_key(Ouid), ?FIELD_AVATAR_ID],
        ["HGET", account_key(Ouid), ?FIELD_BIO],
        ["HGET", account_key(Ouid), ?FIELD_LINKS],
        ["ZSCORE", model_follow:follower_key(Uid), Ouid],
        ["ZSCORE", model_follow:following_key(Uid), Ouid],
        ["SISMEMBER", model_follow:blocked_key(Uid), Ouid]
    ]),
    FollowerStatus = case util_redis:decode_int(IsFollower) of
        undefined -> none;
        0 -> none;
        _ -> following
    end,
    FollowingStatus = case util_redis:decode_int(IsFollowing) of
        undefined -> none;
        0 -> none;
        _ -> following
    end,
    Following = sets:from_list(model_follow:get_all_following(Uid)),
    OFollowing = sets:from_list(model_follow:get_all_following(Ouid)),
    Bio = case RawBio of
        undefined -> <<>>;
        _ -> RawBio
    end,
    Links = case LinksJson of
        undefined -> [];
        _ ->
            {LinksListRaw} = jiffy:decode(LinksJson),
            lists:map(
                fun({K, V}) ->
                    #pb_link{
                        type = util:to_atom(K),
                        text = V
                    }
                end,
                LinksListRaw)
    end,
     %% Fetch Relevant followers.
    OuidFollowers = model_follow:get_all_followers(Ouid),
    RelevantFollowerUids = sets:to_list(sets:intersection(sets:from_list(Following), sets:from_list(OuidFollowers))),
    RelevantFollowerBasicProfiles = get_basic_user_profiles(Uid, RelevantFollowerUids),
    #pb_user_profile{
        uid = Ouid,
        username = Username,
        name = Name,
        avatar_id = AvatarId,
        follower_status = FollowerStatus,
        following_status = FollowingStatus,
        num_mutual_following = sets:size(sets:intersection(OFollowing, Following)),
        bio = Bio,
        links = Links,
        relevant_followers = RelevantFollowerBasicProfiles,
        blocked = util_redis:decode_boolean(IsBlocked)
    }.


get_blocked_user_profile(Uid, Ouid) ->
    {ok, Username} = get_username(Ouid),
    #pb_user_profile{
        uid = Ouid,
        username = Username,
        following_status = none,
        follower_status = none,
        blocked = model_follow:is_blocked(Uid, Ouid)
    }.

%%====================================================================
%% Counts related API
%%====================================================================


-spec count_registrations() -> #{app_type() => non_neg_integer()}.
count_registrations() ->
    HalloAppCount = redis_counts:count_by_slot(ecredis_accounts, fun count_registration_query/2, ?HALLOAPP),
    KatchupCount = redis_counts:count_by_slot(ecredis_accounts, fun count_registration_query/2, ?KATCHUP),
    #{?HALLOAPP => HalloAppCount, ?KATCHUP => KatchupCount}.

-spec count_registrations(Slot :: non_neg_integer(), AppType :: app_type()) -> non_neg_integer().
count_registrations(Slot, AppType) ->
    {ok, CountBin} = q(count_registration_query(Slot, AppType)),
    Count = case CountBin of
        undefined -> 0;
        CountBin -> binary_to_integer(CountBin)
    end,
    Count.

-spec count_registration_query(Slot :: non_neg_integer(), AppType :: app_type()) -> ecredis:redis_command().
count_registration_query(Slot, AppType) ->
    ["GET", count_registrations_slot_key(Slot, AppType)].


-spec count_accounts() -> #{app_type() => non_neg_integer()}.
count_accounts() ->
    HalloAppCount = redis_counts:count_by_slot(ecredis_accounts, fun count_accounts_query/2, ?HALLOAPP),
    KatchupCount = redis_counts:count_by_slot(ecredis_accounts, fun count_accounts_query/2, ?KATCHUP),
    #{?HALLOAPP => HalloAppCount, ?KATCHUP => KatchupCount}.


    -spec count_accounts(Slot :: non_neg_integer(), AppType :: app_type()) -> non_neg_integer().
count_accounts(Slot, AppType) ->
    {ok, CountBin} = q(count_accounts_query(Slot, AppType)),
    Count = case CountBin of
        undefined -> 0;
        CountBin -> binary_to_integer(CountBin)
    end,
    Count.

-spec count_accounts_query(Slot :: non_neg_integer(), AppType :: app_type()) -> ecredis:redis_command().
count_accounts_query(Slot, AppType) ->
    ["GET", count_accounts_key_slot(Slot, AppType)].


-spec count_version_keys() -> map().
count_version_keys() ->
    lists:foldl(
        fun (Slot, Acc) ->
            {ok, Res} = q(["HGETALL", version_key(Slot)]),
            AccountsMap = util:list_to_map(Res),
            util:add_and_merge_maps(Acc, AccountsMap)
        end,
        #{},
        lists:seq(0, ?NUM_VERSION_SLOTS - 1)).


-spec cleanup_version_keys(Versions :: [binary()]) -> ok.
cleanup_version_keys([]) ->
    ok;
cleanup_version_keys(Versions) ->
    CleanupCommands = lists:map(
        fun (Slot) ->
            ["HDEL", version_key(Slot) | Versions]
        end,
        lists:seq(0, ?NUM_VERSION_SLOTS - 1)),
    qmn(CleanupCommands),
    ok.


-spec count_os_version_keys(app_type()) -> map().
count_os_version_keys(AppType) ->
    lists:foldl(
        fun (Slot, Acc) ->
            {ok, Res} = q(["HGETALL", os_version_key(Slot, AppType)]),
            AccountsMap = util:list_to_map(Res),
            util:add_and_merge_maps(Acc, AccountsMap)
        end,
        #{},
        lists:seq(0, ?NUM_VERSION_SLOTS -1)).


-spec count_lang_keys(AppType :: app_type()) -> map().
count_lang_keys(AppType) ->
    lists:foldl(
        fun (Slot, Acc) ->
            {ok, Res} = q(["HGETALL", lang_key(Slot, AppType)]),
            LangIdMap = util:list_to_map(Res),
            util:add_and_merge_maps(Acc, LangIdMap)
        end,
        #{},
        lists:seq(0, ?NUM_SLOTS - 1)).



%%====================================================================
%% Tracing related API
%%====================================================================


-spec get_traced_uids() -> {ok, [binary()]}.
get_traced_uids() ->
    {ok, Uids} = q(["SMEMBERS", ?TRACED_UIDS_KEY]),
    {ok, Uids}.


-spec add_uid_to_trace(Uid :: uid()) -> ok.
add_uid_to_trace(Uid) ->
    {ok, _Res} = q(["SADD", ?TRACED_UIDS_KEY, Uid]),
    ok.


-spec remove_uid_from_trace(Uid :: uid()) -> ok.
remove_uid_from_trace(Uid) ->
    {ok, _Res} = q(["SREM", ?TRACED_UIDS_KEY, Uid]),
    ok.


-spec is_uid_traced(Uid :: uid()) -> boolean().
is_uid_traced(Uid) ->
    {ok, Res} = q(["SISMEMBER", ?TRACED_UIDS_KEY, Uid]),
    binary_to_integer(Res) == 1.


-spec get_traced_phones() -> {ok, [binary()]}.
get_traced_phones() ->
    {ok, Phones} = q(["SMEMBERS", ?TRACED_PHONES_KEY]),
    {ok, Phones}.


-spec add_phone_to_trace(Phone :: phone()) -> ok.
add_phone_to_trace(Phone) ->
    {ok, _Res} = q(["SADD", ?TRACED_PHONES_KEY, Phone]),
    ok.


-spec remove_phone_from_trace(Phone :: phone()) -> ok.
remove_phone_from_trace(Phone) ->
    {ok, _Res} = q(["SREM", ?TRACED_PHONES_KEY, Phone]),
    ok.


-spec is_phone_traced(Phone :: phone()) -> boolean().
is_phone_traced(Phone) ->
    {ok, Res} = q(["SISMEMBER", ?TRACED_PHONES_KEY, Phone]),
    binary_to_integer(Res) == 1.


%%====================================================================
%% PSA Tagged Uid Management API.
%%====================================================================


-spec add_uid_to_psa_tag(Uid :: uid(), PSATag :: binary()) -> ok.
add_uid_to_psa_tag(Uid, PSATag) ->
    {ok, _Res} = q(["SADD", psa_tagged_uids_key(util_redis:eredis_hash(Uid), PSATag), Uid]),
    ok.


-spec get_psa_tagged_uids(Slot :: integer(), PSATag :: binary()) -> {ok, [binary()]}.
get_psa_tagged_uids(Slot, PSATag) ->
    {ok, Uids} = q(["SMEMBERS", psa_tagged_uids_key(Slot, PSATag)]),
    {ok, Uids}.

-spec count_psa_tagged_uids(PSATag :: binary()) -> integer().
count_psa_tagged_uids(PSATag) ->
    lists:foldl(
        fun (Slot, Acc) ->
            {ok, Res} = q(["SCARD", psa_tagged_uids_key(Slot, PSATag)]),
            Acc + binary_to_integer(Res)
        end,
        0,
        lists:seq(0, ?NUM_SLOTS - 1)).


-spec cleanup_psa_tagged_uids(PSATag :: binary()) -> ok.
cleanup_psa_tagged_uids(PSATag) ->
    DeleteCommands = lists:map(
        fun (Slot) ->
            ["DEL", psa_tagged_uids_key(Slot, PSATag)]
        end,
        lists:seq(0, ?NUM_SLOTS - 1)),
    qmn(DeleteCommands),    
    ok.

mark_psa_post_sent(Uid, PostId) ->
    [{ok, NotExists}, {ok, _}] = qp([
        ["HSETNX", psa_tagged_post_key(Uid, PostId), ?FIELD_PSA_POST_STATUS, 1],
        ["EXPIRE", psa_tagged_post_key(Uid, PostId), ?POST_EXPIRATION]
    ]),
    NotExists =:= <<"1">>.

mark_moment_notification_sent(Uid, Tag) ->
    [{ok, NotExists}, {ok, _}] = qp([
        ["HSETNX", moment_sent_notification_key(Uid, Tag), ?FIELD_MOMENT_NOFITICATION_STATUS, 1],
        ["EXPIRE", moment_sent_notification_key(Uid, Tag), ?MOMENT_TAG_EXPIRATION]
    ]),
    NotExists =:= <<"1">>.


delete_moment_notification_sent(Uid, Tag) ->
    {ok, _} = q(["DEL", moment_sent_notification_key(Uid, Tag)]),
    ok.

%%====================================================================
%% Inactive Uid deletion API.
%%====================================================================


-spec add_uid_to_delete(Uid :: uid()) -> ok.
add_uid_to_delete(Uid) ->
    {ok, _Res} = q(["SADD", uids_to_delete_key(util_redis:eredis_hash(Uid)), Uid]),
    ok.


-spec get_uids_to_delete(Slot :: integer()) -> {ok, [binary()]}.
get_uids_to_delete(Slot) ->
    {ok, Uids} = q(["SMEMBERS", uids_to_delete_key(Slot)]),
    {ok, Uids}.

-spec count_uids_to_delete() -> integer().
count_uids_to_delete() ->
    lists:foldl(
        fun (Slot, Acc) ->
            {ok, Res} = q(["SCARD", uids_to_delete_key(Slot)]),
            Acc + binary_to_integer(Res)
        end,
        0,
        lists:seq(0, ?NUM_SLOTS - 1)).


-spec cleanup_uids_to_delete_keys() -> ok.
cleanup_uids_to_delete_keys() ->
    DeleteCommands = lists:map(
        fun (Slot) ->
            ["DEL", uids_to_delete_key(Slot)]
        end,
        lists:seq(0, ?NUM_SLOTS - 1)),
    qmn(DeleteCommands),    
    ok.


-spec mark_inactive_uids_gen_start() -> boolean().
mark_inactive_uids_gen_start() ->
    mark_inactive_uids(?INACTIVE_UIDS_GEN_KEY).


-spec mark_inactive_uids_deletion_start() -> boolean().
mark_inactive_uids_deletion_start() ->
    mark_inactive_uids(?INACTIVE_UIDS_DELETION_KEY).


-spec mark_inactive_uids_check_start() -> boolean().
mark_inactive_uids_check_start() ->
    mark_inactive_uids(?INACTIVE_UIDS_CHECK_KEY).


mark_inactive_uids(Key) ->
    [{ok, Exists}, {ok, _}] = qp([
        ["HSETNX", inactive_uids_mark_key(Key), ?FIELD_INACTIVE_UIDS_STATUS, 1],
        ["EXPIRE", inactive_uids_mark_key(Key), ?INACTIVE_UIDS_VALIDITY]
    ]),
    Exists =:= <<"1">>.

-spec get_export(Uid :: uid()) ->
    {ok, StartTs :: integer(), ExportId :: binary(), TTL :: integer()} | {error, missing}.
get_export(Uid) ->
    {ok, [StartTsBin, ExportId]} = q(["HMGET", export_data_key(Uid),
        ?FIELD_EXPORT_START_TS, ?FIELD_EXPORT_ID]),
    case StartTsBin of
        undefined -> {error, missing};
        _ ->
            {ok, TTLBin} = q(["TTL", export_data_key(Uid)]),
            TTL = case binary_to_integer(TTLBin) of
                -2 ->
                    ?ERROR("Export Key ~s is missing?", [export_data_key(Uid)]),
                    ?EXPORT_TTL;
                -1 ->
                    ?ERROR("Export Key ~s doesn't have TTL", [export_data_key(Uid)]),
                    ?EXPORT_TTL;
                X -> X
            end,
            {ok, util_redis:decode_ts(StartTsBin), ExportId, TTL}
    end.

-spec start_export(Uid :: uid(), ExportId :: binary()) -> {ok, Ts :: integer()} | {error, already_started}.
start_export(Uid, ExportId) ->
    Ts = util:now(),
    {ok, TTL} = q(["TTL", export_data_key(Uid)]),
    case binary_to_integer(TTL) < 0 of
        true ->
            [{ok, _}, {ok, _}, {ok, _}] = qp([
                ["HSET", export_data_key(Uid), ?FIELD_EXPORT_START_TS, Ts],
                ["HSET", export_data_key(Uid), ?FIELD_EXPORT_ID, ExportId],
                ["EXPIRE", export_data_key(Uid), ?EXPORT_TTL]
            ]),
            {ok, Ts};
        false ->
            {error, already_started}
    end.

-spec test_set_export_time(Uid :: uid(), Ts :: integer()) -> ok.
test_set_export_time(Uid, Ts) ->
    {ok, _} = q(["HSET", export_data_key(Uid), ?FIELD_EXPORT_START_TS, Ts]),
    ok.

-spec get_geotag_uids(GeoTag :: atom()) -> list().
get_geotag_uids(GeoTag) ->
    lists:foldl(
        fun (Slot, Acc) ->
            ExpiredTs = util:now() - ?GEO_TAG_EXPIRATION,
            Key = geotag_index_key(Slot, GeoTag),
            case q(["ZRANGE", Key, "+inf", util:to_list(ExpiredTs), "BYSCORE", "REV"]) of
                {ok, TaggedUids} ->
                    Acc ++ TaggedUids;
                Err ->
                    ?ERROR("Failed to get all uids for ~p: ~p, Error: ~p", [GeoTag, Slot, Err]),
                    Acc
            end
        end,
        [],
        lists:seq(0, ?NUM_SLOTS - 1)).


-spec update_geo_tag_index(Uid :: binary(), GeoTag :: atom()) -> ok.
update_geo_tag_index(Uid, GeoTag) ->
    HashSlot = util_redis:eredis_hash(binary_to_list(Uid)),
    UidSlot = HashSlot rem ?NUM_SLOTS,
    Timestamp = util:now(),
    [{ok, _}] = qp([["ZADD", geotag_index_key(UidSlot, GeoTag), Timestamp, Uid]]),
    ok.


-spec add_geo_tag(Uid :: uid(), Tag :: atom(), Timestamp :: integer()) -> ok.
add_geo_tag(Uid, Tag, Timestamp) ->
    ExpiredTs = util:now() - ?GEO_TAG_EXPIRATION,
    Key = geo_tag_key(Uid),
    qp([["ZADD", Key, Timestamp, Tag],
        ["ZREMRANGEBYSCORE", Key, "-inf", ExpiredTs]]),
    update_geo_tag_index(Uid, Tag),
    ok.

-spec get_latest_geo_tag(Uid :: uid()) -> maybe(atom()).
get_latest_geo_tag(Uid) ->
    Key = geo_tag_key(Uid),
    case q(["ZREVRANGE", Key, "0", "0", "WITHSCORES"]) of
        {ok, []} -> undefined;
        {ok, [NewestGeoTag, Timestamp]} ->
            ExpiredTs = util:now() - ?GEO_TAG_EXPIRATION,
            case Timestamp > ExpiredTs of
                true -> util:to_atom(NewestGeoTag);
                false -> undefined
            end;
        Err ->
            ?ERROR("Failed to get geo tag for ~s: ~p", [Uid, Err]),
            undefined
    end.

-spec get_all_geo_tags(Uid :: uid()) -> list({binary(), binary()}).
get_all_geo_tags(Uid) ->
    Key = geo_tag_key(Uid),
    ExpiredTs = util:now() - ?GEO_TAG_EXPIRATION,
    case q(["ZREVRANGEBYSCORE", Key, "+inf", util:to_list(ExpiredTs), "WITHSCORES"]) of
        {ok, GeoTags} ->
            util_redis:parse_zrange_with_scores(GeoTags);
        Err ->
            ?ERROR("Failed to get all geo tags for ~s: ~p", [Uid, Err]),
            undefined
    end.

-spec add_rejected_suggestions(Uid :: uid(), Ouids :: [uid()]) -> ok.
add_rejected_suggestions(Uid, Ouids) ->
    Now = util:now(),
    ExpiredTs = Now - ?REJECTED_SUGGESTION_EXPIRATION,
    Key = rejected_suggestion_key(Uid),
    Commands = lists:map(fun(Ouid) -> ["ZADD", Key, Now, Ouid] end, Ouids),
    qp(Commands ++ [["EXPIRE", Key, ?REJECTED_SUGGESTION_EXPIRATION],
        ["ZREMRANGEBYSCORE", Key, "-inf", ExpiredTs]]),
    ok.

-spec get_all_rejected_suggestions(Uid :: uid()) -> {ok, maybe([uid()])} | {error, any()}.
get_all_rejected_suggestions(Uid) ->
    Key = rejected_suggestion_key(Uid),
    ExpiredTs = util:now() - ?REJECTED_SUGGESTION_EXPIRATION,
    q(["ZREVRANGEBYSCORE", Key, "+inf", util:to_list(ExpiredTs)]).

-spec add_marketing_tag(Uid :: uid(), Tag :: binary()) -> ok.
add_marketing_tag(Uid, Tag) ->
    Timestamp = util:now(),
    OldTs = Timestamp - ?MARKETING_TAG_TTL,
    ListKey = marketing_tag_key(Uid),
    _Results = qp([["MULTI"],
                    ["ZADD", ListKey, Timestamp, Tag],
                    ["EXPIRE", ListKey, ?MARKETING_TAG_TTL],
                    ["ZREMRANGEBYSCORE", ListKey, "-inf", OldTs],
                    ["EXEC"]]),  
    ok.

-spec get_marketing_tags(Uid :: uid()) -> {ok, [{binary(), non_neg_integer()}]}.
get_marketing_tags(Uid) ->
    OldTs = util:now() - ?MARKETING_TAG_TTL,
    ListKey = marketing_tag_key(Uid),
    {ok, Res} = q(["ZREVRANGEBYSCORE", ListKey, "+inf", integer_to_binary(OldTs), "WITHSCORES"]),
    {ok, util_redis:parse_zrange_with_scores(Res)}.


-spec scan(Node :: node(), Cursor :: non_neg_integer(), Count :: pos_integer()) -> {non_neg_integer(), [uid()]} | {error, any()}.
scan(Node, Cursor, Count) ->
    {ok, Res} = qn(["SCAN", Cursor, "MATCH", <<?ACCOUNT_KEY/binary, <<"*">>/binary>>, "COUNT", Count], Node),
    case Res of 
        [NewCur, Keys] -> {binary_to_integer(NewCur), Keys};
        _ -> Res
    end.


-spec get_user_activity_info(Usernames :: [binary()]) -> #{Username :: binary() =>
    {Uid :: uid(), NumFollowers :: non_neg_integer(), NumPosts :: non_neg_integer(), Geotag :: maybe(binary()), Active :: boolean()}}.
get_user_activity_info(Username) when not is_list(Username) ->
    get_user_activity_info([Username]);
get_user_activity_info(Usernames) ->
    UsernameToUidMap = get_username_uids(Usernames),
    InfoMap = maps:map(
        fun(_Username, Uid) ->
            NumFollowers = model_follow:get_followers_count(Uid),
            NumPosts = model_feed:get_num_posts(Uid),
            Geotag = get_latest_geo_tag(Uid),
            IsActive = NumFollowers >= ?ACTIVE_USER_MIN_FOLLOWERS
                andalso NumPosts >= ?ACTIVE_USER_MIN_POSTS
                andalso Geotag =/= undefined,
            {Uid, NumFollowers, NumPosts, Geotag, IsActive}
        end,
        UsernameToUidMap),
    %% For usernames not associated with an account, inject into map as inactive
    lists:foldl(
        fun(BadUsername, AccMap) ->
            maps:put(BadUsername, {undefined, 0, 0, undefined, false}, AccMap)
        end,
        InfoMap,
        Usernames -- maps:keys(InfoMap)).

%%====================================================================
%% Internal redis functions.
%%====================================================================


q(Command) -> ecredis:q(ecredis_accounts, Command).
qp(Commands) -> ecredis:qp(ecredis_accounts, Commands).
qn(Command, Node) -> ecredis:qn(ecredis_accounts, Node, Command).
qmn(Commands) -> util_redis:run_qmn(ecredis_accounts, Commands).
get_node_list() -> ecredis:get_nodes(ecredis_accounts).

ts_reply(Res) ->
    case util_redis:decode_ts(Res) of
        undefined -> {error, missing};
        Ts -> {ok, Ts}
    end.


boolean_decode(Data, DefaultValue) ->
    case Data of
        <<"1">> -> true;
        <<"0">> -> false;
        _ -> DefaultValue
    end.

boolean_encode(BoolValue) ->
    case BoolValue of
        true -> <<"1">>;
        false -> <<"0">>
    end.


-spec account_key(binary()) -> binary().
account_key(Uid) ->
    <<?ACCOUNT_KEY/binary, <<"{">>/binary, Uid/binary, <<"}">>/binary>>.

-spec deleted_account_key(binary()) -> binary().
deleted_account_key(Uid) ->
    <<?DELETED_ACCOUNT_KEY/binary, <<"{">>/binary, Uid/binary, <<"}">>/binary>>.

%% DeletedUidKey to keep track of all deleted uids used so far.
-spec deleted_uid_key(binary()) -> binary().
deleted_uid_key(Uid) ->
    <<?DELETED_UID_KEY/binary, <<"{">>/binary, Uid/binary, <<"}">>/binary>>.

subscribe_key(Uid) ->
    <<?SUBSCRIBE_KEY/binary, <<"{">>/binary, Uid/binary, <<"}">>/binary>>.

broadcast_key(Uid) ->
    <<?BROADCAST_KEY/binary, <<"{">>/binary, Uid/binary, <<"}">>/binary>>.

version_key(Slot) ->
    SlotBinary = integer_to_binary(Slot),
    <<?VERSION_KEY/binary, <<"{">>/binary, SlotBinary/binary, <<"}">>/binary>>.

geotag_index_key(Slot, GeoTag) ->
    SlotBinary = integer_to_binary(Slot),
    GeoTagBin = util:to_binary(GeoTag),
    <<?GEO_TAG_INDEX_KEY/binary, <<"{">>/binary, SlotBinary/binary, <<"}:">>/binary, GeoTagBin/binary>>.

os_version_key(Slot, AppType) ->
    SlotBinary = integer_to_binary(Slot),
    case AppType of
        ?KATCHUP -> <<?KATCHUP_OS_VERSION_KEY/binary, <<"{">>/binary, SlotBinary/binary, <<"}">>/binary>>;
        _ -> <<?OS_VERSION_KEY/binary, <<"{">>/binary, SlotBinary/binary, <<"}">>/binary>>
    end.

lang_key(Slot, AppType) ->
    SlotBinary = integer_to_binary(Slot),
    case AppType of
        ?KATCHUP -> <<?KATCHUP_LANG_KEY/binary, <<"{">>/binary, SlotBinary/binary, <<"}">>/binary>>;
        _ -> <<?LANG_KEY/binary, <<"{">>/binary, SlotBinary/binary, <<"}">>/binary>>
    end.

inactive_uids_mark_key(Key) ->
    <<?TO_DELETE_UIDS_KEY/binary, <<":">>/binary, Key/binary>>.

uids_to_delete_key(Slot) ->
    SlotBinary = integer_to_binary(Slot),
    <<?TO_DELETE_UIDS_KEY/binary, <<"{">>/binary, SlotBinary/binary, <<"}">>/binary>>.

psa_tagged_uids_key(Slot, PSATag) ->
    SlotBinary = integer_to_binary(Slot),
    <<?PSA_TAG_UIDS_KEY/binary, <<"{">>/binary, SlotBinary/binary, <<"}:">>/binary, PSATag/binary>>.

psa_tagged_post_key(Uid, PostId) ->
    <<?PSA_TAG_POST_KEY/binary, <<"{">>/binary, Uid/binary, <<"}:">>/binary, PostId/binary>>.

moment_sent_notification_key(Uid, Tag) ->
    <<?MOMENT_SENT_NOTIFICATION_KEY/binary, <<"{">>/binary, Uid/binary, <<"}:">>/binary, Tag/binary>>.

count_registrations_key(Uid) ->
    Slot = crc16_redis:hash(binary_to_list(Uid)),
    count_registrations_slot_key(Slot, util_uid:get_app_type(Uid)).

count_registrations_slot_key(Slot, ?KATCHUP) ->
    redis_counts:count_key(Slot, ?COUNT_KATCHUP_REGISTRATIONS_KEY);
count_registrations_slot_key(Slot, _) ->
    redis_counts:count_key(Slot, ?COUNT_HALLOAPP_REGISTRATIONS_KEY).

count_accounts_key(Uid) ->
    Slot = crc16_redis:hash(binary_to_list(Uid)),
    count_accounts_key_slot(Slot, util_uid:get_app_type(Uid)).

count_accounts_key_slot(Slot, ?KATCHUP) ->
    redis_counts:count_key(Slot, ?COUNT_KATCHUP_ACCOUNTS_KEY);
count_accounts_key_slot(Slot, _) ->
    redis_counts:count_key(Slot, ?COUNT_HALLOAPP_ACCOUNTS_KEY).

export_data_key(Uid) ->
    <<?EXPORT_DATA_KEY/binary, "{", Uid/binary, "}">>.

marketing_tag_key(Uid) ->
    <<?MARKETING_TAG_KEY/binary, "{", Uid/binary, "}">>.

geo_tag_key(Uid) ->
    <<?GEO_TAG_KEY/binary, "{", Uid/binary, "}">>.


rejected_suggestion_key(Uid) ->
    <<?REJECTED_SUGGESTIONS_KEY/binary, "{", Uid/binary, "}">>.


zone_offset_tag_key(Slot, ZoneOffsetTag) ->
    SlotBin = util:to_binary(Slot),
    <<?ZONE_OFFSET_TAG_KEY/binary, "{", SlotBin/binary, "}:", ZoneOffsetTag/binary>>.

username_index_key(UsernamePrefix) ->
    <<?USERNAME_INDEX_KEY/binary, "{", UsernamePrefix/binary, "}">>.

username_uid_key(Username) ->
    <<?USERNAME_KEY/binary, "{", Username/binary, "}">>.

