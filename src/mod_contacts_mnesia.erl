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

-export([insert_contact/3, insert_syncid/2, delete_contact/2, delete_contact/3,
          delete_contacts/1, fetch_contacts/1, fetch_syncid/1, check_if_contact_exists/2]).


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
  F = fun () ->
        mnesia:write(#user_contacts_new{username = Username,
                                    contact = Contact,
                                    syncid = SyncId}),
        {ok, inserted_contact}
      end,
  case mnesia:transaction(F) of
    {atomic, Result} ->
        Result;
    {aborted, Reason} ->
        ?ERROR_MSG("insert_contact:
                    Mnesia transaction failed for username: ~p with reason: ~p",
                                                                  [Username, Reason]),
        {error, db_failure}
  end.



-spec insert_syncid({binary(), binary()}, binary()) ->
                                              {ok, any()} | {error, any()}.
insert_syncid(Username, SyncId) ->
  F = fun () ->
        mnesia:write(#user_syncids{username = Username,
                                   syncid = SyncId}),
        {ok, inserted_syncid}
      end,
  case mnesia:transaction(F) of
    {atomic, Result} ->
        Result;
    {aborted, Reason} ->
        ?ERROR_MSG("insert_syncid:
                    Mnesia transaction failed for username: ~p with reason: ~p",
                                                                  [Username, Reason]),
        {error, db_failure}
  end.



-spec delete_contact({binary(), binary()}, {binary(), binary()}) -> {ok, any()} | {error, any()}.
delete_contact(Username, Contact) ->
  F = fun() ->
        UserContactNew = #user_contacts_new{username = Username, contact = Contact, _ = '_'},
        Result = mnesia:match_object(UserContactNew),
        case Result of
          [] ->
              none;
          [#user_contacts_new{} = ActualContactNew] ->
              mnesia:delete_object(ActualContactNew)
        end
      end,
  case mnesia:transaction(F) of
    {atomic, Result} ->
      {ok, Result};
    {aborted, Reason} ->
      ?ERROR_MSG("delete_contact:
                  Mnesia transaction failed for username: ~p with reason: ~p", [Username, Reason]),
      {error, db_failure}
  end.



-spec delete_contact({binary(), binary()}, {binary(), binary()}, binary()) ->
                                    {ok, any()} | {error, any()}.
delete_contact(Username, Contact, SyncId) ->
  F = fun() ->
        UserContactNew = #user_contacts_new{username = Username, contact = Contact, syncid = SyncId},
        Result = mnesia:match_object(UserContactNew),
        case Result of
          [] ->
              none;
          [#user_contacts_new{} = ActualContactNew] ->
              mnesia:delete_object(ActualContactNew)
        end
      end,
  case mnesia:transaction(F) of
    {atomic, Result} ->
      {ok, Result};
    {aborted, Reason} ->
      ?ERROR_MSG("delete_contact:
                  Mnesia transaction failed for username: ~p with reason: ~p", [Username, Reason]),
      {error, db_failure}
  end.



-spec delete_contacts({binary(), binary()}) -> {ok, any()} | {error, any()}.
delete_contacts(Username) ->
  F = fun() ->
        Result = mnesia:match_object(#user_contacts_new{username = Username, _ = '_'}),
        case Result of
          [] ->
              none;
          [#user_contacts_new{} | _] ->
              mnesia:delete({user_contacts_new, Username})
        end
      end,
  case mnesia:transaction(F) of
    {atomic, Result} ->
      {ok, Result};
    {aborted, Reason} ->
      ?ERROR_MSG("delete_contacts:
                  Mnesia transaction failed for username: ~p with reason: ~p", [Username, Reason]),
      {error, db_failure}
  end.



-spec fetch_contacts({binary(), binary()}) -> {ok, [#user_contacts_new{}]} | {error, any()}.
fetch_contacts(Username) ->
  F = fun() ->
        mnesia:match_object(#user_contacts_new{username = Username, _ = '_'})
      end,
  case mnesia:transaction(F) of
    {atomic, Result} ->
      {ok, Result};
    {aborted, Reason} ->
      ?ERROR_MSG("fetch_contacts:
                  Mnesia transaction failed for username: ~p with reason: ~p", [Username, Reason]),
      {error, db_failure}
  end.



-spec fetch_syncid({binary(), binary()}) -> {ok, [#user_syncids{}]} | {error, any()}.
fetch_syncid(Username) ->
  F = fun() ->
        mnesia:match_object(#user_syncids{username = Username, _ = '_'})
      end,
  case mnesia:transaction(F) of
    {atomic, Result} ->
      {ok, Result};
    {aborted, Reason} ->
      ?ERROR_MSG("fetch_syncid:
                  Mnesia transaction failed for username: ~p with reason: ~p", [Username, Reason]),
      {error, db_failure}
  end.



-spec check_if_contact_exists({binary(), binary()},{binary(), binary()}) -> boolean().
check_if_contact_exists(Username, Contact) ->
  F = fun() ->
        UserContactNew = #user_contacts_new{username = Username, contact = Contact, _ = '_'},
        Result = mnesia:match_object(UserContactNew),
        case Result of
          [] ->
              false;
          [#user_contacts_new{}] ->
              true
        end
      end,
  case mnesia:transaction(F) of
    {atomic, Res} ->
      Res;
    {aborted, Reason} ->
      ?ERROR_MSG("check_if_contact_exists:
                  Mnesia transaction failed for username: ~p with reason: ~p", [Username, Reason]),
      false
  end.

