%%%-----------------------------------------------------------------------------------
%%% File    : model_privacy.erl
%%%
%%% Copyright (C) 2020 halloappinc.
%%%
%%%
%%%-----------------------------------------------------------------------------------
-module(model_privacy).
-author('murali').

-include("logger.hrl").
-include("redis_keys.hrl").
-include("ha_types.hrl").

-ifdef(TEST).
-export([
    mute_key/1,
    except_key/1,
    only_key/1,
    block_key/1,
    reverse_block_key/1,
    mute_phone_key/1,
    except_phone_key/1,
    only_phone_key/1,
    block_phone_key/1,
    block_uid_key/1,
    reverse_block_phone_key/1,
    reverse_block_uid_key/1
    ]).
-endif.

%% API
-export([
    set_privacy_type/2,
    get_privacy_type/1,
    get_privacy_type_atom/1,
    %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
    %%% Old API
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
    %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
    remove_user/2,
    register_user/2,

    %% New API -- the functions ending with `2` are the newer versions and should be used instead of the old ones.
    add_only_phone/2,
    add_only_phones/2,
    add_except_phone/2,
    add_except_phones/2,
    mute_phone/2,
    mute_phones/2,
    block_phone/2,
    block_phones/2,
    remove_only_phone/2,
    remove_only_phones/2,
    remove_except_phone/2,
    remove_except_phones/2,
    unmute_phone/2,
    unmute_phones/2,
    unblock_phone/2,
    unblock_phones/2,
    get_only_phones/1,
    get_except_phones/1,
    get_mutelist_phones/1,
    get_blocked_phones/1,
    get_blocked_uids2/1,
    get_blocked_by_uids2/1,
    get_blocked_by_uids_phone/1,
    is_blocked2/2,
    is_blocked_by2/2,
    is_blocked_any2/2,
    is_only_phone/2,
    is_except_phone/2
]).

-dialyzer({no_match, block_uids2/2}).
-dialyzer({no_match, unblock_uids2/2}).

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
    AddCommands = lists:map(fun(Ouid) -> ["SADD", reverse_block_key(Ouid), Uid] end, Ouids),
    qmn(AddCommands),
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
    ReverseCommands = lists:map(fun(Ouid) -> ["SREM", reverse_block_key(Ouid), Uid] end, Ouids),
    qmn(ReverseCommands),
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


-spec remove_user(Uid :: uid(), Phone :: phone()) -> ok.
remove_user(Uid, Phone) ->
    {ok, Ouids} = get_blocked_by_uids2(Uid),
    %% Removing this Uid from other uid's reverse block indices.
    %% We are still keeping this user's phone number in other users block lists.
    %% We remove the uid from these block indices since that Uid is no longer valid.
    lists:foreach(fun (Ouid) ->
            unblock_uids2(Ouid, [Uid])
        end, Ouids),
    {ok, _Res} = q(["DEL", only_key(Uid), except_key(Uid), mute_key(Uid),
            only_phone_key(Uid), except_phone_key(Uid), mute_phone_key(Uid),
            block_key(Uid), reverse_block_key(Uid), block_uid_key(Uid), reverse_block_uid_key(Uid)]),
    {ok, _Res2} = q(["DEL", reverse_block_phone_key(Phone)]),
    ok.


-spec register_user(Uid :: uid(), Phone :: phone()) -> ok.
register_user(Uid, Phone) ->
    {ok, Ouids} = get_blocked_by_uids_phone(Phone),
    %% We add this new Uid to all these Ouids block indices.
    %% We are still keeping this phone number in other users block lists.
    lists:foreach(fun (Ouid) ->
            block_uids2(Ouid, [Uid])
        end, Ouids),
    ok.


-spec add_only_phone(Uid :: uid(), Phone :: phone()) -> ok.
add_only_phone(Uid, Phone) ->
    add_only_phones(Uid, [Phone]).


-spec add_only_phones(Uid :: uid(), Phones :: list(phone())) -> ok.
add_only_phones(_Uid, []) -> ok;
add_only_phones(Uid, Phones) ->
    {ok, _Res1} = q(["SADD", only_phone_key(Uid) | Phones]),
    %% Temp: Remove old key.
    {ok, _} = q(["DEL", only_key(Uid)]),
    ok.


-spec add_except_phone(Uid :: uid(), Phone :: phone()) -> ok.
add_except_phone(Uid, Phone) ->
    add_except_phones(Uid, [Phone]).


-spec add_except_phones(Uid :: uid(), Phones :: list(phone())) -> ok.
add_except_phones(_Uid, []) -> ok;
add_except_phones(Uid, Phones) ->
    {ok, _Res1} = q(["SADD", except_phone_key(Uid) | Phones]),
    %% Temp: Remove old key.
    {ok, _} = q(["DEL", except_key(Uid)]),
    ok.


-spec mute_phone(Uid :: uid(), Phone :: phone()) -> ok.
mute_phone(Uid, Phone) ->
    mute_phones(Uid, [Phone]).


-spec mute_phones(Uid :: uid(), Phones :: list(phone())) -> ok.
mute_phones(_Uid, []) -> ok;
mute_phones(Uid, Phones) ->
    {ok, _Res} = q(["SADD", mute_phone_key(Uid) | Phones]),
    %% Temp: Remove old key.
    {ok, _} = q(["DEL", mute_key(Uid)]),
    ok.


-spec block_phone(Uid :: uid(), Phone :: uid()) -> ok.
block_phone(Uid, Phone) ->
    block_phones(Uid, [Phone]).


-spec block_phones(Uid :: uid(), Phones :: list(phone())) -> ok.
block_phones(_Uid, []) -> ok;
block_phones(Uid, Phones) ->
    Ouids = maps:values(model_phone:get_uids(Phones, halloapp)),
    PhoneCommands = lists:map(fun(Phone) -> ["SADD", block_phone_key(Uid), Phone] end, Phones),
    UidCommands = lists:map(fun(Ouid) -> ["SADD", block_uid_key(Uid), Ouid] end, Ouids),
    AddPhoneCommands = lists:map(fun(Phone) -> ["SADD", reverse_block_phone_key(Phone), Uid] end, Phones),
    AddUidCommands = lists:map(fun(Ouid) -> ["SADD", reverse_block_uid_key(Ouid), Uid] end, Ouids),
    _Results = qp(PhoneCommands ++ UidCommands),
    qmn(AddPhoneCommands ++ AddUidCommands),

    %% Temp: Remove old keys.
    {ok, OldOuids} = get_blocked_uids(Uid),
    unblock_uids(Uid, OldOuids),
    ok.


-spec block_uids2(Uid :: uid(), Ouid :: list(uid())) -> ok.
block_uids2(_Uid, []) -> ok;
block_uids2(Uid, Ouids) ->
    {ok, _Res} = q(["SADD", block_uid_key(Uid) | Ouids]),
    ReverseCommands = lists:map(fun(Ouid) -> ["SADD", reverse_block_uid_key(Ouid), Uid] end, Ouids),
    qmn(ReverseCommands),
    ok.


-spec remove_only_phone(Uid :: uid(), Phone :: phone()) -> ok.
remove_only_phone(Uid, Phone) ->
    remove_only_phones(Uid, [Phone]).


-spec remove_only_phones(Uid :: uid(), Phones :: list(phone())) -> ok.
remove_only_phones(_Uid, []) -> ok;
remove_only_phones(Uid, Phones) ->
    {ok, _Res1} = q(["SREM", only_phone_key(Uid) | Phones]),
    ok.


-spec remove_except_phone(Uid :: uid(), Phone :: phone()) -> ok.
remove_except_phone(Uid, Phone) ->
    remove_except_phones(Uid, [Phone]).


-spec remove_except_phones(Uid :: uid(), Phones :: list(phone())) -> ok.
remove_except_phones(_Uid, []) -> ok;
remove_except_phones(Uid, Phones) ->
    {ok, _Res1} = q(["SREM", except_phone_key(Uid) | Phones]),
    ok.


-spec unmute_phone(Uid :: uid(), Phone :: phone()) -> ok.
unmute_phone(Uid, Phone) ->
    unmute_phones(Uid, [Phone]).


-spec unmute_phones(Uid :: uid(), Phones :: list(phone())) -> ok.
unmute_phones(_Uid, []) -> ok;
unmute_phones(Uid, Phones) ->
    {ok, _Res} = q(["SREM", mute_phone_key(Uid) | Phones]),
    ok.


-spec unblock_phone(Uid :: uid(), Phone :: phone()) -> ok.
unblock_phone(Uid, Phone) ->
    unblock_phones(Uid, [Phone]).


-spec unblock_phones(Uid :: uid(), Phones :: list(phone())) -> ok.
unblock_phones(_Uid, []) -> ok;
unblock_phones(Uid, Phones) ->
    Ouids = maps:values(model_phone:get_uids(Phones, halloapp)),
    PhoneCommands = lists:map(fun(Phone) -> ["SREM", block_phone_key(Uid), Phone] end, Phones),
    UidCommands = lists:map(fun(Ouid) -> ["SREM", block_uid_key(Uid), Ouid] end, Ouids),
    ReversePhoneCommands = lists:map(fun(Phone) -> ["SREM", reverse_block_phone_key(Phone), Uid] end, Phones),
    ReverseUidCommands = lists:map(fun(Ouid) -> ["SREM", reverse_block_uid_key(Ouid), Uid] end, Ouids),
    _Results = qp(PhoneCommands ++ UidCommands),
    qmn(ReversePhoneCommands ++ ReverseUidCommands),

    %% Temp: Remove old keys.
    {ok, OldOuids} = get_blocked_uids(Uid),
    unblock_uids(Uid, OldOuids),
    ok.


-spec unblock_uids2(Uid :: uid(), Ouid :: list(uid())) -> ok.
unblock_uids2(_Uid, []) -> ok;
unblock_uids2(Uid, Ouids) ->
    {ok, _Res} = q(["SREM", block_uid_key(Uid) | Ouids]),
    ReverseCommands = lists:map(fun(Ouid) -> ["SREM", reverse_block_uid_key(Ouid), Uid] end, Ouids),
    qmn(ReverseCommands),
    ok.

-spec get_only_phones(Uid :: uid()) -> {ok, list(phone())}.
get_only_phones(Uid) ->
    {ok, Res1} = q(["SMEMBERS", only_phone_key(Uid)]),
    {ok, Res1}.


-spec get_except_phones(Uid :: uid()) -> {ok, list(phone())}.
get_except_phones(Uid) ->
    {ok, Res1} = q(["SMEMBERS", except_phone_key(Uid)]),
    {ok, Res1}.


-spec get_mutelist_phones(Uid :: uid()) -> {ok, list(phone())}.
get_mutelist_phones(Uid) ->
    {ok, Res} = q(["SMEMBERS", mute_phone_key(Uid)]),
    {ok, Res}.


-spec get_blocked_phones(Uid :: uid()) -> {ok, list(phone())}.
get_blocked_phones(Uid) ->
    {ok, Res} = q(["SMEMBERS", block_phone_key(Uid)]),
    {ok, Res}.


-spec get_blocked_uids2(Uid :: uid()) -> {ok, list(binary())}.
get_blocked_uids2(Uid) ->
    [{ok, Res1}, {ok, Res2}] = qp([
        ["SMEMBERS", block_key(Uid)],
        ["SMEMBERS", block_uid_key(Uid)]]),
    case {Res1, Res2} of
        %% If old-key's value is empty: switch to new key.
        {[], _} -> {ok, Res2};
        %% Otherwise: use old key's value.
        {_, _} -> {ok, Res1}
    end.


-spec get_blocked_by_uids2(Uid :: uid()) -> {ok, list(binary())}.
get_blocked_by_uids2(Uid) ->
    [{ok, Res1}, {ok, Res2}] = qp([
        ["SMEMBERS", reverse_block_key(Uid)],
        ["SMEMBERS", reverse_block_uid_key(Uid)]]),
    %% Combine values from both keys.
    {ok, sets:to_list(sets:from_list(Res1 ++ Res2))}.


-spec get_blocked_by_uids_phone(Phone :: phone()) -> {ok, list(binary())}.
get_blocked_by_uids_phone(Phone) ->
    {ok, Res} = q(["SMEMBERS", reverse_block_phone_key(Phone)]),
    {ok, Res}.


-spec is_blocked2(Uid :: uid(), Ouid :: uid()) -> boolean().
is_blocked2(Uid, Ouid) ->
    [{ok, Res1}, {ok, Res2}] = qp([
        ["SISMEMBER", block_key(Uid), Ouid],
        ["SISMEMBER", block_uid_key(Uid), Ouid]]),
    Res1 =:= <<"1">> orelse Res2 =:= <<"1">>.


-spec is_blocked_by2(Uid :: uid(), Ouid :: uid()) -> boolean().
is_blocked_by2(Uid, Ouid) ->
    [{ok, Res1}, {ok, Res2}] = qp([
        ["SISMEMBER", reverse_block_key(Uid), Ouid],
        ["SISMEMBER", reverse_block_uid_key(Uid), Ouid]]),
    Res1 =:= <<"1">> orelse Res2 =:= <<"1">>.


%% Returns true if Uid blocked Ouid (or) if Uid is blocked by Ouid.
%% Checks if there is a block-relationship between these uids in any direction.
-spec is_blocked_any2(Uid :: uid(), Ouid :: uid()) -> boolean().
is_blocked_any2(Uid, Ouid) ->
    is_blocked2(Uid, Ouid) orelse is_blocked_by2(Uid, Ouid).


-spec is_only_phone(Uid :: uid(), Phone :: phone()) -> boolean().
is_only_phone(Uid, Phone) ->
    {ok, Res1} = q(["SISMEMBER", only_phone_key(Uid), Phone]),
    binary_to_integer(Res1) == 1.


-spec is_except_phone(Uid :: uid(), Phone :: phone()) -> boolean().
is_except_phone(Uid, Phone) ->
    {ok, Res1} = q(["SISMEMBER", except_phone_key(Uid), Phone]),
    binary_to_integer(Res1) == 1.

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
qmn(Commands) -> util_redis:run_qmn(ecredis_accounts, Commands).


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


only_phone_key(Uid) ->
    <<?ONLY_PHONE_KEY/binary, <<"{">>/binary, Uid/binary, <<"}">>/binary>>.

except_phone_key(Uid) ->
    <<?EXCEPT_PHONE_KEY/binary, <<"{">>/binary, Uid/binary, <<"}">>/binary>>.

mute_phone_key(Uid) ->
    <<?MUTE_PHONE_KEY/binary, <<"{">>/binary, Uid/binary, <<"}">>/binary>>.

block_phone_key(Uid) ->
    <<?BLOCK_PHONE_KEY/binary, <<"{">>/binary, Uid/binary, <<"}">>/binary>>.

reverse_block_phone_key(Phone) ->
    <<?REVERSE_BLOCK_PHONE_KEY/binary, <<"{">>/binary, Phone/binary, <<"}">>/binary>>.

block_uid_key(Uid) ->
    <<?BLOCK_UID_KEY/binary, <<"{">>/binary, Uid/binary, <<"}">>/binary>>.

reverse_block_uid_key(Uid) ->
    <<?REVERSE_BLOCK_UID_KEY/binary, <<"{">>/binary, Uid/binary, <<"}">>/binary>>.

