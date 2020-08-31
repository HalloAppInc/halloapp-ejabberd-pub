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
-behavior(gen_mod).

-include("logger.hrl").
-include("account.hrl").
-include("eredis_cluster.hrl").
-include("redis_keys.hrl").
-include("ha_types.hrl").

%% Export all functions for unit tests
-ifdef(TEST).
-compile(export_all).
-endif.

%% gen_mod callbacks
-export([start/2, stop/1, depends/2, mod_options/1]).

-export([key/1]).


%% API
-export([
    create_account/4,
    delete_account/1,
    account_exists/1,
    filter_nonexisting_uids/1,
    is_account_deleted/1,
    get_account/1,
    get_phone/1,
    set_name/2,
    get_name/1,
    get_name_binary/1,
    get_creation_ts_ms/1,
    delete_name/1,
    set_avatar_id/2,
    delete_avatar_id/1,
    get_avatar_id/1,
    get_avatar_id_binary/1,
    get_last_activity/1,
    set_last_activity/3,
    set_user_agent/2,
    get_signup_user_agent/1,
    get_push_info/1,
    set_push_token/4,
    get_push_token/1,
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
    count_accounts/1,
    count_accounts/0,
    fix_counters/0,
    get_traced_uids/0,
    add_uid_to_trace/1,
    remove_uid_from_trace/1,
    is_uid_traced/1,
    get_traced_phones/0,
    add_phone_to_trace/1,
    remove_phone_from_trace/1,
    is_phone_traced/1,
    get_names/1
]).

-export([
    get_all_pools/0,
    qs/2
]).

%%====================================================================
%% gen_mod callbacks
%%====================================================================

start(_Host, _Opts) ->
    ?INFO_MSG("start ~w", [?MODULE]),
    ok.

stop(_Host) ->
    ?INFO_MSG("stop ~w", [?MODULE]),
    ok.

depends(_Host, _Opts) ->
    [{mod_redis, hard}].

mod_options(_Host) ->
    [].

%%====================================================================
%% API
%%====================================================================


-define(FIELD_PHONE, <<"ph">>).
-define(FIELD_NAME, <<"na">>).
-define(FIELD_AVATAR_ID, <<"av">>).
-define(FIELD_CREATION_TIME, <<"ct">>).
-define(FIELD_NUM_INV, <<"in">>).  % from model_invites, but is part of the account structure
-define(FIELD_SINV_TS, <<"it">>).  % from model_invites, but is part of the account structure
-define(FIELD_LAST_ACTIVITY, <<"la">>).
-define(FIELD_ACTIVITY_STATUS, <<"st">>).
-define(FIELD_USER_AGENT, <<"ua">>).
-define(FIELD_PUSH_OS, <<"pos">>).
-define(FIELD_PUSH_TOKEN, <<"ptk">>).
-define(FIELD_PUSH_TIMESTAMP, <<"pts">>).
-define(FIELD_PUSH_POST, <<"pp">>).
-define(FIELD_PUSH_COMMENT, <<"pc">>).


%%====================================================================
%% Account related API
%%====================================================================

-spec create_account(Uid :: binary(), Phone :: binary(), Name :: binary(),
        UserAgent :: binary()) -> ok | {error, exists}.
create_account(Uid, Phone, Name, UserAgent) ->
    create_account(Uid, Phone, Name, UserAgent, util:now_ms()).


-spec create_account(Uid :: binary(), Phone :: binary(), Name :: binary(),
        UserAgent :: binary(), CreationTsMs :: integer()) -> ok | {error, exists | deleted}.
create_account(Uid, Phone, Name, UserAgent, CreationTsMs) ->
    {ok, Deleted} = q(["EXISTS", deleted_account_key(Uid)]),
    case binary_to_integer(Deleted) == 1 of
        true -> {error, deleted};
        false ->
            {ok, Exists} = q(["HSETNX", key(Uid), ?FIELD_PHONE, Phone]),
            case binary_to_integer(Exists) > 0 of
                true ->
                    Res = qp([
                        ["HSET", key(Uid),
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


-spec delete_account(Uid :: binary()) -> ok.
delete_account(Uid) ->
    case q(["HEXISTS", key(Uid), ?FIELD_PHONE]) of
        {ok, <<"1">>} ->
            [RenameResult, DecrResult] = qp([
                ["RENAME", key(Uid), deleted_account_key(Uid)],
                ["DECR", count_accounts_key(Uid)]
            ]),
            case RenameResult of
                {ok, <<"OK">>} ->
                    ?INFO_MSG("Uid: ~s deleted", [Uid]);
                {error, Error} ->
                    ?ERROR_MSG("Uid: ~s account delete failed ~p", [Uid, Error])
            end,
            {ok, _} = DecrResult;
        {ok, <<"0">>} ->
            ok
    end,
    ok.


-spec set_name(Uid :: binary(), Name :: binary()) -> ok  | {error, any()}.
set_name(Uid, Name) ->
    {ok, _Res} = q(["HSET", key(Uid), ?FIELD_NAME, Name]),
    ok.


-spec get_name(Uid :: binary()) -> binary() | {ok, binary() | undefined} | {error, any()}.
get_name(Uid) ->
    {ok, Res} = q(["HGET", key(Uid), ?FIELD_NAME]),
    {ok, Res}.


-spec delete_name(Uid :: binary()) -> ok  | {error, any()}.
delete_name(Uid) ->
    {ok, _Res} = q(["HDEL", key(Uid), ?FIELD_NAME]),
    ok.


-spec get_name_binary(Uid :: binary()) -> binary().
get_name_binary(Uid) ->
    {ok, Name} = get_name(Uid),
    case Name of
        undefined ->  <<>>;
        _ -> Name
    end.


-spec set_avatar_id(Uid :: binary(), AvatarId :: binary()) -> ok  | {error, any()}.
set_avatar_id(Uid, AvatarId) ->
    {ok, _Res} = q(["HSET", key(Uid), ?FIELD_AVATAR_ID, AvatarId]),
    ok.


-spec delete_avatar_id(Uid :: binary()) -> ok.
delete_avatar_id(Uid) ->
    {ok, _Res} = q(["HDEL", key(Uid), ?FIELD_AVATAR_ID]),
    ok.


-spec get_avatar_id(Uid :: binary()) -> binary() | {ok, binary() | undefined} | {error, any()}.
get_avatar_id(Uid) ->
    {ok, Res} = q(["HGET", key(Uid), ?FIELD_AVATAR_ID]),
    {ok, Res}.


-spec get_avatar_id_binary(Uid :: binary()) -> binary().
get_avatar_id_binary(Uid) ->
    {ok, AvatarId} = get_avatar_id(Uid),
    case AvatarId of
        undefined ->  <<>>;
        _ -> AvatarId
    end.


-spec get_phone(Uid :: binary()) -> {ok, binary()} | {error, missing}.
get_phone(Uid) ->
    {ok, Res} = q(["HGET", key(Uid), ?FIELD_PHONE]),
    case Res of
        undefined -> {error, missing};
        Res -> {ok, Res}
    end.


-spec get_creation_ts_ms(Uid :: binary()) -> {ok, integer()} | {error, missing}.
get_creation_ts_ms(Uid) ->
    {ok, Res} = q(["HGET", key(Uid), ?FIELD_CREATION_TIME]),
    ts_reply(Res).


-spec set_user_agent(Uid :: binary(), UserAgent :: binary()) -> ok.
set_user_agent(Uid, UserAgent) ->
    {ok, _Res} = q(["HSET", key(Uid), ?FIELD_USER_AGENT, UserAgent]),
    ok.


-spec get_signup_user_agent(Uid :: binary()) -> {ok, binary()} | {error, missing}.
get_signup_user_agent(Uid) ->
    {ok, Res} = q(["HGET", key(Uid), ?FIELD_USER_AGENT]),
    case Res of
        undefined -> {error, missing};
        Res -> {ok, Res}
    end.


-spec get_account(Uid :: binary()) -> {ok, account()} | {error, missing}.
get_account(Uid) ->
    {ok, Res} = q(["HGETALL", key(Uid)]),
    M = util:list_to_map(Res),
    Account = #account{
            uid = Uid,
            phone = maps:get(?FIELD_PHONE, M),
            name = maps:get(?FIELD_NAME, M),
            signup_user_agent = maps:get(?FIELD_USER_AGENT, M),
            creation_ts_ms = util_redis:decode_ts(maps:get(?FIELD_CREATION_TIME, M)),
            last_activity_ts_ms = util_redis:decode_ts(maps:get(?FIELD_LAST_ACTIVITY, M, undefined)),
            activity_status = util:to_atom(maps:get(?FIELD_ACTIVITY_STATUS, M, undefined))
        },
    {ok, Account}.


%%====================================================================
%% Push-tokens related API
%%====================================================================


-spec set_push_token(Uid :: binary(), Os :: binary(), PushToken :: binary(),
        TimestampMs :: integer()) -> ok.
set_push_token(Uid, Os, PushToken, TimestampMs) ->
    {ok, _Res} = q(
            ["HMSET", key(Uid),
            ?FIELD_PUSH_OS, Os,
            ?FIELD_PUSH_TOKEN, PushToken,
            ?FIELD_PUSH_TIMESTAMP, integer_to_binary(TimestampMs)]),
    ok.


-spec get_push_token(Uid :: binary()) -> {ok, undefined | push_info()} | {error, missing}.
get_push_token(Uid) ->
    {ok, [Os, Token, TimestampMs]} = q(
            ["HMGET", key(Uid), ?FIELD_PUSH_OS, ?FIELD_PUSH_TOKEN, ?FIELD_PUSH_TIMESTAMP]),
    Res = case Token of
        undefined ->
            undefined;
        _ -> 
            #push_info{
                uid = Uid, 
                os = Os, 
                token = Token, 
                timestamp_ms = util_redis:decode_ts(TimestampMs)
            }
    end,
    {ok, Res}.


-spec remove_push_token(Uid :: binary()) -> ok | {error, missing}.
remove_push_token(Uid) ->
    {ok, _Res} = q(["HDEL", key(Uid), ?FIELD_PUSH_OS, ?FIELD_PUSH_TOKEN, ?FIELD_PUSH_TIMESTAMP]),
    ok.


-spec get_push_info(Uid :: binary()) -> {ok, undefined | push_info()} | {error, missing}.
get_push_info(Uid) ->
    {ok, [Os, Token, TimestampMs, PushPost, PushComment]} = q(
            ["HMGET", key(Uid), ?FIELD_PUSH_OS, ?FIELD_PUSH_TOKEN, ?FIELD_PUSH_TIMESTAMP,
            ?FIELD_PUSH_POST, ?FIELD_PUSH_COMMENT]),
    Res = #push_info{uid = Uid, 
            os = Os, 
            token = Token, 
            timestamp_ms = util_redis:decode_ts(TimestampMs),
            post_pref = boolean_decode(PushPost, true),
            comment_pref = boolean_decode(PushComment, true)},
    {ok, Res}.


-spec remove_push_info(Uid :: binary()) -> ok | {error, missing}.
remove_push_info(Uid) ->
    {ok, _Res} = q(["HDEL", key(Uid), ?FIELD_PUSH_OS, ?FIELD_PUSH_TOKEN, ?FIELD_PUSH_TIMESTAMP]),
    ok.


-spec set_push_post_pref(Uid :: binary(), PushPost :: boolean()) -> ok.
set_push_post_pref(Uid, PushPost) ->
    PushPostValue = boolean_encode(PushPost),
    {ok, _Res} = q(["HSET", key(Uid), ?FIELD_PUSH_POST, PushPostValue]),
    ok.


-spec get_push_post_pref(Uid :: binary()) -> {ok, boolean()}.
get_push_post_pref(Uid) ->
    {ok, PushPostValue} = q(["HGET", key(Uid), ?FIELD_PUSH_POST]),
    Res = boolean_decode(PushPostValue, true),
    {ok, Res}.


-spec remove_push_post_pref(Uid :: binary()) -> ok | {error, missing}.
remove_push_post_pref(Uid) ->
    {ok, _Res} = q(["HDEL", key(Uid), ?FIELD_PUSH_POST]),
    ok.


-spec set_push_comment_pref(Uid :: binary(), PushComment :: boolean()) -> ok.
set_push_comment_pref(Uid, PushComment) ->
    PushCommentValue = boolean_encode(PushComment),
    {ok, _Res} = q(["HMSET", key(Uid), ?FIELD_PUSH_COMMENT, PushCommentValue]),
    ok.


-spec get_push_comment_pref(Uid :: binary()) -> {ok, boolean()}.
get_push_comment_pref(Uid) ->
    {ok, [PushCommentValue]} = q(["HMGET", key(Uid), ?FIELD_PUSH_COMMENT]),
    Res = boolean_decode(PushCommentValue, true),
    {ok, Res}.


-spec remove_push_comment_pref(Uid :: binary()) -> ok | {error, missing}.
remove_push_comment_pref(Uid) ->
    {ok, _Res} = q(["HDEL", key(Uid), ?FIELD_PUSH_COMMENT]),
    ok.


-spec account_exists(Uid :: binary()) -> boolean().
account_exists(Uid) ->
    {ok, Res} = q(["HEXISTS", key(Uid), ?FIELD_PHONE]),
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


-spec is_account_deleted(Uid :: binary()) -> boolean().
is_account_deleted(Uid) ->
    {ok, Res} = q(["EXISTS", deleted_account_key(Uid)]),
    binary_to_integer(Res) > 0.


%%====================================================================
%% Presence related API
%%====================================================================


-spec set_last_activity(Uid :: binary(), TimestampMs :: integer(),
        ActivityStatus :: activity_status()) -> ok.
set_last_activity(Uid, TimestampMs, ActivityStatus) ->
    {ok, _Res1} = q(
            ["HMSET", key(Uid),
            ?FIELD_LAST_ACTIVITY, integer_to_binary(TimestampMs),
            ?FIELD_ACTIVITY_STATUS, util:to_binary(ActivityStatus)]),
    ok.


-spec get_last_activity(Uid :: binary()) -> {ok, activity()} | {error, missing}.
get_last_activity(Uid) ->
    {ok, [TimestampMs, ActivityStatus]} = q(
            ["HMGET", key(Uid), ?FIELD_LAST_ACTIVITY, ?FIELD_ACTIVITY_STATUS]),
    Res = case util_redis:decode_ts(TimestampMs) of
            undefined ->
                #activity{uid = Uid};
            TsMs ->
                #activity{uid = Uid, last_activity_ts_ms = TsMs,
                        status = util:to_atom(ActivityStatus)}
        end,
    {ok, Res}.


-spec presence_subscribe(Uid :: binary(), Buid :: binary()) -> ok.
presence_subscribe(Uid, Buid) ->
    {ok, _Res1} = q(["SADD", subscribe_key(Uid), Buid]),
    {ok, _Res2} = q(["SADD", broadcast_key(Buid), Uid]),
    ok.


-spec presence_unsubscribe(Uid :: binary(), Buid :: binary()) -> boolean().
presence_unsubscribe(Uid, Buid) ->
    {ok, _Res1} = q(["SREM", subscribe_key(Uid), Buid]),
    {ok, _Res2} = q(["SREM", broadcast_key(Buid), Uid]),
    ok.


-spec presence_unsubscribe_all(Uid :: binary()) -> ok.
presence_unsubscribe_all(Uid) ->
    {ok, Buids} = q(["SMEMBERS", subscribe_key(Uid)]),
    lists:foreach(fun (Buid) ->
            {ok, _Res} = q(["SREM", broadcast_key(Buid), Uid])
        end,
        Buids),
    {ok, _} = q(["DEL", subscribe_key(Uid)]),
    ok.


-spec get_subscribed_uids(Uid :: binary()) -> {ok, [binary()]}.
get_subscribed_uids(Uid) ->
    {ok, Buids} = q(["SMEMBERS", subscribe_key(Uid)]),
    {ok, Buids}.


-spec get_broadcast_uids(Uid :: binary()) -> {ok, [binary()]}.
get_broadcast_uids(Uid) ->
    {ok, Buids} = q(["SMEMBERS", broadcast_key(Uid)]),
    {ok, Buids}.


%%====================================================================
%% Counts related API
%%====================================================================


-spec count_registrations() -> non_neg_integer().
count_registrations() ->
    redis_counts:count_fold(fun model_accounts:count_registrations/1).


-spec count_registrations(Slot :: non_neg_integer()) -> non_neg_integer().
count_registrations(Slot) ->
    {ok, CountBin} = q(["GET", count_registrations_key_slot(Slot)]),
    Count = case CountBin of
                undefined -> 0;
                CountBin -> binary_to_integer(CountBin)
            end,
    Count.


-spec count_accounts() -> non_neg_integer().
count_accounts() ->
    redis_counts:count_fold(fun model_accounts:count_accounts/1).


-spec count_accounts(Slot :: non_neg_integer()) -> non_neg_integer().
count_accounts(Slot) ->
    {ok, CountBin} = q(["GET", count_accounts_key_slot(Slot)]),
    Count = case CountBin of
                undefined -> 0;
                CountBin -> binary_to_integer(CountBin)
            end,
    Count.


fix_counters() ->
    ?INFO_MSG("start", []),
    {ok, Pools} = get_all_pools(),
    ?INFO_MSG("pools: ~p", [Pools]),
    ResultMap = compute_counters(Pools),
    ?INFO_MSG("result map ~p", [ResultMap]),
    maps:map(
        fun (K, V) ->
            {ok, _} = q(["SET", K, V])
        end,
        ResultMap),
    ?INFO_MSG("finished setting ~p counters", [maps:size(ResultMap)]),
    ok.


compute_counters(Pools) ->
    lists:foldl(
        fun (Pool, Map) ->
            scan_server(Pool, <<"0">>, Map)
        end,
        #{},
        Pools).


scan_server(Pool, Cursor, Map) ->
    {ok, [NewCursor, Results]} = qs(Pool, ["SCAN", Cursor, "COUNT", 500]),
    Fun = fun (V) -> V + 1 end,
    NewMap = lists:foldl(
        fun (Key, M) ->
            case process_key(Key) of
                skip -> M;
                {account, Uid} ->
                    CounterKey = count_registrations_key(Uid),
                    M2 = maps:update_with(CounterKey, Fun, 1, M),
                    CounterKey2 = count_accounts_key(Uid),
                    maps:update_with(CounterKey2, Fun, 1, M2);
                {deleted_account, Uid} ->
                    CounterKey = count_registrations_key(Uid),
                    maps:update_with(CounterKey, Fun, 1, M)
            end
        end,
        Map,
        Results),
    case NewCursor of
        <<"0">> -> NewMap;
        _ -> scan_server(Pool, NewMap, NewMap)
    end.


process_key(<<"acc:{", Rest/binary>>) ->
    [Uid, <<"">>] = binary:split(Rest, <<"}">>),
    {account, Uid};
process_key(<<"dac:{", Rest/binary>>) ->
    [Uid, <<"">>] = binary:split(Rest, <<"}">>),
    {deleted_account, Uid};
process_key(_Any) ->
    skip.

%%====================================================================
%% Tracing related API
%%====================================================================


-spec get_traced_uids() -> {ok, [binary()]}.
get_traced_uids() ->
    {ok, Uids} = q(["SMEMBERS", ?TRACED_UIDS_KEY]),
    {ok, Uids}.


-spec add_uid_to_trace(Uid :: binary()) -> ok.
add_uid_to_trace(Uid) ->
    {ok, _Res} = q(["SADD", ?TRACED_UIDS_KEY, Uid]),
    ok.


-spec remove_uid_from_trace(Uid :: binary()) -> ok.
remove_uid_from_trace(Uid) ->
    {ok, _Res} = q(["SREM", ?TRACED_UIDS_KEY, Uid]),
    ok.


-spec is_uid_traced(Uid :: binary()) -> boolean().
is_uid_traced(Uid) ->
    {ok, Res} = q(["SISMEMBER", ?TRACED_UIDS_KEY, Uid]),
    binary_to_integer(Res) == 1.


-spec get_traced_phones() -> {ok, [binary()]}.
get_traced_phones() ->
    {ok, Phones} = q(["SMEMBERS", ?TRACED_PHONES_KEY]),
    {ok, Phones}.


-spec add_phone_to_trace(Phone :: binary()) -> ok.
add_phone_to_trace(Phone) ->
    {ok, _Res} = q(["SADD", ?TRACED_PHONES_KEY, Phone]),
    ok.


-spec remove_phone_from_trace(Phone :: binary()) -> ok.
remove_phone_from_trace(Phone) ->
    {ok, _Res} = q(["SREM", ?TRACED_PHONES_KEY, Phone]),
    ok.


-spec is_phone_traced(Phone :: binary()) -> boolean().
is_phone_traced(Phone) ->
    {ok, Res} = q(["SISMEMBER", ?TRACED_PHONES_KEY, Phone]),
    binary_to_integer(Res) == 1.


-spec get_names(Uids :: [uid()]) -> names_map().
get_names(Uids) ->
    lists:foldl(
        fun (Uid, M) ->
            case model_accounts:get_name(Uid) of
                {ok, undefined} -> M;
                {ok, Name} -> maps:put(Uid, Name, M)
            end
        end,
        #{},
        Uids).


%%====================================================================
%% Internal redis functions.
%%====================================================================


q(Command) -> ecredis:q(ecredis_accounts, Command).
qp(Commands) -> ecredis:qp(ecredis_accounts, Commands).


get_all_pools() ->
    gen_server:call(redis_accounts_client, {get_all_pools}).

qs(Pool, Command) ->
    Result = gen_server:call(redis_accounts_client, {qs, Pool, Command}),
    Result.


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


% TODO rename to account_key
-spec key(binary()) -> binary().
key(Uid) ->
    <<?ACCOUNT_KEY/binary, <<"{">>/binary, Uid/binary, <<"}">>/binary>>.

-spec deleted_account_key(binary()) -> binary().
deleted_account_key(Uid) ->
    <<?DELETED_ACCOUNT_KEY/binary, <<"{">>/binary, Uid/binary, <<"}">>/binary>>.

subscribe_key(Uid) ->
    <<?SUBSCRIBE_KEY/binary, <<"{">>/binary, Uid/binary, <<"}">>/binary>>.

broadcast_key(Uid) ->
    <<?BROADCAST_KEY/binary, <<"{">>/binary, Uid/binary, <<"}">>/binary>>.

count_registrations_key(Uid) ->
    Slot = eredis_cluster_hash:hash(binary_to_list(Uid)),
    count_registrations_key_slot(Slot).

count_registrations_key_slot(Slot) ->
    redis_counts:count_key(Slot, ?COUNT_REGISTRATIONS_KEY).

count_accounts_key(Uid) ->
    Slot = eredis_cluster_hash:hash(binary_to_list(Uid)),
    count_accounts_key_slot(Slot).

count_accounts_key_slot(Slot) ->
    redis_counts:count_key(Slot, ?COUNT_ACCOUNTS_KEY).

