%%%-----------------------------------------------------------------------------------
%%% File    : model_privacy.erl
%%%
%%% Copyright (C) 2020 halloappinc.
%%%
%%%
%%%-----------------------------------------------------------------------------------
-module(model_privacy).
-author('murali').
-behavior(gen_mod).

-include("logger.hrl").
-include("eredis_cluster.hrl").
-include("redis_keys.hrl").

%% Export all functions for unit tests
-ifdef(TEST).
-compile(export_all).
-endif.

%% gen_mod callbacks
-export([start/2, stop/1, depends/2, mod_options/1]).

%% API
-export([
    set_privacy_type/2,
    get_privacy_type/1,
    get_privacy_type_atom/1,
    whitelist_uid/2,
    whitelist_uids/2,
    blacklist_uid/2,
    blacklist_uids/2,
    mute_uid/2,
    mute_uids/2,
    block_uid/2,
    block_uids/2,
    unwhitelist_uid/2,
    unwhitelist_uids/2,
    unblacklist_uid/2,
    unblacklist_uids/2,
    unmute_uid/2,
    unmute_uids/2,
    unblock_uid/2,
    unblock_uids/2,
    get_whitelist_uids/1,
    get_blacklist_uids/1,
    get_mutelist_uids/1,
    get_blocked_uids/1,
    get_blocked_by_uids/1,
    is_whitelisted/2,
    is_blacklisted/2,
    is_blocked/2,
    is_blocked_by/2,
    is_blocked_any/2
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


-define(FIELD_PRIVACY_LIST_TYPE, <<"plt">>).
-define(USER_VAL, <<"">>).


%%====================================================================
%% Privacy related API
%%====================================================================


-spec set_privacy_type(Uid :: binary(), Type :: atom()) -> ok.
set_privacy_type(Uid, Type) ->
    Value = encode_feed_privacy_list_type(Type),
    {ok, _Res} = q(["HSET", model_accounts:key(Uid), ?FIELD_PRIVACY_LIST_TYPE, Value]),
    ok.


-spec get_privacy_type(Uid :: binary()) -> {ok, atom()} | {error, any()}.
get_privacy_type(Uid) ->
    {ok, Res} = q(["HGET", model_accounts:key(Uid), ?FIELD_PRIVACY_LIST_TYPE]),
    {ok, decode_feed_privacy_list_type(Res)}.


-spec get_privacy_type_atom(Uid :: binary()) -> atom() | {error, any()}.
get_privacy_type_atom(Uid) ->
    {ok, Res} = get_privacy_type(Uid),
    Res.


-spec whitelist_uid(Uid :: binary(), Ouid :: binary()) -> ok.
whitelist_uid(Uid, Ouid) ->
    whitelist_uids(Uid, [Ouid]).


-spec whitelist_uids(Uid :: binary(), Ouids :: list(binary())) -> ok.
whitelist_uids(_Uid, []) -> ok;
whitelist_uids(Uid, Ouids) ->
    {ok, _Res} = q(["SADD", whitelist_key(Uid) | Ouids]),
    ok.


-spec blacklist_uid(Uid :: binary(), Ouid :: binary()) -> ok.
blacklist_uid(Uid, Ouid) ->
    blacklist_uids(Uid, [Ouid]).


-spec blacklist_uids(Uid :: binary(), Ouids :: list(binary())) -> ok.
blacklist_uids(_Uid, []) -> ok;
blacklist_uids(Uid, Ouids) ->
    {ok, _Res} = q(["SADD", blacklist_key(Uid) | Ouids]),
    ok.


-spec mute_uid(Uid :: binary(), Ouid :: binary()) -> ok.
mute_uid(Uid, Ouid) ->
    mute_uids(Uid, [Ouid]).


-spec mute_uids(Uid :: binary(), Ouids :: list(binary())) -> ok.
mute_uids(_Uid, []) -> ok;
mute_uids(Uid, Ouids) ->
    {ok, _Res} = q(["SADD", mute_key(Uid) | Ouids]),
    ok.


-spec block_uid(Uid :: binary(), Ouid :: binary()) -> ok.
block_uid(Uid, Ouid) ->
    block_uids(Uid, [Ouid]).


-spec block_uids(Uid :: binary(), Ouids :: list(binary())) -> ok.
block_uids(_Uid, []) -> ok;
block_uids(Uid, Ouids) ->
    BlockKey = block_key(Uid),
    Commands = lists:map(fun(Ouid) -> ["SADD", BlockKey, Ouid] end, Ouids),
    _Results = qp(Commands),
    lists:foreach(fun(Ouid) -> q(["SADD", reverse_block_key(Ouid), Uid]) end, Ouids),
    ok.


-spec unwhitelist_uid(Uid :: binary(), Ouid :: binary()) -> ok.
unwhitelist_uid(Uid, Ouid) ->
    unwhitelist_uids(Uid, [Ouid]).


-spec unwhitelist_uids(Uid :: binary(), Ouids :: list(binary())) -> ok.
unwhitelist_uids(_Uid, []) -> ok;
unwhitelist_uids(Uid, Ouids) ->
    {ok, _Res} = q(["SREM", whitelist_key(Uid) | Ouids]),
    ok.


-spec unblacklist_uid(Uid :: binary(), Ouid :: binary()) -> ok.
unblacklist_uid(Uid, Ouid) ->
    unblacklist_uids(Uid, [Ouid]).


-spec unblacklist_uids(Uid :: binary(), Ouids :: list(binary())) -> ok.
unblacklist_uids(_Uid, []) -> ok;
unblacklist_uids(Uid, Ouids) ->
    {ok, _Res} = q(["SREM", blacklist_key(Uid) | Ouids]),
    ok.


-spec unmute_uid(Uid :: binary(), Ouid :: binary()) -> ok.
unmute_uid(Uid, Ouid) ->
    unmute_uids(Uid, [Ouid]).


-spec unmute_uids(Uid :: binary(), Ouids :: list(binary())) -> ok.
unmute_uids(_Uid, []) -> ok;
unmute_uids(Uid, Ouids) ->
    {ok, _Res} = q(["SREM", mute_key(Uid) | Ouids]),
    ok.


-spec unblock_uid(Uid :: binary(), Ouid :: binary()) -> ok.
unblock_uid(Uid, Ouid) ->
    unblock_uids(Uid, [Ouid]).


-spec unblock_uids(Uid :: binary(), Ouids :: list(binary())) -> ok.
unblock_uids(_Uid, []) -> ok;
unblock_uids(Uid, Ouids) ->
    {ok, _Res} = q(["SREM", block_key(Uid) | Ouids]),
    lists:foreach(fun(Ouid) -> q(["SREM", reverse_block_key(Ouid), Uid]) end, Ouids),
    ok.

-spec get_whitelist_uids(Uid :: binary()) -> {ok, list(binary())}.
get_whitelist_uids(Uid) ->
    {ok, Res} = q(["SMEMBERS", whitelist_key(Uid)]),
    {ok, Res}.


-spec get_blacklist_uids(Uid :: binary()) -> {ok, list(binary())}.
get_blacklist_uids(Uid) ->
    {ok, Res} = q(["SMEMBERS", blacklist_key(Uid)]),
    {ok, Res}.


-spec get_mutelist_uids(Uid :: binary()) -> {ok, list(binary())}.
get_mutelist_uids(Uid) ->
    {ok, Res} = q(["SMEMBERS", mute_key(Uid)]),
    {ok, Res}.


-spec get_blocked_uids(Uid :: binary()) -> {ok, list(binary())}.
get_blocked_uids(Uid) ->
    {ok, Res} = q(["SMEMBERS", block_key(Uid)]),
    {ok, Res}.


-spec get_blocked_by_uids(Uid :: binary()) -> {ok, list(binary())}.
get_blocked_by_uids(Uid) ->
    {ok, Res} = q(["SMEMBERS", reverse_block_key(Uid)]),
    {ok, Res}.


-spec is_whitelisted(Uid :: binary(), Ouid :: binary()) -> boolean().
is_whitelisted(Uid, Ouid) ->
    {ok, Res} = q(["SISMEMBER", whitelist_key(Uid), Ouid]),
    binary_to_integer(Res) == 1.


-spec is_blacklisted(Uid :: binary(), Ouid :: binary()) -> boolean().
is_blacklisted(Uid, Ouid) ->
    {ok, Res} = q(["SISMEMBER", blacklist_key(Uid), Ouid]),
    binary_to_integer(Res) == 1.


-spec is_blocked(Uid :: binary(), Ouid :: binary()) -> boolean().
is_blocked(Uid, Ouid) ->
    {ok, Res} = q(["SISMEMBER", block_key(Uid), Ouid]),
    binary_to_integer(Res) == 1.


-spec is_blocked_by(Uid :: binary(), Ouid :: binary()) -> boolean().
is_blocked_by(Uid, Ouid) ->
    {ok, Res} = q(["SISMEMBER", reverse_block_key(Uid), Ouid]),
    binary_to_integer(Res) == 1.


%% Returns true if Uid blocked Ouid (or) if Uid is blocked by Ouid.
%% Checks if there is a block-relationship between these uids in any direction.
-spec is_blocked_any(Uid :: binary(), Ouid :: binary()) -> boolean().
is_blocked_any(Uid, Ouid) ->
    is_blocked(Uid, Ouid) orelse is_blocked_by(Uid, Ouid).


%%====================================================================
%% Internal functions.
%%====================================================================


-spec encode_feed_privacy_list_type(Type :: atom()) -> binary().
encode_feed_privacy_list_type(all) -> <<"f">>;
encode_feed_privacy_list_type(except) -> <<"b">>;
encode_feed_privacy_list_type(only) -> <<"w">>;
encode_feed_privacy_list_type(Type) -> erlang:error(badarg, [Type]).


-spec decode_feed_privacy_list_type(Value :: binary()) -> atom().
decode_feed_privacy_list_type(<<"f">>) -> all;
decode_feed_privacy_list_type(<<"b">>) -> except;
decode_feed_privacy_list_type(<<"w">>) -> only;
decode_feed_privacy_list_type(undefined) -> all. %% default option is all.


%%====================================================================
%% Internal redis functions.
%%====================================================================


q(Command) ->
    {ok, Result} = gen_server:call(redis_accounts_client, {q, Command}),
    Result.

qp(Commands) ->
    {ok, Results} = gen_server:call(redis_accounts_client, {qp, Commands}),
    Results.

whitelist_key(Uid) ->
    <<?WHITELIST_KEY/binary, <<"{">>/binary, Uid/binary, <<"}">>/binary>>.

blacklist_key(Uid) ->
    <<?BLACKLIST_KEY/binary, <<"{">>/binary, Uid/binary, <<"}">>/binary>>.

mute_key(Uid) ->
    <<?MUTE_KEY/binary, <<"{">>/binary, Uid/binary, <<"}">>/binary>>.

block_key(Uid) ->
    <<?BLOCK_KEY/binary, <<"{">>/binary, Uid/binary, <<"}">>/binary>>.

reverse_block_key(Uid) ->
    <<?REVERSE_BLOCK_KEY/binary, <<"{">>/binary, Uid/binary, <<"}">>/binary>>.

