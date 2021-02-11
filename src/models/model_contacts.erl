%%%------------------------------------------------------------------------------------
%%% File: model_contacts.erl
%%% Copyright (C) 2020, HalloApp, Inc.
%%%
%%% This model handles all the redis db queries that are related with contacts.
%%%
%%%------------------------------------------------------------------------------------
-module(model_contacts).
-author("murali").
-behavior(gen_mod).

-include("logger.hrl").
-include("redis_keys.hrl").
-include("ha_types.hrl").
-include("contacts.hrl").

%% Export all functions for unit tests
-ifdef(TEST).
-compile(export_all).
-endif.

%% gen_mod callbacks
-export([start/2, stop/1, depends/2, mod_options/1]).

-export([contacts_key/1, sync_key/2, reverse_key/1]).


%% API
-export([
    add_contact/2,
    add_contacts/2,
    add_reverse_hash_contact/2,
    add_reverse_hash_contacts/2,
    remove_contact/2,
    remove_contacts/2,
    remove_all_contacts/1,
    sync_contacts/3,
    finish_sync/2,
    is_contact/2,
    get_contacts/1,
    get_sync_contacts/2,
    get_contact_uids/1,
    get_contact_uids_size/1,
    get_potential_reverse_contact_uids/1,
    hash_phone/1,
    get_contact_hash_salt/0,
    add_not_invited_phone/1,
    get_not_invited_phones/0
]).

%%====================================================================
%% gen_mod callbacks
%%====================================================================

start(_Host, _Opts) ->
    create_ets_options_table(),
    fetch_and_store_salt(),
     % Making sure we have salt
    {ok, _Salt} = model_contacts:get_contact_hash_salt(),
    ok.

stop(_Host) ->
    ok.

depends(_Host, _Opts) ->
    [{mod_redis, hard},
     {mod_aws, hard}].

mod_options(_Host) ->
    [].

%%====================================================================
%% API
%%====================================================================

-spec add_contact(Uid :: uid(), Contact :: binary()) -> ok  | {error, any()}.
add_contact(Uid, Contact) ->
    add_contacts(Uid, [Contact]).


-spec add_contacts(Uid :: uid(), ContactList :: [binary()]) -> ok  | {error, any()}.
add_contacts(_Uid, []) ->
    ok;
add_contacts(Uid, ContactList) ->
    {ok, _Res} = q(["SADD", contacts_key(Uid) | ContactList]),
    lists:foreach(
        fun(Contact) ->
            {ok, _} = q(["SADD", reverse_key(Contact), Uid])
        end, ContactList),
    ok.


-spec add_reverse_hash_contact(Uid :: uid(), Contact :: binary()) -> ok | {error, any()}.
add_reverse_hash_contact(Uid, Contact) ->
    add_reverse_hash_contacts(Uid, [Contact]).


-spec add_reverse_hash_contacts(Uid :: uid(), ContactList :: [binary()]) -> ok | {error, any()}.
add_reverse_hash_contacts(Uid, ContactList) ->
    lists:foreach(
        fun(Contact) ->
            {ok, _} = q(["SADD", reverse_phone_hash_key(Contact), Uid])
        end, ContactList),
    ok.


-spec remove_contact(Uid :: uid(), Contact :: binary()) -> ok  | {error, any()}.
remove_contact(Uid, Contact) ->
    remove_contacts(Uid, [Contact]).


-spec remove_contacts(Uid :: uid(), ContactList :: [binary()]) -> ok  | {error, any()}.
remove_contacts(_Uid, []) ->
    ok;
remove_contacts(Uid, ContactList) ->
    {ok, _Res} = q(["SREM", contacts_key(Uid) | ContactList]),
    lists:foreach(
        fun(Contact) ->
            {ok, _} = q(["SREM", reverse_key(Contact), Uid])
        end, ContactList),
    ok.


-spec remove_all_contacts(Uid :: uid()) -> ok  | {error, any()}.
remove_all_contacts(Uid) ->
    {ok, ContactList} = q(["SMEMBERS", contacts_key(Uid)]),
    lists:foreach(
        fun(Contact) ->
            {ok, _} = q(["SREM", reverse_key(Contact), Uid])
        end, ContactList),
    {ok, _Res} = q(["DEL", contacts_key(Uid)]),
    ok.


-spec sync_contacts(Uid :: uid(), Sid :: binary(),
                    ContactList :: [binary()]) -> ok  | {error, any()}.
sync_contacts(_Uid, _Sid, []) ->
    ok;
sync_contacts(Uid, Sid, ContactList) ->
    [{ok, _Res}, {ok, _}] = qp([
            ["SADD", sync_key(Uid, Sid) | ContactList],
            ["EXPIRE", sync_key(Uid, Sid), ?SYNC_KEY_TTL]]),
    ok.


-spec finish_sync(Uid :: uid(), Sid :: binary()) -> ok  | {error, any()}.
finish_sync(Uid, Sid) ->
    {ok, RemovedContactList} = q(["SDIFF", contacts_key(Uid), sync_key(Uid, Sid)]),
    {ok, AddedContactList} = q(["SDIFF", sync_key(Uid, Sid), contacts_key(Uid)]),
    lists:foreach(
        fun(Contact) ->
            {ok, _} = q(["SREM", reverse_key(Contact), Uid])
        end, RemovedContactList),
    lists:foreach(
        fun(Contact) ->
            {ok, _} = q(["SADD", reverse_key(Contact), Uid])
        end, AddedContactList),
    %% Empty contact sync should still work fine, so check if sync_key exists or not.
    {ok, _Res} = case q(["EXISTS", sync_key(Uid, Sid)]) of
        {ok, <<"0">>} -> q(["DEL", contacts_key(Uid)]);
        {ok, <<"1">>} -> q(["RENAME", sync_key(Uid, Sid), contacts_key(Uid)])
    end,
    ok.


-spec is_contact(Uid :: uid(), Contact :: binary()) -> boolean() | {error, any()}.
is_contact(Uid, Contact) ->
    {ok, Res} = q(["SISMEMBER", contacts_key(Uid), Contact]),
    binary_to_integer(Res) == 1.


-spec get_contacts(Uid :: uid()) -> {ok, [binary()]} | {error, any()}.
get_contacts(Uid) ->
    {ok, Res} = q(["SMEMBERS", contacts_key(Uid)]),
    {ok, Res}.


-spec get_sync_contacts(Uid :: uid(), Sid :: binary()) -> {ok, [binary()]} | {error, any()}.
get_sync_contacts(Uid, Sid) ->
    {ok, Res} = q(["SMEMBERS", sync_key(Uid, Sid)]),
    {ok, Res}.


-spec get_contact_uids(Contact :: binary()) -> {ok, [binary()]} | {error, any()}.
get_contact_uids(Contact) ->
    {ok, Res} = q(["SMEMBERS", reverse_key(Contact)]),
    {ok, Res}.

-spec get_contact_uids_size(Contact :: binary()) -> non_neg_integer() | {error, any()}.
get_contact_uids_size(Contact) ->
    {ok, Res} = q(["SCARD", reverse_key(Contact)]),
    binary_to_integer(Res).


-spec get_potential_reverse_contact_uids(Contact :: binary()) -> {ok, [binary()]} | {error, any()}.
get_potential_reverse_contact_uids(Contact) ->
    {ok, Res} = q(["SMEMBERS", reverse_phone_hash_key(Contact)]),
    {ok, Res}.


% Returns true if this is the first time this phone was marked.
-spec add_not_invited_phone(Phone :: binary()) -> boolean().
add_not_invited_phone(Phone) ->
    TimestampMs = util:now_ms(),
    {ok, Res} = q(["ZADD", not_invited_phones_key(), TimestampMs, Phone]),
    cleanup_not_invited_phones(TimestampMs - 30 * ?DAYS_MS),
    binary_to_integer(Res) =:= 1.


-spec get_not_invited_phones() -> [{binary(), non_neg_integer()}].
get_not_invited_phones() ->
    {ok, Res} = q(["ZRANGEBYSCORE", not_invited_phones_key(), "-inf", "+inf", "WITHSCORES"]),
    util_redis:parse_zrange_with_scores(Res).


-spec cleanup_not_invited_phones(MinScore :: integer()) -> NumRemoved :: non_neg_integer().
cleanup_not_invited_phones(MinScore) ->
    {ok, Res} = q(["ZREMRANGEBYSCORE", not_invited_phones_key(), "-inf", MinScore]),
    binary_to_integer(Res).


%%====================================================================
%% Internal functions
%%====================================================================

-spec create_ets_options_table() -> atom().
create_ets_options_table() ->
    ets:new(contact_options, [named_table, set, public, {read_concurrency, true}]).


-spec fetch_and_store_salt() -> ok.
fetch_and_store_salt() ->
    Salt = get_salt_secret_from_aws(),
    ets:insert(contact_options, {contact_hash_salt, Salt}),
    ok.


-spec get_salt_secret_from_aws() -> binary().
get_salt_secret_from_aws() ->
    SecretString = binary_to_list(mod_aws:get_secret(<<"contact_hash_salt">>)),
    Salt = string:trim(SecretString),
    list_to_binary(Salt).


q(Command) -> ecredis:q(ecredis_contacts, Command).
qp(Commands) -> ecredis:qp(ecredis_contacts, Commands).


-spec contacts_key(Uid :: uid()) -> binary().
contacts_key(Uid) ->
    <<?CONTACTS_KEY/binary, <<"{">>/binary, Uid/binary, <<"}">>/binary>>.


-spec sync_key(Uid :: uid(), Sid :: binary()) -> binary().
sync_key(Uid, Sid) ->
    <<?SYNC_KEY/binary, <<"{">>/binary, Uid/binary, <<"}:">>/binary, Sid/binary>>.


-spec reverse_key(Phone :: phone()) -> binary().
reverse_key(Phone) ->
    <<?REVERSE_KEY/binary, <<"{">>/binary, Phone/binary, <<"}">>/binary>>.


-spec reverse_phone_hash_key(Phone :: phone()) -> binary().
reverse_phone_hash_key(Phone) ->
    SqueezedPhoneHash = hash_phone(Phone),
    <<?PHONE_HASH_KEY/binary, "{", SqueezedPhoneHash/binary, "}">>.

not_invited_phones_key() ->
    <<?NOT_INVITED_PHONES_KEY/binary>>.

-spec hash_phone(Phone :: phone()) -> binary().
hash_phone(Phone) ->
    SqueezedPhone = integer_to_binary(binary_to_integer(Phone) bsr ?SQUEEZE_LENGTH_BITS),
    {ok, Salt} = get_contact_hash_salt(),
    SaltedSqueezedPhone = <<SqueezedPhone/binary, Salt/binary>>,
    <<HashKey:?STORE_HASH_LENGTH_BYTES/binary, _Rest/binary>> = crypto:hash(sha256, SaltedSqueezedPhone),
    base64url:encode(HashKey).


-spec get_contact_hash_salt() -> {ok, binary()} | {error, any()}.
get_contact_hash_salt() ->
    case config:get_hallo_env() of
        prod ->
            Result = ets:lookup_element(contact_options, contact_hash_salt, 2),
            {ok, Result};
        _ ->
            {ok, ?DUMMY_SALT}
    end.

