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
    get_all_uids/0
]).

%%====================================================================
%% gen_mod callbacks
%%====================================================================

start(_Host, _Opts) ->
    ok.

stop(_Host) ->
    ok.

depends(_Host, _Opts) ->
    [{mod_redis, hard}].

mod_options(_Host) ->
    [].

%%====================================================================
%% API
%%====================================================================

-spec add_contact(Uid :: binary(), Contact :: binary()) -> ok  | {error, any()}.
add_contact(Uid, Contact) ->
    add_contacts(Uid, [Contact]).


-spec add_contacts(Uid :: binary(), ContactList :: [binary()]) -> ok  | {error, any()}.
add_contacts(_Uid, []) ->
    ok;
add_contacts(Uid, ContactList) ->
    {ok, _Res} = q(["SADD", contacts_key(Uid) | ContactList]),
    lists:foreach(
        fun(Contact) ->
            {ok, _} = q(["SADD", reverse_key(Contact), Uid])
        end, ContactList),
    ok.


-spec remove_contact(Uid :: binary(), Contact :: binary()) -> ok  | {error, any()}.
remove_contact(Uid, Contact) ->
    remove_contacts(Uid, [Contact]).


-spec remove_contacts(Uid :: binary(), ContactList :: [binary()]) -> ok  | {error, any()}.
remove_contacts(_Uid, []) ->
    ok;
remove_contacts(Uid, ContactList) ->
    {ok, _Res} = q(["SREM", contacts_key(Uid) | ContactList]),
    lists:foreach(
        fun(Contact) ->
            {ok, _} = q(["SREM", reverse_key(Contact), Uid])
        end, ContactList),
    ok.


-spec remove_all_contacts(Uid :: binary()) -> ok  | {error, any()}.
remove_all_contacts(Uid) ->
    {ok, ContactList} = q(["SMEMBERS", contacts_key(Uid)]),
    lists:foreach(
        fun(Contact) ->
            {ok, _} = q(["SREM", reverse_key(Contact), Uid])
        end, ContactList),
    {ok, _Res} = q(["DEL", contacts_key(Uid)]),
    ok.


-spec sync_contacts(Uid :: binary(), Sid :: binary(),
                    ContactList :: [binary()]) -> ok  | {error, any()}.
sync_contacts(_Uid, _Sid, []) ->
    ok;
sync_contacts(Uid, Sid, ContactList) ->
    {ok, _Res} = q(["SADD", sync_key(Uid, Sid) | ContactList]),
    ok.


-spec finish_sync(Uid :: binary(), Sid :: binary()) -> ok  | {error, any()}.
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
    {ok, _Res} = q(["RENAME", sync_key(Uid, Sid), contacts_key(Uid)]),
    ok.


-spec is_contact(Uid :: binary(), Contact :: binary()) -> boolean() | {error, any()}.
is_contact(Uid, Contact) ->
    {ok, Res} = q(["SISMEMBER", contacts_key(Uid), Contact]),
    binary_to_integer(Res) == 1.


-spec get_contacts(Uid :: binary()) -> {ok, [binary()]} | {error, any()}.
get_contacts(Uid) ->
    {ok, Res} = q(["SMEMBERS", contacts_key(Uid)]),
    {ok, Res}.


-spec get_sync_contacts(Uid :: binary(), Sid :: binary()) -> {ok, [binary()]} | {error, any()}.
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

-spec get_all_uids() -> {ok, [binary()]} | {error, any()}.
get_all_uids() ->
    {ok, [Cursor, Uids]} = q(["SCAN", "0", "COUNT", "1000"]),
    AllUids = get_all_uids(Cursor, Uids),
    {ok, AllUids}.

get_all_uids(<<"0">>, Results) ->
    Results;
get_all_uids(Cursor, Results) ->
    {ok, [NewCursor, Uids]} = q(["SCAN", Cursor, "COUNT", "1000"]),
    get_all_uids(NewCursor, lists:append(Uids, Results)).


q(Command) ->
    {ok, Result} = gen_server:call(redis_contacts_client, {q, Command}),
    Result.

qp(Commands) ->
    {ok, Result} = gen_server:call(redis_contacts_client, {qp, Commands}),
    Result.


-spec contacts_key(Uid :: binary()) -> binary().
contacts_key(Uid) ->
    <<?CONTACTS_KEY/binary, <<"{">>/binary, Uid/binary, <<"}">>/binary>>.


-spec sync_key(Uid :: binary(), Sid :: binary()) -> binary().
sync_key(Uid, Sid) ->
    <<?SYNC_KEY/binary, <<"{">>/binary, Uid/binary, <<"}:">>/binary, Sid/binary>>.

-spec reverse_key(Phone :: binary()) -> binary().
reverse_key(Phone) ->
    <<?REVERSE_KEY/binary, <<"{">>/binary, Phone/binary, <<"}">>/binary>>.

