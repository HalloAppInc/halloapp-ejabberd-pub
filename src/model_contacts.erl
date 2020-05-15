%%%------------------------------------------------------------------------------------
%%% File: model_contacts.erl
%%% Copyright (C) 2020, HalloApp, Inc.
%%%
%%% This model handles all the redis db queries that are related with contacts.
%%%
%%%------------------------------------------------------------------------------------
-module(model_contacts).
-author("murali").
-behavior(gen_server).
-behavior(gen_mod).

-include("logger.hrl").

%% Export all functions for unit tests
-ifdef(TEST).
-compile(export_all).
-endif.

%% gen_mod callbacks
-export([start/2, stop/1, depends/2, mod_options/1]).
%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, terminate/2, handle_info/2, code_change/3]).

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

start_link() ->
    gen_server:start_link({local, get_proc()}, ?MODULE, [], []).

%%====================================================================
%% gen_mod callbacks
%%====================================================================

start(Host, Opts) ->
    gen_mod:start_child(?MODULE, Host, Opts, get_proc()).

stop(_Host) ->
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

-define(CONTACTS_KEY, <<"con:">>).
-define(SYNC_KEY, <<"sync:">>).
-define(REVERSE_KEY, <<"rev:">>).


-spec add_contact(Uid :: binary(), Contact :: binary()) -> ok  | {error, any()}.
add_contact(Uid, Contact) ->
    add_contacts(Uid, [Contact]).


-spec add_contacts(Uid :: binary(), ContactList :: [binary()]) -> ok  | {error, any()}.
add_contacts(Uid, ContactList) ->
    gen_server:call(get_proc(), {add_contacts, Uid, ContactList}).


-spec remove_contact(Uid :: binary(), Contact :: binary()) -> ok  | {error, any()}.
remove_contact(Uid, Contact) ->
    remove_contacts(Uid, [Contact]).


-spec remove_contacts(Uid :: binary(), ContactList :: [binary()]) -> ok  | {error, any()}.
remove_contacts(Uid, ContactList) ->
    gen_server:call(get_proc(), {remove_contacts, Uid, ContactList}).


-spec remove_all_contacts(Uid :: binary()) -> ok  | {error, any()}.
remove_all_contacts(Uid) ->
    gen_server:call(get_proc(), {remove_all_contacts, Uid}).


-spec sync_contacts(Uid :: binary(), Sid :: binary(),
                    ContactList :: [binary()]) -> ok  | {error, any()}.
sync_contacts(Uid, Sid, ContactList) ->
    gen_server:call(get_proc(), {sync_contacts, Uid, Sid, ContactList}).


-spec finish_sync(Uid :: binary(), Sid :: binary()) -> ok  | {error, any()}.
finish_sync(Uid, Sid) ->
    gen_server:call(get_proc(), {finish_sync, Uid, Sid}).


-spec is_contact(Uid :: binary(), Contact :: binary()) -> boolean() | {error, any()}.
is_contact(Uid, Contact) ->
    gen_server:call(get_proc(), {is_contact, Uid, Contact}).


-spec get_contacts(Uid :: binary()) -> {ok, [binary()]} | {error, any()}.
get_contacts(Uid) ->
    gen_server:call(get_proc(), {get_contacts, Uid}).


-spec get_sync_contacts(Uid :: binary(), Sid :: binary()) -> {ok, [binary()]} | {error, any()}.
get_sync_contacts(Uid, Sid) ->
    gen_server:call(get_proc(), {get_sync_contacts, Uid, Sid}).


-spec get_contact_uids(Contact :: binary()) -> {ok, [binary()]} | {error, any()}.
get_contact_uids(Contact) ->
    gen_server:call(get_proc(), {get_contact_uids, Contact}).

-spec get_contact_uids_size(Contact :: binary()) -> non_neg_integer() | {error, any()}.
get_contact_uids_size(Contact) ->
    gen_server:call(get_proc(), {get_contact_uids_size, Contact}).

-spec get_all_uids() -> {ok, [binary()]} | {error, any()}.
get_all_uids() ->
    gen_server:call(get_proc(), {get_all_uids}).

%%====================================================================
%% gen_server callbacks
%%====================================================================

init(_Stuff) ->
    process_flag(trap_exit, true),
    {ok, redis_contacts_client}.


handle_call({add_contacts, Uid, ContactList}, _From, Redis) ->
    {ok, _Res} = q(["SADD", contacts_key(Uid) | ContactList]),
    lists:foreach(fun(Contact) ->
                    {ok, _} = q(["SADD", reverse_key(Contact), Uid])
                  end, ContactList),
    {reply, ok, Redis};

handle_call({remove_contacts, Uid, ContactList}, _From, Redis) ->
    {ok, _Res} = q(["SREM", contacts_key(Uid) | ContactList]),
    lists:foreach(fun(Contact) ->
                    {ok, _} = q(["SREM", reverse_key(Contact), Uid])
                  end, ContactList),
    {reply, ok, Redis};

handle_call({remove_all_contacts, Uid}, _From, Redis) ->
    {ok, ContactList} = q(["SMEMBERS", contacts_key(Uid)]),
    lists:foreach(fun(Contact) ->
                    {ok, _} = q(["SREM", reverse_key(Contact), Uid])
                  end, ContactList),
    {ok, _Res} = q(["DEL", contacts_key(Uid)]),
    {reply, ok, Redis};

handle_call({sync_contacts, Uid, Sid, ContactList}, _From, Redis) ->
    {ok, _Res} = q(["SADD", sync_key(Uid, Sid) | ContactList]),
    {reply, ok, Redis};

handle_call({finish_sync, Uid, Sid}, _From, Redis) ->
    {ok, RemovedContactList} = q(["SDIFF", contacts_key(Uid), sync_key(Uid, Sid)]),
    {ok, AddedContactList} = q(["SDIFF", sync_key(Uid, Sid), contacts_key(Uid)]),
    lists:foreach(fun(Contact) ->
                    {ok, _} = q(["SREM", reverse_key(Contact), Uid])
                  end, RemovedContactList),
    lists:foreach(fun(Contact) ->
                    {ok, _} = q(["SADD", reverse_key(Contact), Uid])
                  end, AddedContactList),
    {ok, _Res} = q(["RENAME", sync_key(Uid, Sid), contacts_key(Uid)]),
    {reply, ok, Redis};

handle_call({is_contact, Uid, Contact}, _From, Redis) ->
    {ok, Res} = q(["SISMEMBER", contacts_key(Uid), Contact]),
    {reply, binary_to_integer(Res) == 1, Redis};

handle_call({get_contacts, Uid}, _From, Redis) ->
    {ok, Res} = q(["SMEMBERS", contacts_key(Uid)]),
    {reply, {ok, Res}, Redis};

handle_call({get_sync_contacts, Uid, Sid}, _From, Redis) ->
    {ok, Res} = q(["SMEMBERS", sync_key(Uid, Sid)]),
    {reply, {ok, Res}, Redis};

handle_call({get_contact_uids, Contact}, _From, Redis) ->
    {ok, Res} = q(["SMEMBERS", reverse_key(Contact)]),
    {reply, {ok, Res}, Redis};

handle_call({get_contact_uids_size, Contact}, _From, Redis) ->
    {ok, Res} = q(["SCARD", reverse_key(Contact)]),
    {reply, binary_to_integer(Res), Redis};

handle_call({get_all_uids}, _From, Redis) ->
    {ok, [Cursor, Uids]} = q(["SCAN", "0", "COUNT", "1000"]),
    AllUids = get_all_uids(Cursor, Uids),
    {reply, {ok, AllUids}, Redis}.


get_all_uids(<<"0">>, Results) ->
    Results;
get_all_uids(Cursor, Results) ->
    {ok, [NewCursor, Uids]} = q(["SCAN", Cursor, "COUNT", "1000"]),
    get_all_uids(NewCursor, lists:append(Uids, Results)).


handle_cast(_Message, Redis) -> {noreply, Redis}.
handle_info(_Message, Redis) -> {noreply, Redis}.
terminate(_Reason, _Redis) -> ok.
code_change(_OldVersion, Redis, _Extra) -> {ok, Redis}.


q(Command) ->
    {ok, Result} = gen_server:call(redis_contacts_client, {q, Command}),
    Result.


-spec contacts_key(Uid :: binary()) -> binary().
contacts_key(Uid) ->
    <<?CONTACTS_KEY/binary, <<"{">>/binary, Uid/binary, <<"}">>/binary>>.


-spec sync_key(Uid :: binary(), Sid :: binary()) -> binary().
sync_key(Uid, Sid) ->
    <<?SYNC_KEY/binary, <<"{">>/binary, Uid/binary, <<"}:">>/binary, Sid/binary>>.

-spec reverse_key(Phone :: binary()) -> binary().
reverse_key(Phone) ->
    % TODO: use the REVERCE_KEY here, run migration
    <<?SYNC_KEY/binary, <<"{">>/binary, Phone/binary, <<"}">>/binary>>.




