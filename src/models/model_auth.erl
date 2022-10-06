%%%-------------------------------------------------------------------
%%% @author nikola
%%% @copyright (C) 2020, HalloApp, Inc.
%%% @doc
%%%
%%% @end
%%% Created : 15. Apr 2020 2:53 PM
%%%-------------------------------------------------------------------
-module(model_auth).
-author("nikola").

-include("_build/default/lib/ecredis/include/ecredis.hrl").
-include("logger.hrl").
-include("password.hrl").
-include("redis_keys.hrl").
-include("ha_types.hrl").
-include("time.hrl").

-ifdef(TEST).
-export([spub_key/1, static_key_attempt_key/2]).
-endif.

-define(LOCKED, <<"locked:">>).
-define(LOCKED_SIZE, byte_size(?LOCKED)).
-define(TTL_STATIC_KEY_ATTEMPT, 86400).

%% API
-export([
    set_spub/2,
    get_spub/1,
    get_uid_from_spub/1,
    spub_search/1,
    delete_spub/1,
    lock_user/1,
    unlock_user/1,
    set_login/1,
    authenticate_static_key/2,
    delete_static_key/2,
    get_static_keys/1,
    get_static_key_uid/1,
    add_static_key_code_attempt/2,
    get_static_key_code_attempts/2
]).

%%====================================================================
%% API
%%====================================================================

-define(FIELD_TIMESTAMP_MS, <<"tms">>).
-define(FIELD_S_PUB, <<"spb">>).
-define(FIELD_LOGIN_STATUS, <<"log">>).
-define(FIELD_SPUB_UID, <<"spu">>).
-define(FIELD_STATIC_KEY_UID, <<"sku">>).
-define(TTL_REVERSE_SPUB, (30 * ?DAYS)).


-spec set_spub(Uid :: binary(), SPub :: binary()) -> ok  | {error, any()}.
set_spub(Uid, SPub) ->
    TimestampMs = util:now_ms(),
    Commands = [
        ["DEL", spub_key(Uid)],
        ["HSET", spub_key(Uid),
            ?FIELD_S_PUB, SPub,
            ?FIELD_TIMESTAMP_MS, integer_to_binary(TimestampMs)]
    ],
    set_reverse_spub(Uid, SPub),
    util_redis:verify_ok(multi_exec(Commands)).


set_reverse_spub(Uid, SPub) ->
    Commands = [
        ["DEL", reverse_spub_key(SPub)],
        ["HSET", reverse_spub_key(SPub), ?FIELD_SPUB_UID, Uid],
        ["EXPIRE", reverse_spub_key(SPub), ?TTL_REVERSE_SPUB]
    ],
    util_redis:verify_ok(multi_exec(Commands)).


-spec get_spub(Uid :: binary()) -> {ok, s_pub()} | {error, missing}.
get_spub(Uid) ->
    {ok, [SPub, TsMsBinary]} = q(["HMGET", spub_key(Uid),
        ?FIELD_S_PUB, ?FIELD_TIMESTAMP_MS]),
    {ok, #s_pub{
        s_pub = SPub,
        ts_ms = util_redis:decode_ts(TsMsBinary),
        uid = Uid
    }}.


-spec get_uid_from_spub(binary()) -> {ok, uid()} | {error, missing}.
get_uid_from_spub(SPub) ->
    q(["HGET", reverse_spub_key(SPub), ?FIELD_SPUB_UID]).


%% for `ejabberdctl spub_info`
-spec spub_search(binary()) -> list({binary(), uid()}).
spub_search(RevSPubPrefix) ->
    FormattedRevSPubPrefix = util:to_binary([?REVERSE_SPUB_KEY, "{", RevSPubPrefix, "*"]),
    NodeList = lists:map(fun(Node) -> {Node, "0"} end, ecredis:get_nodes(ecredis_auth)),
    spub_search(NodeList, FormattedRevSPubPrefix).


%% Recursive function to scan each node until RevSPubPrefix returns some match(es)
-spec spub_search([{Node :: rnode(), Cursor :: binary()}], binary()) -> list({binary(), uid()}).
spub_search(NodeList, _RevSPubPrefix) when NodeList =:= [] ->
    %% Base case: NodeList is empty; all nodes have been fully searched with no results
    [];
spub_search(NodeList, RevSPubPrefix) ->
    %% Run SCAN on each node
    Results = lists:map(
        fun({Node, Cursor}) ->
            {Node, qn(Node, ["SCAN", Cursor, "MATCH", RevSPubPrefix, "COUNT", "500"])}
        end,
        NodeList),
    %% Remove nodes that have been fully scanned and returned no results
    %% Also trim and flatten data to [{Node, NewCursor, ScanResults}]
    FilteredResults = lists:filtermap(
        fun({Node, {ok, Result}}) ->
            case Result of
                [<<"0">>, []] -> false;
                [NewCursor, ScanResult] -> {true, {Node, NewCursor, ScanResult}}
            end
        end,
        Results),
    %% Check if any results were found on any node
    case lists:any(fun({_Node, _Cursor, ScanRes}) -> ScanRes =/= [] end, FilteredResults) of
        false ->
            %% No results were found on any node; enter recursion
            UpdatedNodeList = lists:map(
                fun({Node, NewCursor, _}) -> {Node, NewCursor} end,
                FilteredResults),
            spub_search(UpdatedNodeList, RevSPubPrefix);
        true ->
            %% Some node(s) had results; combine all results and return them
            lists:filtermap(
                fun
                    ({_Node, _Cursor, ScanResult}) when ScanResult =:= [] ->
                        false;
                    ({_Node, _Cursor, [ReverseSPubKey]}) ->
                        %% Return value is {SPub, Uid}
                        [_Prefix, SPub] = binary:split(ReverseSPubKey, [<<"{">>, <<"}">>],
                            [global, trim]),
                        {ok, Uid} = get_uid_from_spub(SPub),
                        {true, {SPub, Uid}}
                end,
                FilteredResults)
    end.


-spec set_login(Uid :: binary()) -> boolean().
set_login(Uid) ->
    {ok, Exists} = q(["HSETNX", spub_key(Uid), ?FIELD_LOGIN_STATUS, 1]),
    Exists =:= <<"1">>.


-spec lock_user(Uid :: binary()) -> ok | {error, any()}.
lock_user(Uid) ->
    {ok, #s_pub{s_pub = SPub, ts_ms = _TsMs, uid = _Uid}} = get_spub(Uid),
    {Locked, LockedSize} = {?LOCKED, ?LOCKED_SIZE},
    case SPub of
        <<Locked:LockedSize/binary, _Rest/binary>> -> ok;
        _ ->
            SPub2 = <<?LOCKED/binary, SPub/binary>>,
            set_spub(Uid, SPub2)
    end.


-spec unlock_user(Uid :: binary()) -> ok | {error, any()}.
unlock_user(Uid) ->
    {ok, #s_pub{s_pub = LockedSPub, ts_ms = _TsMs, uid = _Uid}} = get_spub(Uid),
    {Locked, LockedSize} = {?LOCKED, ?LOCKED_SIZE},
    case LockedSPub of
        <<Locked:LockedSize/binary, Rest/binary>> -> set_spub(Uid, Rest);
        _ -> ok
    end.


-spec delete_spub(Uid :: binary()) -> ok  | {error, any()}.
delete_spub(Uid) ->
    {ok, _Res} = q(["DEL", spub_key(Uid)]),
    ok.

%% TODO(vipin): Delete the mapping from Uid to StaticKey if not needed.
-spec authenticate_static_key(Uid :: uid(), StaticKey :: binary()) -> ok | {error, any()}.
authenticate_static_key(Uid, StaticKey) ->
    ListKey = static_key_key(Uid),
    RevStaticKey = reverse_static_key_key(StaticKey),
    Results = qmn([["SADD", ListKey, StaticKey],
                    ["HSET", RevStaticKey, ?FIELD_STATIC_KEY_UID, Uid] ]),  
    util_redis:verify_ok(Results).

-spec delete_static_key(Uid :: uid(), StaticKey :: binary()) -> ok | {error, any()}.
delete_static_key(Uid, StaticKey) ->
    ListKey = static_key_key(Uid),
    RevStaticKey = reverse_static_key_key(StaticKey),
    Results = qmn([["SREM", ListKey, StaticKey],
                    ["HDEL", RevStaticKey, ?FIELD_STATIC_KEY_UID]]),
    util_redis:verify_ok(Results).

-spec get_static_keys(Uid :: uid()) -> {ok, [binary()]}.
get_static_keys(Uid) ->
    ListKey = static_key_key(Uid),
    q(["SMEMBERS", ListKey]).

-spec get_static_key_uid(StaticKey :: binary()) -> {ok, maybe(binary())}.
get_static_key_uid(StaticKey) ->
    RevStaticKey = reverse_static_key_key(StaticKey),
    q(["HGET", RevStaticKey, ?FIELD_STATIC_KEY_UID]).

-spec add_static_key_code_attempt(StaticKey :: binary(), Timestamp :: integer()) -> integer().
add_static_key_code_attempt(StaticKey, Timestamp) ->
    Key = static_key_attempt_key(StaticKey, Timestamp),
    {ok, [Res, _]} = multi_exec([
        ["INCR", Key],
        ["EXPIRE", Key, ?TTL_STATIC_KEY_ATTEMPT]
    ]),
    util_redis:decode_int(Res).

-spec get_static_key_code_attempts(StaticKey :: binary(), Timestamp :: integer()) -> maybe(integer()).
get_static_key_code_attempts(StaticKey, Timestamp) ->
    Key = static_key_attempt_key(StaticKey, Timestamp),
    {ok, Res} = q(["GET", Key]),
    case Res of
        undefined -> 0;
        Res -> util:to_integer(Res)
    end.


q(Command) -> ecredis:q(ecredis_auth, Command).
qn(Node, Command) -> ecredis:qn(ecredis_auth, Node, Command).
qp(Commands) -> ecredis:qp(ecredis_auth, Commands).
qmn(Commands) -> util_redis:run_qmn(ecredis_auth, Commands).


multi_exec(Commands) ->
    WrappedCommands = lists:append([[["MULTI"]], Commands, [["EXEC"]]]),
    Results = qp(WrappedCommands),
    [ExecResult|_Rest] = lists:reverse(Results),
    ExecResult.


-spec spub_key(binary()) -> binary().
spub_key(Uid) ->
    <<?SPUB_KEY/binary, <<"{">>/binary, Uid/binary, <<"}">>/binary>>.

reverse_spub_key(SPub) ->
    <<?REVERSE_SPUB_KEY/binary, <<"{">>/binary, SPub/binary, <<"}">>/binary>>.

static_key_key(Uid) ->
    <<?STATIC_KEY_KEY/binary, <<"{">>/binary, Uid/binary, <<"}">>/binary>>.

reverse_static_key_key(StaticKey) ->
    <<?REVERSE_STATIC_KEY_KEY/binary, <<"{">>/binary, StaticKey/binary, <<"}">>/binary>>.


-spec static_key_attempt_key(StaticKey :: binary(), Timestamp :: integer() ) -> binary().
static_key_attempt_key(StaticKey, Timestamp) ->
    KeyBin = util:to_binary(StaticKey),
    Day = util:to_binary(util:to_integer(Timestamp / ?DAYS)),
    <<?STATIC_KEY_ATTEMPT_KEY/binary, "{", KeyBin/binary, "}:", Day/binary>>.

