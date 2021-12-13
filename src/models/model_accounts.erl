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

-define(DELETED_ACCOUNT_TTL, 2 * ?WEEKS).

%% Validity period for transient keys created during inactive accounts deletion.
-define(INACTIVE_UIDS_VALIDITY, 12 * ?HOURS).

-define(EXPORT_TTL, 10 * ?DAYS).

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
    lang_key/1,
    uids_to_delete_key/1
]).


%% API
-export([
    create_account/4,
    create_account/5, % CommonTest
    delete_account/1,
    account_exists/1,
    filter_nonexisting_uids/1,
    is_account_deleted/1,
    get_account/1,
    get_phone/1,
    get_phones/1,
    set_name/2,
    get_name/1,
    get_name_binary/1,
    get_names/1,
    get_avatar_ids/1,
    get_creation_ts_ms/1,
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
    set_last_ipaddress/2,
    get_last_ipaddress/1,
    set_user_agent/2,
    get_signup_user_agent/1,
    set_client_version/2,
    get_client_version/1,
    set_device_info/3,
    get_push_info/1,
    set_push_token/5,
    get_push_token/1,
    set_voip_token/4,
    get_lang_id/1,
    remove_push_token/1,
    remove_push_info/1,
    set_push_post_pref/2,
    get_push_post_pref/1,
    remove_push_post_pref/1,
    set_push_comment_pref/2,
    get_push_comment_pref/1,
    remove_push_comment_pref/1,
    presence_subscribe/2,
    presence_unsubscribe/2,
    presence_unsubscribe_all/1,
    get_subscribed_uids/1,
    get_broadcast_uids/1,
    count_registrations/0,
    count_registrations/1,
    count_registration_query/1,
    count_accounts_query/1,
    count_accounts/0,
    count_accounts/1,
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
    count_lang_keys/0,
    add_uid_to_delete/1,
    get_uids_to_delete/1,
    count_uids_to_delete/0,
    cleanup_uids_to_delete_keys/0,
    mark_inactive_uids_gen_start/0,
    mark_inactive_uids_deletion_start/0,
    mark_inactive_uids_check_start/0,
    get_export/1,
    start_export/2,
    test_set_export_time/2 % For tests only
]).

%%====================================================================
%% API
%%====================================================================


-define(FIELD_PHONE, <<"ph">>).
-define(FIELD_NAME, <<"na">>).
-define(FIELD_AVATAR_ID, <<"av">>).
-define(FIELD_CREATION_TIME, <<"ct">>).
-define(FIELD_DELETION_TIME, <<"dt">>).
-define(FIELD_SYNC_STATUS, <<"fsy">>).
-define(FIELD_NON_EMPTY_SYNC_STATUS, <<"sy">>).
-define(FIELD_NUM_INV, <<"in">>).  % from model_invites, but is part of the account structure
-define(FIELD_SINV_TS, <<"it">>).  % from model_invites, but is part of the account structure
-define(FIELD_LAST_IPADDRESS, <<"lip">>).
-define(FIELD_LAST_ACTIVITY, <<"la">>).
-define(FIELD_ACTIVITY_STATUS, <<"st">>).
-define(FIELD_USER_AGENT, <<"ua">>).
-define(FIELD_CLIENT_VERSION, <<"cv">>).
-define(FIELD_PUSH_OS, <<"pos">>).
-define(FIELD_PUSH_TOKEN, <<"ptk">>).
-define(FIELD_PUSH_TIMESTAMP, <<"pts">>).
-define(FIELD_PUSH_POST, <<"pp">>).
-define(FIELD_PUSH_COMMENT, <<"pc">>).
-define(FIELD_PUSH_LANGUAGE_ID, <<"pl">>).
-define(FIELD_VOIP_TOKEN, <<"pvt">>).
-define(FIELD_DEVICE, <<"dvc">>).
-define(FIELD_OS_VERSION, <<"osv">>).

%% Field to capture creation of list with inactive uids and their deletion.
-define(FIELD_INACTIVE_UIDS_STATUS, <<"ius">>).

%% Export Field
-define(FIELD_EXPORT_START_TS, <<"est">>).
-define(FIELD_EXPORT_ID, <<"eur">>).


%%====================================================================
%% Account related API
%%====================================================================

-spec create_account(Uid :: uid(), Phone :: phone(), Name :: binary(),
        UserAgent :: binary()) -> ok | {error, exists}.
create_account(Uid, Phone, Name, UserAgent) ->
    create_account(Uid, Phone, Name, UserAgent, util:now_ms()).


-spec create_account(Uid :: uid(), Phone :: phone(), Name :: binary(),
        UserAgent :: binary(), CreationTsMs :: integer()) -> ok | {error, exists | deleted}.
create_account(Uid, Phone, Name, UserAgent, CreationTsMs) ->
    {ok, Deleted} = q(["EXISTS", deleted_account_key(Uid)]),
    case binary_to_integer(Deleted) == 1 of
        true -> {error, deleted};
        false ->
            {ok, Exists} = q(["HSETNX", account_key(Uid), ?FIELD_PHONE, Phone]),
            case binary_to_integer(Exists) > 0 of
                true ->
                    Res = qp([
                        ["HSET", account_key(Uid),
                            ?FIELD_NAME, Name,
                            ?FIELD_USER_AGENT, UserAgent,
                            ?FIELD_CREATION_TIME, integer_to_binary(CreationTsMs)],
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
            ?FIELD_CREATION_TIME, ?FIELD_LAST_ACTIVITY, ?FIELD_ACTIVITY_STATUS,
            ?FIELD_USER_AGENT, ?FIELD_CLIENT_VERSION, ?FIELD_PUSH_LANGUAGE_ID,
            ?FIELD_DEVICE, ?FIELD_OS_VERSION]) of
        {ok, [undefined | _]} ->
            ?WARNING("Looks like it is already deleted, Uid: ~p", [Uid]),
            ok;
        {ok, [_Phone, CreationTsMsBin, LastActivityTsMs, ActivityStatus,
                UserAgent, ClientVersion, LangId, Device, OsVersion]} ->
            [{ok, _}, RenameResult, {ok, _}, DecrResult] = qp([
                ["HSET", deleted_uid_key(Uid),
                            ?FIELD_CREATION_TIME, CreationTsMsBin,
                            ?FIELD_LAST_ACTIVITY, LastActivityTsMs,
                            ?FIELD_ACTIVITY_STATUS, ActivityStatus,
                            ?FIELD_USER_AGENT, UserAgent,
                            ?FIELD_CLIENT_VERSION, ClientVersion,
                            ?FIELD_DELETION_TIME, integer_to_binary(DeletionTsMs),
                            ?FIELD_DEVICE, Device,
                            ?FIELD_OS_VERSION, OsVersion],
                ["RENAME", account_key(Uid), deleted_account_key(Uid)],
                ["EXPIRE", deleted_account_key(Uid), ?DELETED_ACCOUNT_TTL],
                ["DECR", count_accounts_key(Uid)]
            ]),
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
    case LangId =/= undefined of
        true ->
            %% Decrement lang counter
            LangSlot = HashSlot rem ?NUM_SLOTS,
            {ok, _} = q(["HINCRBY", lang_key(LangSlot), LangId, -1]);
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


-spec get_signup_user_agent(Uid :: uid()) -> {ok, binary()} | {error, missing}.
get_signup_user_agent(Uid) ->
    {ok, Res} = q(["HGET", account_key(Uid), ?FIELD_USER_AGENT]),
    case Res of
        undefined -> {error, missing};
        Res -> {ok, Res}
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


-spec get_client_version(Uid :: uid()) -> {ok, binary()} | {error, missing}.
get_client_version(Uid) ->
    {ok, Res} = q(["HGET", account_key(Uid), ?FIELD_CLIENT_VERSION]),
    case Res of
        undefined -> {error, missing};
        Res -> {ok, Res}
    end.


-spec set_device_info(Uid :: uid(), Device :: maybe(binary()), OsVersion :: maybe(binary())) -> ok.
set_device_info(_Uid, undefined, undefined) ->
    %% TODO: murali@: temporary until clients send us this - check-in on 12-20-2021.
    ok;
set_device_info(Uid, Device, OsVersion) ->
    {ok, _} = q(["HMSET", account_key(Uid), ?FIELD_DEVICE, Device, ?FIELD_OS_VERSION, OsVersion]),
    ok.


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
                    name = maps:get(?FIELD_NAME, M),
                    signup_user_agent = maps:get(?FIELD_USER_AGENT, M),
                    creation_ts_ms = util_redis:decode_ts(maps:get(?FIELD_CREATION_TIME, M)),
                    last_activity_ts_ms = util_redis:decode_ts(maps:get(?FIELD_LAST_ACTIVITY, M, undefined)),
                    activity_status = util:to_atom(maps:get(?FIELD_ACTIVITY_STATUS, M, undefined)),
                    client_version = maps:get(?FIELD_CLIENT_VERSION, M, undefined),
                    lang_id = maps:get(?FIELD_PUSH_LANGUAGE_ID, M, undefined),
                    device = maps:get(?FIELD_DEVICE, M, undefined),
                    os_version = maps:get(?FIELD_OS_VERSION, M, undefined),
                    last_ipaddress = util:to_list(maps:get(?FIELD_LAST_IPADDRESS, M, undefined))
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


%% We will first run a migration to set values appropriately for lang_id keys on all slots.
%% Then set the value for lang_id key in persistent_term storage.
%% In the next diff - we can cleanup this code.
-spec set_push_token(Uid :: uid(), TokenType :: binary(), PushToken :: binary(),
        TimestampMs :: integer(), LangId :: binary()) -> ok.
set_push_token(Uid, TokenType, PushToken, TimestampMs, LangId) ->
    {ok, OldLangId} = get_lang_id(Uid),
    {ok, _Res} = q([
            "HMSET", account_key(Uid),
            ?FIELD_PUSH_OS, TokenType,
            ?FIELD_PUSH_TOKEN, PushToken,
            ?FIELD_PUSH_TIMESTAMP, integer_to_binary(TimestampMs),
            ?FIELD_PUSH_LANGUAGE_ID, LangId
        ]),
    update_lang_counters(Uid, LangId, OldLangId),
    ok.


-spec set_voip_token(Uid :: binary(), VoipToken :: binary(),
    TimestampMs :: integer(), LangId :: binary()) -> ok.
set_voip_token(Uid, VoipToken, TimestampMs, LangId) ->
    {ok, OldLangId} = get_lang_id(Uid),
    {ok, _Res} = q([
            "HMSET", account_key(Uid),
            ?FIELD_VOIP_TOKEN, VoipToken,
            ?FIELD_PUSH_TIMESTAMP, integer_to_binary(TimestampMs),
            ?FIELD_PUSH_LANGUAGE_ID, LangId
        ]),
    update_lang_counters(Uid, LangId, OldLangId),
    ok.


-spec update_lang_counters(Uid :: binary(), LangId :: binary(), OldLangId :: binary()) -> ok.
update_lang_counters(Uid, LangId, OldLangId) ->
    HashSlot = util_redis:eredis_hash(binary_to_list(Uid)),
    LangSlot = HashSlot rem ?NUM_SLOTS,
    case OldLangId of
        undefined ->
            [{ok, _}] = qp([["HINCRBY", lang_key(LangSlot), LangId, 1]]),
            ok;
        LangId -> ok;
        OldLangId ->
            [{ok, _}, {ok, _}] = qp([
                    ["HINCRBY", lang_key(LangSlot), LangId, 1],
                    ["HINCRBY", lang_key(LangSlot), OldLangId, -1]
                ]),
            ok
    end,
    ok.


-spec get_push_token(Uid :: uid()) -> {ok, maybe(push_info())} | {error, missing}.
get_push_token(Uid) ->
    {ok, [Os, Token, TimestampMs, LangId, VoipToken]} = q(
            ["HMGET", account_key(Uid), ?FIELD_PUSH_OS, ?FIELD_PUSH_TOKEN,
                    ?FIELD_PUSH_TIMESTAMP, ?FIELD_PUSH_LANGUAGE_ID, ?FIELD_VOIP_TOKEN]),
    Res = case Token =:= undefined andalso VoipToken =:= undefined of
        true -> undefined;
        false ->
            #push_info{
                uid = Uid, 
                os = Os, 
                token = Token, 
                voip_token = VoipToken,
                timestamp_ms = util_redis:decode_ts(TimestampMs),
                lang_id = LangId
            }
    end,
    {ok, Res}.


-spec remove_push_token(Uid :: uid()) -> ok | {error, missing}.
remove_push_token(Uid) ->
    {ok, _Res} = q(["HDEL", account_key(Uid),
        ?FIELD_PUSH_OS, ?FIELD_PUSH_TOKEN, ?FIELD_PUSH_TIMESTAMP, ?FIELD_VOIP_TOKEN]),
    ok.


-spec get_push_info(Uid :: uid()) -> {ok, maybe(push_info())} | {error, missing}.
get_push_info(Uid) ->
    {ok, [Os, Token, TimestampMs, PushPost, PushComment, ClientVersion, LangId, VoipToken]} = q(
            ["HMGET", account_key(Uid), ?FIELD_PUSH_OS, ?FIELD_PUSH_TOKEN, ?FIELD_PUSH_TIMESTAMP,
            ?FIELD_PUSH_POST, ?FIELD_PUSH_COMMENT, ?FIELD_CLIENT_VERSION, ?FIELD_PUSH_LANGUAGE_ID,
            ?FIELD_VOIP_TOKEN]),
    Res = #push_info{
            uid = Uid,
            os = Os,
            token = Token,
            voip_token = VoipToken,
            timestamp_ms = util_redis:decode_ts(TimestampMs),
            post_pref = boolean_decode(PushPost, true),
            comment_pref = boolean_decode(PushComment, true),
            client_version = ClientVersion,
            lang_id = LangId
        },
    {ok, Res}.


-spec remove_push_info(Uid :: uid()) -> ok | {error, missing}.
remove_push_info(Uid) ->
    {ok, _Res} = q(["HDEL", account_key(Uid), ?FIELD_PUSH_OS, ?FIELD_PUSH_TOKEN,
        ?FIELD_PUSH_TIMESTAMP, ?FIELD_PUSH_LANGUAGE_ID, ?FIELD_VOIP_TOKEN]),
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


-spec account_exists(Uid :: uid()) -> boolean().
account_exists(Uid) ->
    {ok, Res} = q(["HEXISTS", account_key(Uid), ?FIELD_PHONE]),
    binary_to_integer(Res) > 0.


-spec filter_nonexisting_uids(Uids :: [uid()]) -> [uid()].
filter_nonexisting_uids(Uids) ->
    lists:foldr(
        fun (Uid, Acc) ->
            case model_accounts:account_exists(Uid) of
                true -> [Uid | Acc];
                false -> Acc
            end
        end,
        [],
        Uids).


-spec is_account_deleted(Uid :: uid()) -> boolean().
is_account_deleted(Uid) ->
    {ok, Res} = q(["EXISTS", deleted_uid_key(Uid)]),
    binary_to_integer(Res) > 0.


%%====================================================================
%% Store Last IP address
%%====================================================================


-spec set_last_ipaddress(Uid :: uid(), IPAddress :: list()) -> ok.
set_last_ipaddress(Uid, IPAddress) ->
    {ok, _Res1} = q(["HSET", account_key(Uid), ?FIELD_LAST_IPADDRESS, util:to_binary(IPAddress)]),
    ok.


-spec get_last_ipaddress(Uid :: uid()) -> maybe(binary()).
get_last_ipaddress(Uid) ->
    {ok, IPAddress} = q(["HGET", account_key(Uid), ?FIELD_LAST_IPADDRESS]),
    util_redis:decode_binary(IPAddress).


%%====================================================================
%% Presence related API
%%====================================================================


-spec set_last_activity(Uid :: uid(), TimestampMs :: integer(),
        ActivityStatus :: activity_status()) -> ok.
set_last_activity(Uid, TimestampMs, ActivityStatus) ->
    {ok, _Res1} = q(
            ["HMSET", account_key(Uid),
            ?FIELD_LAST_ACTIVITY, integer_to_binary(TimestampMs),
            ?FIELD_ACTIVITY_STATUS, util:to_binary(ActivityStatus)]),
    ok.


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


%%====================================================================
%% Counts related API
%%====================================================================


-spec count_registrations() -> non_neg_integer().
count_registrations() ->
    redis_counts:count_by_slot(ecredis_accounts, fun count_registration_query/1).


-spec count_registrations(Slot :: non_neg_integer()) -> non_neg_integer().
count_registrations(Slot) ->
    {ok, CountBin} = q(["GET", count_registrations_key_slot(Slot)]),
    Count = case CountBin of
                undefined -> 0;
                CountBin -> binary_to_integer(CountBin)
            end,
    Count.

-spec count_registration_query(Slot :: non_neg_integer()) -> non_neg_integer().
count_registration_query(Slot) ->
    ["GET", count_registrations_key_slot(Slot)].


-spec count_accounts() -> non_neg_integer().
count_accounts() ->
    redis_counts:count_by_slot(ecredis_accounts, fun count_accounts_query/1).


-spec count_accounts(Slot :: non_neg_integer()) -> non_neg_integer().
count_accounts(Slot) ->
    {ok, CountBin} = q(["GET", count_accounts_key_slot(Slot)]),
    Count = case CountBin of
                undefined -> 0;
                CountBin -> binary_to_integer(CountBin)
            end,
    Count.

-spec count_accounts_query(Slot :: non_neg_integer()) -> non_neg_integer().
count_accounts_query(Slot) ->
    ["GET", count_accounts_key_slot(Slot)].


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


-spec count_lang_keys() -> map().
count_lang_keys() ->
    lists:foldl(
        fun (Slot, Acc) ->
            {ok, Res} = q(["HGETALL", lang_key(Slot)]),
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


-spec mark_inactive_uids_gen_start() -> bool.
mark_inactive_uids_gen_start() ->
    mark_inactive_uids(?INACTIVE_UIDS_GEN_KEY).


-spec mark_inactive_uids_deletion_start() -> bool.
mark_inactive_uids_deletion_start() ->
    mark_inactive_uids(?INACTIVE_UIDS_DELETION_KEY).


-spec mark_inactive_uids_check_start() -> bool.
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

-spec start_export(Uid :: uid(), ExportId :: string()) -> {ok, Ts :: integer()} | {error, already_started}.
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


%%====================================================================
%% Internal redis functions.
%%====================================================================


q(Command) -> ecredis:q(ecredis_accounts, Command).
qp(Commands) -> ecredis:qp(ecredis_accounts, Commands).
%%qn(Command, Node) -> ecredis:qn(ecredis_accounts, Node, Command).
qmn(Commands) -> util_redis:run_qmn(ecredis_accounts, Commands).
%%get_node_list() -> ecredis:get_nodes(ecredis_accounts).

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

lang_key(Slot) ->
    SlotBinary = integer_to_binary(Slot),
    <<?LANG_KEY/binary, <<"{">>/binary, SlotBinary/binary, <<"}">>/binary>>.

inactive_uids_mark_key(Key) ->
    <<?TO_DELETE_UIDS_KEY/binary, <<":">>/binary, Key/binary>>.

uids_to_delete_key(Slot) ->
    SlotBinary = integer_to_binary(Slot),
    <<?TO_DELETE_UIDS_KEY/binary, <<"{">>/binary, SlotBinary/binary, <<"}">>/binary>>.

count_registrations_key(Uid) ->
    Slot = crc16_redis:hash(binary_to_list(Uid)),
    count_registrations_key_slot(Slot).

count_registrations_key_slot(Slot) ->
    redis_counts:count_key(Slot, ?COUNT_REGISTRATIONS_KEY).

count_accounts_key(Uid) ->
    Slot = crc16_redis:hash(binary_to_list(Uid)),
    count_accounts_key_slot(Slot).

count_accounts_key_slot(Slot) ->
    redis_counts:count_key(Slot, ?COUNT_ACCOUNTS_KEY).

export_data_key(Uid) ->
    <<?EXPORT_DATA_KEY/binary, "{", Uid/binary, "}">>.

