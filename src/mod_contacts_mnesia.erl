%%%----------------------------------------------------------------------
%%% File    : mod_contacts_mnesia.erl
%%%
%%% Copyright (C) 2020 halloappinc.
%%%
%%% This module handles all the mnesia related queries with contacts to
%%% - insert a user's contacts into an mnesia table
%%% - fetch/delete user's contacts
%%% - check if a contact exists already.
%%%----------------------------------------------------------------------

-module(mod_contacts_mnesia).
-author('murali').
-include("logger.hrl").
-include("xmpp.hrl").
-include("translate.hrl").
-include("user_info.hrl").

-export([init/2, close/0]).

-export([
        insert_contact/3, insert_syncid/2, delete_contact/2, delete_contact/3,
        delete_contacts/1, fetch_contacts/1, fetch_syncid/1, check_if_contact_exists/2,
        fetch_all_contacts/0]).


init(_Host, _Opts) ->
  ejabberd_mnesia:create(?MODULE, user_contacts_new,
                        [{disc_copies, [node()]},
                        {type, bag},
                        {attributes, record_info(fields, user_contacts_new)}]),
  ejabberd_mnesia:create(?MODULE, user_syncids,
                          [{disc_copies, [node()]},
                          {type, set},
                          {attributes, record_info(fields, user_syncids)}]).

close() ->
  ok.



-spec insert_contact({binary(), binary()}, {binary(), binary()}, binary()) ->
                                              {ok, any()} | {error, any()}.
insert_contact(Username, Contact, SyncId) ->
  mnesia:dirty_write(#user_contacts_new{username = Username,
                                    contact = Contact,
                                    syncid = SyncId}),
  {ok, ok}.



-spec insert_syncid({binary(), binary()}, binary()) ->
                                              {ok, any()} | {error, any()}.
insert_syncid(Username, SyncId) ->
  mnesia:dirty_write(#user_syncids{username = Username,
                                   syncid = SyncId}),
  {ok, ok}.



-spec delete_contact({binary(), binary()}, {binary(), binary()}) -> {ok, any()} | {error, any()}.
delete_contact(Username, Contact) ->
  UserContactNew = #user_contacts_new{username = Username, contact = Contact, _ = '_'},
  Result = mnesia:dirty_match_object(UserContactNew),
  case Result of
    [] ->
        {ok, none};
    [#user_contacts_new{} = ActualContactNew | _] ->
        mnesia:dirty_delete_object(ActualContactNew),
        {ok, ok}
  end.



-spec delete_contact({binary(), binary()}, {binary(), binary()}, binary()) ->
                                    {ok, any()} | {error, any()}.
delete_contact(Username, Contact, SyncId) ->
  UserContactNew = #user_contacts_new{username = Username, contact = Contact, syncid = SyncId},
  Result = mnesia:dirty_match_object(UserContactNew),
  case Result of
    [] ->
        {ok, none};
    [#user_contacts_new{} = ActualContactNew | _] ->
        mnesia:dirty_delete_object(ActualContactNew),
        {ok, ok}
  end.



-spec delete_contacts({binary(), binary()}) -> {ok, any()} | {error, any()}.
delete_contacts(Username) ->
  Result = mnesia:dirty_match_object(#user_contacts_new{username = Username, _ = '_'}),
  case Result of
    [] ->
        {ok, none};
    [#user_contacts_new{} | _] ->
        mnesia:dirty_delete({user_contacts_new, Username}),
        {ok, ok}
  end.



-spec fetch_contacts({binary(), binary()}) -> {ok, [#user_contacts_new{}]} | {error, any()}.
fetch_contacts(Username) ->
  Result = mnesia:dirty_match_object(#user_contacts_new{username = Username, _ = '_'}),
  {ok, Result}.



-spec fetch_syncid({binary(), binary()}) -> {ok, [#user_syncids{}]} | {error, any()}.
fetch_syncid(Username) ->
  Result = mnesia:dirty_match_object(#user_syncids{username = Username, _ = '_'}),
  {ok, Result}.



-spec check_if_contact_exists({binary(), binary()},{binary(), binary()}) -> boolean().
check_if_contact_exists(Username, Contact) ->
  UserContactNew = #user_contacts_new{username = Username, contact = Contact, _ = '_'},
  Result = mnesia:dirty_match_object(UserContactNew),
  case Result of
    [] ->
        false;
    [#user_contacts_new{} | _] ->
        true
  end.


-spec fetch_all_contacts() -> {ok, [#user_contacts_new{}]} | {error, any()}.
fetch_all_contacts() ->
  Result = mnesia:dirty_match_object(mnesia:table_info(user_contacts_new, wild_pattern)),
  {ok, Result}.

