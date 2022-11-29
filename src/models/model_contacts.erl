%%%------------------------------------------------------------------------------------
%%% File: model_contacts.erl
%%% Copyright (C) 2020, HalloApp, Inc.
%%%
%%% This model handles all the redis db queries that are related with contacts.
%%%
%%%------------------------------------------------------------------------------------
-module(model_contacts).
-author("murali").

-include("logger.hrl").
-include("redis_keys.hrl").
-include("ha_types.hrl").
-include("contacts.hrl").

-ifdef(TEST).
-export([reverse_phone_hash_key/1]).
-endif.

-export([contacts_key/1, sync_key/2, reverse_key/2]).


%% API
-export([
    init/0,
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
    count_contacts/1,
    get_sync_contacts/2,
    count_sync_contacts/2,
    get_contact_uids/2,
    get_contact_uids_size/2,
    get_contacts_uids_size/2,
    get_potential_reverse_contact_uids/1,
    hash_phone/1,
    get_contact_hash_salt/0,
    add_not_invited_phone/1,
    get_not_invited_phones/0
]).

%%====================================================================
%% gen_mod callbacks
%%====================================================================

init() ->
    fetch_and_store_salt(),
     % Making sure we have salt
    {ok, _Salt} = model_contacts:get_contact_hash_salt(),
    ok.

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
    AppType = util_uid:get_app_type(Uid),
    {ok, _Res} = q(["SADD", contacts_key(Uid) | ContactList]),
    ReverseKeyCommands = lists:map(
        fun(Contact) ->
            ["SADD", reverse_key(Contact, AppType), Uid]
        end, ContactList),
    qmn(ReverseKeyCommands),
    ok.


-spec add_reverse_hash_contact(Uid :: uid(), Contact :: binary()) -> ok | {error, any()}.
add_reverse_hash_contact(Uid, Contact) ->
    add_reverse_hash_contacts(Uid, [Contact]).


-spec add_reverse_hash_contacts(Uid :: uid(), ContactList :: [binary()]) -> ok | {error, any()}.
add_reverse_hash_contacts(Uid, ContactList) ->
    Commands = lists:map(
        fun(Contact) ->
            ["SADD", reverse_phone_hash_key(Contact), Uid]
        end, ContactList),
    qmn(Commands),
    ok.


-spec remove_contact(Uid :: uid(), Contact :: binary()) -> ok  | {error, any()}.
remove_contact(Uid, Contact) ->
    remove_contacts(Uid, [Contact]).


-spec remove_contacts(Uid :: uid(), ContactList :: [binary()]) -> ok  | {error, any()}.
remove_contacts(_Uid, []) ->
    ok;
remove_contacts(Uid, ContactList) ->
    AppType = util_uid:get_app_type(Uid),
    {ok, _Res} = q(["SREM", contacts_key(Uid) | ContactList]),
    Commands = lists:map(
        fun(Contact) ->
            ["SREM", reverse_key(Contact, AppType), Uid]
        end, ContactList),
    qmn(Commands),
    ok.


-spec remove_all_contacts(Uid :: uid()) -> ok  | {error, any()}.
remove_all_contacts(Uid) ->
    AppType = util_uid:get_app_type(Uid),
    {ok, ContactList} = q(["SMEMBERS", contacts_key(Uid)]),
    Commands = lists:map(
        fun(Contact) ->
            ["SREM", reverse_key(Contact, AppType), Uid]
        end, ContactList),
    qmn(Commands),
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
    AppType = util_uid:get_app_type(Uid),
    case q(["PERSIST", sync_key(Uid, Sid)]) of
        {ok, <<"0">>} ->
            %% Can happen in rare case if the client takes 31 days to complete the sync.
            {error, expired_sync};
        {ok, <<"1">>} ->
            {ok, RemovedContactList} = q(["SDIFF", contacts_key(Uid), sync_key(Uid, Sid)]),
            {ok, AddedContactList} = q(["SDIFF", sync_key(Uid, Sid), contacts_key(Uid)]),
            ReverseKeyCommands1 = lists:map(
                fun(Contact) ->
                    ["SREM", reverse_key(Contact, AppType), Uid]
                end, RemovedContactList),
            ReverseKeyCommands2 = lists:map(
                fun(Contact) ->
                    ["SADD", reverse_key(Contact, AppType), Uid]
                end, AddedContactList),
            qmn(ReverseKeyCommands1 ++ ReverseKeyCommands2),

            %% Empty contact sync should still work fine, so check if sync_key exists or not.
            {ok, _Res} = case q(["EXISTS", sync_key(Uid, Sid)]) of
                {ok, <<"0">>} ->
                    q(["DEL", contacts_key(Uid)]);
                {ok, <<"1">>} ->
                    q(["RENAME", sync_key(Uid, Sid), contacts_key(Uid)])
            end,
            ok
    end.


-spec is_contact(Uid :: uid(), Contact :: binary()) -> boolean() | {error, any()}.
is_contact(Uid, Contact) ->
    {ok, Res} = q(["SISMEMBER", contacts_key(Uid), Contact]),
    binary_to_integer(Res) == 1.


-spec get_contacts(Uid :: uid() | [uid()]) -> {ok, [binary()]} | {ok, [[binary()]]} | {error, any()}.
get_contacts(Uids) when is_list(Uids) ->
    Commands = lists:map(
        fun(Uid) ->
            ["SMEMBERS", contacts_key(Uid)]
        end, Uids),
    Results = qmn(Commands),
    {ok, lists:map(fun({ok, Result}) -> Result end, Results)};
get_contacts(Uid) ->
    {ok, Res} = q(["SMEMBERS", contacts_key(Uid)]),
    {ok, Res}.


-spec count_contacts(Uid :: uid()) -> integer() | {error, any()}.
count_contacts(Uid) ->
    {ok, Res} = q(["SCARD", contacts_key(Uid)]),
    binary_to_integer(Res).


-spec get_sync_contacts(Uid :: uid(), Sid :: binary()) -> {ok, [binary()]} | {error, any()}.
get_sync_contacts(Uid, Sid) ->
    {ok, Res} = q(["SMEMBERS", sync_key(Uid, Sid)]),
    {ok, Res}.


-spec count_sync_contacts(Uid :: uid(), Sid :: binary()) -> {ok, integer()} | {error, any()}.
count_sync_contacts(Uid, Sid) ->
    {ok, Res} = q(["SCARD", sync_key(Uid, Sid)]),
    {ok, binary_to_integer(Res)}.


-spec get_contact_uids(Contact :: binary() | [binary()], AppType :: app_type()) -> {ok, [binary()] | map()} | {error, any()}.
get_contact_uids(Contacts, AppType) when is_list(Contacts) ->
    Commands = lists:map(
        fun (Contact) ->
            ["SMEMBERS", reverse_key(Contact, AppType)]
        end,
        Contacts),
    Res = qmn(Commands),
    Result = lists:foldl(
        fun ({Contact, {ok, RevContacts}}, Acc) ->
            Acc#{Contact => RevContacts}
        end, #{}, lists:zip(Contacts, Res)),
    {ok, Result};

get_contact_uids(Contact, AppType) ->
    {ok, Res} = q(["SMEMBERS", reverse_key(Contact, AppType)]),
    {ok, Res}.


-spec get_contact_uids_size(Contact :: binary(), AppType :: app_type()) -> non_neg_integer() | {error, any()}.
get_contact_uids_size(Contact, AppType) ->
    {ok, Res} = q(["SCARD", reverse_key(Contact, AppType)]),
    binary_to_integer(Res).


-spec get_contacts_uids_size(Contacts :: [binary()], AppType :: app_type()) -> map() | {error, any()}.
get_contacts_uids_size([], _AppType) -> #{};
get_contacts_uids_size(Contacts, AppType) ->
    Commands = lists:map(fun(Contact) -> ["SCARD", reverse_key(Contact, AppType)] end, Contacts),
    Res = qmn(Commands),
    Result = lists:foldl(
        fun({Contact, {ok, Size}}, Acc) ->
            case Size of
                <<"0">> -> Acc;
                _ -> Acc#{Contact => binary_to_integer(Size)}
            end
        end, #{}, lists:zip(Contacts, Res)),
    Result.


-spec get_potential_reverse_contact_uids(Contact :: binary()) -> {ok, [uid()]} | {error, any()}.
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


-spec fetch_and_store_salt() -> ok.
fetch_and_store_salt() ->
    Salt = get_salt_secret_from_aws(),
    ets:insert(?CONTACT_OPTIONS_TABLE, {contact_hash_salt, Salt}),
    ok.


-spec get_salt_secret_from_aws() -> binary().
get_salt_secret_from_aws() ->
    SecretString = binary_to_list(mod_aws:get_secret(<<"contact_hash_salt">>)),
    Salt = string:trim(SecretString),
    list_to_binary(Salt).


q(Command) -> ecredis:q(ecredis_contacts, Command).
qp(Commands) -> ecredis:qp(ecredis_contacts, Commands).
qmn(Commands) -> util_redis:run_qmn(ecredis_contacts, Commands).


-spec contacts_key(Uid :: uid()) -> binary().
contacts_key(Uid) ->
    <<?CONTACTS_KEY/binary, <<"{">>/binary, Uid/binary, <<"}">>/binary>>.


-spec sync_key(Uid :: uid(), Sid :: binary()) -> binary().
sync_key(Uid, Sid) ->
    <<?SYNC_KEY/binary, <<"{">>/binary, Uid/binary, <<"}:">>/binary, Sid/binary>>.


-spec reverse_key(Phone :: phone(), AppType :: app_type()) -> binary().
reverse_key(Phone, AppType) ->
    case AppType of
        halloapp -> <<?REVERSE_KEY/binary, <<"{">>/binary, Phone/binary, <<"}">>/binary>>;
        katchup -> <<?KATCHUP_REVERSE_KEY/binary, <<"{">>/binary, Phone/binary, <<"}">>/binary>>
    end.


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
            Result = ets:lookup_element(?CONTACT_OPTIONS_TABLE, contact_hash_salt, 2),
            {ok, Result};
        _ ->
            {ok, ?DUMMY_SALT}
    end.
