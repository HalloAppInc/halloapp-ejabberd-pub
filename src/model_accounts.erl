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
-behavior(gen_server).
-behavior(gen_mod).

-include("logger.hrl").
-include("account.hrl").
-include("eredis_cluster.hrl").

%% Export all functions for unit tests
-ifdef(TEST).
-compile(export_all).
-endif.

-export([start_link/0]).
%% gen_mod callbacks
-export([start/2, stop/1, depends/2, mod_options/1]).
%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, terminate/2, handle_info/2, code_change/3]).

-export([key/1]).


%% API
-export([
    create_account/4,
    delete_account/1,
    account_exists/1,
    is_account_deleted/1,
    get_account/1,
    get_phone/1,
    set_name/2,
    get_name/1,
    get_name_binary/1,
    delete_name/1,
    set_avatar_id/2,
    get_avatar_id/1,
    get_avatar_id_binary/1,
    get_last_activity/1,
    set_last_activity/3,
    get_signup_user_agent/1,
    set_push_info/1,
    set_push_info/4,
    get_push_info/1,
    remove_push_info/1,
    presence_subscribe/2,
    presence_unsubscribe/2,
    presence_unsubscribe_all/1,
    get_subscribed_uids/1,
    get_broadcast_uids/1,
    count_registrations/0,
    count_registrations/1,
    count_accounts/1,
    count_accounts/0,
    fix_counters/0
]).

-export([
    get_all_pools/0,
    qs/2
]).

start_link() ->
    gen_server:start_link({local, get_proc()}, ?MODULE, [], []).

%%====================================================================
%% gen_mod callbacks
%%====================================================================

start(Host, Opts) ->
    ?INFO_MSG("start ~w", [?MODULE]),
    gen_mod:start_child(?MODULE, Host, Opts, get_proc()).

stop(_Host) ->
    ?INFO_MSG("stop ~w", [?MODULE]),
    gen_mod:stop_child(get_proc()).

depends(_Host, _Opts) ->
    [{mod_redis, hard}].

mod_options(_Host) ->
    [].

get_proc() ->
    gen_mod:get_module_proc(global, ?MODULE).

%%====================================================================
%% API
%%====================================================================

-define(ACCOUNT_KEY, <<"acc:">>).
-define(DELETED_ACCOUNT_KEY, <<"dac:">>).
-define(SUBSCRIBE_KEY, <<"sub:">>).
-define(BROADCAST_KEY, <<"bro:">>).
-define(COUNT_REGISTRATIONS_KEY, <<"c_reg:">>).
-define(COUNT_ACCOUNTS_KEY, <<"c_acc:">>).

-define(FIELD_PHONE, <<"ph">>).
-define(FIELD_NAME, <<"na">>).
-define(FIELD_AVATAR_ID, <<"av">>).
-define(FIELD_CREATION_TIME, <<"ct">>).
-define(FIELD_LAST_ACTIVITY, <<"la">>).
-define(FIELD_ACTIVITY_STATUS, <<"st">>).
-define(FIELD_USER_AGENT, <<"ua">>).
-define(FIELD_PUSH_OS, <<"pos">>).
-define(FIELD_PUSH_TOKEN, <<"ptk">>).
-define(FIELD_PUSH_TIMESTAMP, <<"pts">>).


-spec create_account(Uid :: binary(), Phone :: binary(), Name :: binary(),
        UserAgent :: binary()) -> ok | {error, exists}.
create_account(Uid, Phone, Name, UserAgent) ->
    create_account(Uid, Phone, Name, UserAgent, util:now_ms()).

-spec create_account(Uid :: binary(), Phone :: binary(), Name :: binary(),
        UserAgent :: binary(), CreationTsMs :: integer()) -> ok | {error, exists | deleted}.
create_account(Uid, Phone, Name, UserAgent, CreationTsMs) ->
    gen_server:call(get_proc(), {create_account, Uid, Phone, Name, UserAgent, CreationTsMs}).

-spec delete_account(Uid :: binary()) -> ok.
delete_account(Uid) ->
    gen_server:call(get_proc(), {delete_account, Uid}).

-spec set_name(Uid :: binary(), Name :: binary()) -> ok  | {error, any()}.
set_name(Uid, Name) ->
    gen_server:call(get_proc(), {set_name, Uid, Name}).

-spec get_name(Uid :: binary()) -> binary() | {ok, binary() | undefined} | {error, any()}.
get_name(Uid) ->
    gen_server:call(get_proc(), {get_name, Uid}).

-spec delete_name(Uid :: binary()) -> ok  | {error, any()}.
delete_name(Uid) ->
    gen_server:call(get_proc(), {delete_name, Uid}).

-spec get_name_binary(Uid :: binary()) -> binary().
get_name_binary(Uid) ->
    {ok, Name} = get_name(Uid),
    case Name of
        undefined ->  <<>>;
        _ -> Name
    end.

-spec set_avatar_id(Uid :: binary(), AvatarId :: binary()) -> ok  | {error, any()}.
set_avatar_id(Uid, AvatarId) ->
    gen_server:call(get_proc(), {set_avatar_id, Uid, AvatarId}).

-spec get_avatar_id(Uid :: binary()) -> binary() | {ok, binary() | undefined} | {error, any()}.
get_avatar_id(Uid) ->
    gen_server:call(get_proc(), {get_avatar_id, Uid}).

-spec get_avatar_id_binary(Uid :: binary()) -> binary().
get_avatar_id_binary(Uid) ->
    {ok, AvatarId} = get_avatar_id(Uid),
    case AvatarId of
        undefined ->  <<>>;
        _ -> AvatarId
    end.

-spec get_phone(Uid :: binary()) -> {ok, binary()} | {error, missing}.
get_phone(Uid) ->
    gen_server:call(get_proc(), {get_phone, Uid}).

-spec get_creation_ts_ms(Uid :: binary()) -> {ok, integer()} | {error, missing}.
get_creation_ts_ms(Uid) ->
    gen_server:call(get_proc(), {get_creation_ts_ms, Uid}).

-spec get_signup_user_agent(Uid :: binary()) -> {ok, binary()} | {error, missing}.
get_signup_user_agent(Uid) ->
    gen_server:call(get_proc(), {get_signup_user_agent, Uid}).

-spec get_account(Uid :: binary()) -> {ok, account()} | {error, missing}.
get_account(Uid) ->
    gen_server:call(get_proc(), {get_account, Uid}).

-spec set_last_activity(Uid :: binary(), TimestampMs :: integer(),
        ActivityStatus :: activity_status()) -> ok.
set_last_activity(Uid, TimestampMs, ActivityStatus) ->
    gen_server:call(get_proc(), {set_last_activity, Uid, TimestampMs, ActivityStatus}).

-spec get_last_activity(Uid :: binary()) -> {ok, activity()} | {error, missing}.
get_last_activity(Uid) ->
    gen_server:call(get_proc(), {get_last_activity, Uid}).


-spec set_push_info(PushInfo :: push_info()) -> ok.
set_push_info(PushInfo) ->
    set_push_info(PushInfo#push_info.uid, PushInfo#push_info.os,
            PushInfo#push_info.token, PushInfo#push_info.timestamp_ms).


-spec set_push_info(Uid :: binary(), Os :: binary(), PushToken :: binary(),
        TimestampMs :: integer()) -> ok.
set_push_info(Uid, Os, PushToken, TimestampMs) ->
    gen_server:call(get_proc(), {set_push_info, Uid, Os, PushToken, TimestampMs}).


-spec get_push_info(Uid :: binary()) -> {ok, undefined | push_info()} | {error, missing}.
get_push_info(Uid) ->
    gen_server:call(get_proc(), {get_push_info, Uid}).


-spec remove_push_info(Uid :: binary()) -> ok | {error, missing}.
remove_push_info(Uid) ->
    gen_server:call(get_proc(), {remove_push_info, Uid}).


-spec account_exists(Uid :: binary()) -> boolean().
account_exists(Uid) ->
    gen_server:call(get_proc(), {account_exists, Uid}).

-spec is_account_deleted(Uid :: binary()) -> boolean().
is_account_deleted(Uid) ->
    gen_server:call(get_proc(), {is_account_deleted, Uid}).

-spec presence_subscribe(Uid :: binary(), Buid :: binary()) -> boolean().
presence_subscribe(Uid, Buid) ->
    gen_server:call(get_proc(), {presence_subscribe, Uid, Buid}).

-spec presence_unsubscribe(Uid :: binary(), Buid :: binary()) -> boolean().
presence_unsubscribe(Uid, Buid) ->
    gen_server:call(get_proc(), {presence_unsubscribe, Uid, Buid}).

-spec presence_unsubscribe_all(Uid :: binary()) -> ok.
presence_unsubscribe_all(Uid) ->
    gen_server:call(get_proc(), {presence_unsubscribe_all, Uid}).

-spec get_subscribed_uids(Uid :: binary()) -> {ok, [binary()]}.
get_subscribed_uids(Uid) ->
    gen_server:call(get_proc(), {get_subscribed_uids, Uid}).

-spec get_broadcast_uids(Uid :: binary()) -> {ok, [binary()]}.
get_broadcast_uids(Uid) ->
    gen_server:call(get_proc(), {get_broadcast_uids, Uid}).

-spec count_registrations() -> non_neg_integer().
count_registrations() ->
    count_fold(fun model_accounts:count_registrations/1, "count_registrations").

-spec count_registrations(Slot :: non_neg_integer()) -> non_neg_integer().
count_registrations(Slot) ->
    gen_server:call(get_proc(), {count_registrations, Slot}).

-spec count_accounts() -> non_neg_integer().
count_accounts() ->
    count_fold(fun model_accounts:count_accounts/1, "count_accounts").

-spec count_accounts(Slot :: non_neg_integer()) -> non_neg_integer().
count_accounts(Slot) ->
    gen_server:call(get_proc(), {count_accounts, Slot}).

count_fold(Fun, Name) ->
    lists:foldl(
        fun (Slot, Acc) ->
            C = Fun(Slot),
            case C > 0 of
                true -> ?DEBUG("name: ~s, slot ~p count ~p", [Name, Slot, C]);
                false -> ok
            end,
            Acc + C
        end,
        0,
        lists:seq(0, ?REDIS_CLUSTER_HASH_SLOTS -1)).

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
    ResultMap = lists:foldl(
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
                    maps:update_with(CounterKey, Fun, 1, M);
                {deleted_account, Uid} ->
                    CounterKey = count_registrations_key(Uid),
                    M2 = maps:update_with(CounterKey, Fun, 1, M),
                    CounterKey2 = count_accounts_key(Uid),
                    maps:update_with(CounterKey2, Fun, 1, M2)
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
%% gen_server callbacks
%%====================================================================

init(_Stuff) ->
    process_flag(trap_exit, true),
    {ok, redis_accounts_client}.

handle_call({get_connection}, _From, Redis) ->
    {reply, {ok, Redis}, Redis};

handle_call({create_account, Uid, Phone, Name, UserAgent, CreationTsMs}, _From, Redis) ->
    {ok, Deleted} = q(["EXISTS", deleted_account_key(Uid)]),
    case binary_to_integer(Deleted) == 1 of
        true -> {reply, {error, deleted}, Redis};
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
                    [{ok, _FieldCount}, {ok, <<"1">>}, {ok, <<"1">>}] = Res,
                    {reply, ok, Redis};
                false ->
                    {reply, {error, exists}, Redis}
            end
    end;

handle_call({delete_account, Uid}, _From, Redis) ->
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
    {reply, ok, Redis};

handle_call({account_exists, Uid}, _From, Redis) ->
    {ok, Res} = q(["HEXISTS", key(Uid), ?FIELD_PHONE]),
    {reply, binary_to_integer(Res) > 0, Redis};

handle_call({is_account_deleted, Uid}, _From, Redis) ->
    {ok, Res} = q(["EXISTS", deleted_account_key(Uid)]),
    {reply, binary_to_integer(Res) > 0, Redis};

handle_call({get_account, Uid}, _From, Redis) ->
    {ok, Res} = q(["HGETALL", key(Uid)]),
    M = util:list_to_map(Res),
    Account = #account{
            uid = Uid,
            phone = maps:get(?FIELD_PHONE, M),
            name = maps:get(?FIELD_NAME, M),
            signup_user_agent = maps:get(?FIELD_USER_AGENT, M),
            creation_ts_ms = ts_decode(maps:get(?FIELD_CREATION_TIME, M)),
            last_activity_ts_ms = ts_decode(maps:get(?FIELD_LAST_ACTIVITY, M, undefined)),
            activity_status = util:to_atom(maps:get(?FIELD_ACTIVITY_STATUS, M, undefined))
        },
    {reply, {ok, Account}, Redis};

handle_call({get_phone, Uid}, _From, Redis) ->
    {ok, Res} = q(["HGET", key(Uid), ?FIELD_PHONE]),
    case Res of
        undefined -> {reply, {error, missing}, Redis};
        Res -> {reply, {ok, Res}, Redis}
    end;

handle_call({get_signup_user_agent, Uid}, _From, Redis) ->
    {ok, Res} = q(["HGET", key(Uid), ?FIELD_USER_AGENT]),
    case Res of
        undefined -> {reply, {error, missing}, Redis};
        Res -> {reply, {ok, Res}, Redis}
    end;

handle_call({get_creation_ts_ms, Uid}, _From, Redis) ->
    {ok, Res} = q(["HGET", key(Uid), ?FIELD_CREATION_TIME]),
    {reply, ts_reply(Res), Redis};

handle_call({set_name, Uid, Name}, _From, Redis) ->
    {ok, _Res} = q(["HSET", key(Uid), ?FIELD_NAME, Name]),
    {reply, ok, Redis};

handle_call({get_name, Uid}, _From, Redis) ->
    {ok, Res} = q(["HGET", key(Uid), ?FIELD_NAME]),
    {reply, {ok, Res}, Redis};

handle_call({delete_name, Uid}, _From, Redis) ->
    {ok, _Res} = q(["HDEL", key(Uid), ?FIELD_NAME]),
    {reply, ok, Redis};

handle_call({set_avatar_id, Uid, AvatarId}, _From, Redis) ->
    {ok, _Res} = q(["HSET", key(Uid), ?FIELD_AVATAR_ID, AvatarId]),
    {reply, ok, Redis};

handle_call({get_avatar_id, Uid}, _From, Redis) ->
    {ok, Res} = q(["HGET", key(Uid), ?FIELD_AVATAR_ID]),
    {reply, {ok, Res}, Redis};

handle_call({set_last_activity, Uid, Timestamp, Status}, _From, Redis) ->
    {ok, _Res} = q(
            ["HMSET", key(Uid),
            ?FIELD_LAST_ACTIVITY, integer_to_binary(Timestamp),
            ?FIELD_ACTIVITY_STATUS, util:to_binary(Status)]),
    {reply, ok, Redis};

handle_call({get_last_activity, Uid}, _From, Redis) ->
    {ok, [TimestampMs, ActivityStatus]} = q(
            ["HMGET", key(Uid), ?FIELD_LAST_ACTIVITY, ?FIELD_ACTIVITY_STATUS]),
    Res = case ts_decode(TimestampMs) of
            undefined ->
                #activity{uid = Uid};
            TsMs ->
                #activity{uid = Uid, last_activity_ts_ms = TsMs,
                        status = util:to_atom(ActivityStatus)}
        end,
    {reply, {ok, Res}, Redis};

handle_call({set_push_info, Uid, Os, Token, TimestampMs}, _From, Redis) ->
    {ok, _Res} = q(
            ["HMSET", key(Uid),
            ?FIELD_PUSH_OS, Os,
            ?FIELD_PUSH_TOKEN, Token,
            ?FIELD_PUSH_TIMESTAMP, integer_to_binary(TimestampMs)]),
    {reply, ok, Redis};

handle_call({get_push_info, Uid}, _From, Redis) ->
    {ok, [Os, Token, TimestampMs]} = q(
            ["HMGET", key(Uid), ?FIELD_PUSH_OS, ?FIELD_PUSH_TOKEN, ?FIELD_PUSH_TIMESTAMP]),
    Res = case ts_decode(TimestampMs) of
            undefined ->
                undefined;
            TsMs ->
                #push_info{uid = Uid, os = Os, token = Token, timestamp_ms = TsMs}
        end,
    {reply, {ok, Res}, Redis};

handle_call({remove_push_info, Uid}, _From, Redis) ->
    {ok, _Res} = q(["HDEL", key(Uid), ?FIELD_PUSH_OS, ?FIELD_PUSH_TOKEN, ?FIELD_PUSH_TIMESTAMP]),
    {reply, ok, Redis};

handle_call({presence_subscribe, Uid, Buid}, _From, Redis) ->
    {ok, Res1} = q(["SADD", subscribe_key(Uid), Buid]),
    {ok, _Res2} = q(["SADD", broadcast_key(Buid), Uid]),
    {reply, binary_to_integer(Res1) == 1, Redis};

handle_call({presence_unsubscribe, Uid, Buid}, _From, Redis) ->
    {ok, Res1} = q(["SREM", subscribe_key(Uid), Buid]),
    {ok, _Res2} = q(["SREM", broadcast_key(Buid), Uid]),
    {reply, binary_to_integer(Res1) == 1, Redis};

handle_call({presence_unsubscribe_all, Uid}, _From, Redis) ->
    {ok, Buids} = q(["SMEMBERS", subscribe_key(Uid)]),
    lists:foreach(fun (Buid) ->
            {ok, _Res} = q(["SREM", broadcast_key(Buid), Uid])
        end,
        Buids),
    {ok, _} = q(["DEL", subscribe_key(Uid)]),
    {reply, ok, Redis};

handle_call({get_subscribed_uids, Uid}, _From, Redis) ->
    {ok, Buids} = q(["SMEMBERS", subscribe_key(Uid)]),
    {reply, {ok, Buids}, Redis};

handle_call({get_broadcast_uids, Uid}, _From, Redis) ->
    {ok, Buids} = q(["SMEMBERS", broadcast_key(Uid)]),
    {reply, {ok, Buids}, Redis};

handle_call({count_registrations, Slot}, _From, Redis) ->
    {ok, CountBin} = q(["GET", count_registrations_key_slot(Slot)]),
    Count = case CountBin of
                undefined -> 0;
                CountBin -> binary_to_integer(CountBin)
            end,
    {reply, Count, Redis};

handle_call({count_accounts, Slot}, _From, Redis) ->
    {ok, CountBin} = q(["GET", count_accounts_key_slot(Slot)]),
    Count = case CountBin of
                undefined -> 0;
                CountBin -> binary_to_integer(CountBin)
            end,
    {reply, Count, Redis}.


handle_cast(_Message, Redis) -> {noreply, Redis}.
handle_info(_Message, Redis) -> {noreply, Redis}.
terminate(_Reason, _Redis) -> ok.
code_change(_OldVersion, Redis, _Extra) -> {ok, Redis}.

q(Command) ->
    {ok, Result} = gen_server:call(redis_accounts_client, {q, Command}),
    Result.

qp(Commands) ->
    {ok, Results} = gen_server:call(redis_accounts_client, {qp, Commands}),
    Results.


get_all_pools() ->
    gen_server:call(redis_accounts_client, {get_all_pools}).

qs(Pool, Command) ->
    Result = gen_server:call(redis_accounts_client, {qs, Pool, Command}),
    Result.


ts_reply(Res) ->
    case ts_decode(Res) of
        undefined -> {error, missing};
        Ts -> {ok, Ts}
    end.

ts_decode(Data) ->
    case Data of
        undefined -> undefined;
        Data -> binary_to_integer(Data)
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
    count_key(Slot, ?COUNT_REGISTRATIONS_KEY).

count_accounts_key(Uid) ->
    Slot = eredis_cluster_hash:hash(binary_to_list(Uid)),
    count_accounts_key_slot(Slot).

count_accounts_key_slot(Slot) ->
    count_key(Slot, ?COUNT_ACCOUNTS_KEY).

count_key(Slot, Prefix) when is_integer(Slot), is_binary(Prefix) ->
    SlotKey = mod_redis:get_slot_key(Slot),
    SlotBinary = integer_to_binary(Slot),
    <<Prefix/binary, <<"{">>/binary, SlotKey/binary, <<"}.">>/binary,
        SlotBinary/binary>>.
