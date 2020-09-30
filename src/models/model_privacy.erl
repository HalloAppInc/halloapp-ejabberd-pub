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
-include("ha_types.hrl").

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
    add_only_uid/2,
    add_only_uids/2,
    add_except_uid/2,
    add_except_uids/2,
    mute_uid/2,
    mute_uids/2,
    block_uid/2,
    block_uids/2,
    remove_only_uid/2,
    remove_only_uids/2,
    remove_except_uid/2,
    remove_except_uids/2,
    unmute_uid/2,
    unmute_uids/2,
    unblock_uid/2,
    unblock_uids/2,
    get_only_uids/1,
    get_except_uids/1,
    get_mutelist_uids/1,
    get_blocked_uids/1,
    get_blocked_by_uids/1,
    is_only_uid/2,
    is_except_uid/2,
    is_blocked/2,
    is_blocked_by/2,
    is_blocked_any/2,
    remove_user/1
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


-spec set_privacy_type(Uid :: uid(), Type :: atom()) -> ok.
set_privacy_type(Uid, Type) ->
    Value = encode_feed_privacy_list_type(Type),
    {ok, _Res} = q(["HSET", model_accounts:account_key(Uid), ?FIELD_PRIVACY_LIST_TYPE, Value]),
    ok.


-spec get_privacy_type(Uid :: uid()) -> {ok, atom()} | {error, any()}.
get_privacy_type(Uid) ->
    {ok, Res} = q(["HGET", model_accounts:account_key(Uid), ?FIELD_PRIVACY_LIST_TYPE]),
    {ok, decode_feed_privacy_list_type(Res)}.


-spec get_privacy_type_atom(Uid :: uid()) -> atom() | {error, any()}.
get_privacy_type_atom(Uid) ->
    {ok, Res} = get_privacy_type(Uid),
    Res.


-spec add_only_uid(Uid :: uid(), Ouid :: uid()) -> ok.
add_only_uid(Uid, Ouid) ->
    add_only_uids(Uid, [Ouid]).


-spec add_only_uids(Uid :: uid(), Ouid :: list(uid())) -> ok.
add_only_uids(_Uid, []) -> ok;
add_only_uids(Uid, Ouids) ->
    {ok, _Res1} = q(["SADD", only_key(Uid) | Ouids]),
    ok.


-spec add_except_uid(Uid :: uid(), Ouid :: uid()) -> ok.
add_except_uid(Uid, Ouid) ->
    add_except_uids(Uid, [Ouid]).


-spec add_except_uids(Uid :: uid(), Ouid :: list(uid())) -> ok.
add_except_uids(_Uid, []) -> ok;
add_except_uids(Uid, Ouids) ->
    {ok, _Res1} = q(["SADD", except_key(Uid) | Ouids]),
    ok.


-spec mute_uid(Uid :: uid(), Ouid :: uid()) -> ok.
mute_uid(Uid, Ouid) ->
    mute_uids(Uid, [Ouid]).


-spec mute_uids(Uid :: uid(), Ouid :: list(uid())) -> ok.
mute_uids(_Uid, []) -> ok;
mute_uids(Uid, Ouids) ->
    {ok, _Res} = q(["SADD", mute_key(Uid) | Ouids]),
    ok.


-spec block_uid(Uid :: uid(), Ouid :: uid()) -> ok.
block_uid(Uid, Ouid) ->
    block_uids(Uid, [Ouid]).


-spec block_uids(Uid :: uid(), Ouid :: list(uid())) -> ok.
block_uids(_Uid, []) -> ok;
block_uids(Uid, Ouids) ->
    BlockKey = block_key(Uid),
    Commands = lists:map(fun(Ouid) -> ["SADD", BlockKey, Ouid] end, Ouids),
    _Results = qp(Commands),
    lists:foreach(fun(Ouid) -> q(["SADD", reverse_block_key(Ouid), Uid]) end, Ouids),
    ok.


-spec remove_only_uid(Uid :: uid(), Ouid :: uid()) -> ok.
remove_only_uid(Uid, Ouid) ->
    remove_only_uids(Uid, [Ouid]).


-spec remove_only_uids(Uid :: uid(), Ouid :: list(uid())) -> ok.
remove_only_uids(_Uid, []) -> ok;
remove_only_uids(Uid, Ouids) ->
    {ok, _Res1} = q(["SREM", only_key(Uid) | Ouids]),
    ok.


-spec remove_except_uid(Uid :: uid(), Ouid :: uid()) -> ok.
remove_except_uid(Uid, Ouid) ->
    remove_except_uids(Uid, [Ouid]).


-spec remove_except_uids(Uid :: uid(), Ouid :: list(uid())) -> ok.
remove_except_uids(_Uid, []) -> ok;
remove_except_uids(Uid, Ouids) ->
    {ok, _Res1} = q(["SREM", except_key(Uid) | Ouids]),
    ok.


-spec unmute_uid(Uid :: uid(), Ouid :: uid()) -> ok.
unmute_uid(Uid, Ouid) ->
    unmute_uids(Uid, [Ouid]).


-spec unmute_uids(Uid :: uid(), Ouid :: list(uid())) -> ok.
unmute_uids(_Uid, []) -> ok;
unmute_uids(Uid, Ouids) ->
    {ok, _Res} = q(["SREM", mute_key(Uid) | Ouids]),
    ok.


-spec unblock_uid(Uid :: uid(), Ouid :: uid()) -> ok.
unblock_uid(Uid, Ouid) ->
    unblock_uids(Uid, [Ouid]).


-spec unblock_uids(Uid :: uid(), Ouid :: list(uid())) -> ok.
unblock_uids(_Uid, []) -> ok;
unblock_uids(Uid, Ouids) ->
    {ok, _Res} = q(["SREM", block_key(Uid) | Ouids]),
    lists:foreach(fun(Ouid) -> q(["SREM", reverse_block_key(Ouid), Uid]) end, Ouids),
    ok.

-spec get_only_uids(Uid :: uid()) -> {ok, list(binary())}.
get_only_uids(Uid) ->
    {ok, Res1} = q(["SMEMBERS", only_key(Uid)]),
    {ok, Res1}.


-spec get_except_uids(Uid :: uid()) -> {ok, list(binary())}.
get_except_uids(Uid) ->
    {ok, Res1} = q(["SMEMBERS", except_key(Uid)]),
    {ok, Res1}.


-spec get_mutelist_uids(Uid :: uid()) -> {ok, list(binary())}.
get_mutelist_uids(Uid) ->
    {ok, Res} = q(["SMEMBERS", mute_key(Uid)]),
    {ok, Res}.


-spec get_blocked_uids(Uid :: uid()) -> {ok, list(binary())}.
get_blocked_uids(Uid) ->
    {ok, Res} = q(["SMEMBERS", block_key(Uid)]),
    {ok, Res}.


-spec get_blocked_by_uids(Uid :: uid()) -> {ok, list(binary())}.
get_blocked_by_uids(Uid) ->
    {ok, Res} = q(["SMEMBERS", reverse_block_key(Uid)]),
    {ok, Res}.


-spec is_only_uid(Uid :: uid(), Ouid :: uid()) -> boolean().
is_only_uid(Uid, Ouid) ->
    {ok, Res1} = q(["SISMEMBER", only_key(Uid), Ouid]),
    binary_to_integer(Res1) == 1.


-spec is_except_uid(Uid :: uid(), Ouid :: uid()) -> boolean().
is_except_uid(Uid, Ouid) ->
    {ok, Res1} = q(["SISMEMBER", except_key(Uid), Ouid]),
    binary_to_integer(Res1) == 1.


-spec is_blocked(Uid :: uid(), Ouid :: uid()) -> boolean().
is_blocked(Uid, Ouid) ->
    {ok, Res} = q(["SISMEMBER", block_key(Uid), Ouid]),
    binary_to_integer(Res) == 1.


-spec is_blocked_by(Uid :: uid(), Ouid :: uid()) -> boolean().
is_blocked_by(Uid, Ouid) ->
    {ok, Res} = q(["SISMEMBER", reverse_block_key(Uid), Ouid]),
    binary_to_integer(Res) == 1.


%% Returns true if Uid blocked Ouid (or) if Uid is blocked by Ouid.
%% Checks if there is a block-relationship between these uids in any direction.
-spec is_blocked_any(Uid :: uid(), Ouid :: uid()) -> boolean().
is_blocked_any(Uid, Ouid) ->
    is_blocked(Uid, Ouid) orelse is_blocked_by(Uid, Ouid).


-spec remove_user(Uid :: uid()) -> ok.
remove_user(Uid) ->
    {ok, _Res} = q(["DEL", only_key(Uid), except_key(Uid), mute_key(Uid),
            block_key(Uid), reverse_block_key(Uid)]),
    ok.


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


q(Command) -> ecredis:q(ecredis_accounts, Command).
qp(Commands) -> ecredis:qp(ecredis_accounts, Commands).


only_key(Uid) ->
    <<?ONLY_KEY/binary, <<"{">>/binary, Uid/binary, <<"}">>/binary>>.

except_key(Uid) ->
    <<?EXCEPT_KEY/binary, <<"{">>/binary, Uid/binary, <<"}">>/binary>>.

mute_key(Uid) ->
    <<?MUTE_KEY/binary, <<"{">>/binary, Uid/binary, <<"}">>/binary>>.

block_key(Uid) ->
    <<?BLOCK_KEY/binary, <<"{">>/binary, Uid/binary, <<"}">>/binary>>.

reverse_block_key(Uid) ->
    <<?REVERSE_BLOCK_KEY/binary, <<"{">>/binary, Uid/binary, <<"}">>/binary>>.

