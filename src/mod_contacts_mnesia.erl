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

-include("logger.hrl").
-include("xmpp.hrl").
-include("translate.hrl").
-include("user_info.hrl").

-export([init/2, close/0]).

-export([insert_contact/3, delete_contact/2, delete_contact/3,
          delete_contacts/1, fetch_contacts/1, check_if_contact_exists/2]).
-export([need_transform/1, transform/1]).

init(_Host, _Opts) ->
  case ejabberd_mnesia:create(?MODULE, user_contacts,
                            [{disc_copies, [node()]},
                            {type, bag},
                            {attributes, record_info(fields, user_contacts)}]) of
    {atomic, _} -> ok;
    _ -> {error, db_failure}
  end.

close() ->
  ok.



-spec insert_contact({binary(), binary()}, {binary(), binary()}, binary()) ->
                                              {ok, any()} | {error, any()}.
insert_contact(Username, Contact, Timestamp) ->
  F = fun () ->
        mnesia:write(#user_contacts{username = Username,
                                    contact = Contact,
                                    timestamp = Timestamp}),
        {ok, inserted_contact}
      end,
  case mnesia:transaction(F) of
    {atomic, Result} ->
        ?DEBUG("insert_contact:
                Mnesia transaction successful for username: ~p", [Username]),
        Result;
    {aborted, Reason} ->
        ?ERROR_MSG("insert_contact:
                    Mnesia transaction failed for username: ~p with reason: ~p",
                                                                  [Username, Reason]),
        {error, db_failure}
  end.



-spec delete_contact({binary(), binary()}, {binary(), binary()}) -> {ok, any()} | {error, any()}.
delete_contact(Username, Contact) ->
  F = fun() ->
        UserContact = #user_contacts{username = Username, contact = Contact, _ = '_'},
        Result = mnesia:match_object(UserContact),
        case Result of
          [] ->
              none;
          [#user_contacts{} = ActualContact] ->
              mnesia:delete_object(ActualContact)
        end
      end,
  case mnesia:transaction(F) of
    {atomic, Result} ->
      ?DEBUG("delete_contact: Mnesia transaction successful for username: ~p", [Username]),
      {ok, Result};
    {aborted, Reason} ->
      ?ERROR_MSG("delete_contact:
                  Mnesia transaction failed for username: ~p with reason: ~p", [Username, Reason]),
      {error, db_failure}
  end.



-spec delete_contact({binary(), binary()}, {binary(), binary()}, binary()) ->
                                    {ok, any()} | {error, any()}.
delete_contact(Username, Contact, Timestamp) ->
  F = fun() ->
        UserContact = #user_contacts{username = Username, contact = Contact, timestamp = Timestamp},
        Result = mnesia:match_object(UserContact),
        case Result of
          [] ->
              none;
          [#user_contacts{}] ->
              mnesia:delete_object(UserContact)
        end
      end,
  case mnesia:transaction(F) of
    {atomic, Result} ->
      ?DEBUG("delete_contact: Mnesia transaction successful for username: ~p", [Username]),
      {ok, Result};
    {aborted, Reason} ->
      ?ERROR_MSG("delete_contact:
                  Mnesia transaction failed for username: ~p with reason: ~p", [Username, Reason]),
      {error, db_failure}
  end.



-spec delete_contacts({binary(), binary()}) -> {ok, any()} | {error, any()}.
delete_contacts(Username) ->
  F = fun() ->
        Result = mnesia:match_object(#user_contacts{username = Username, _ = '_'}),
        case Result of
          [] ->
              none;
          [#user_contacts{} | _] ->
              mnesia:delete({user_contacts, Username})
        end
      end,
  case mnesia:transaction(F) of
    {atomic, Result} ->
      ?DEBUG("delete_contacts: Mnesia transaction successful for username: ~p", [Username]),
      {ok, Result};
    {aborted, Reason} ->
      ?ERROR_MSG("delete_contacts:
                  Mnesia transaction failed for username: ~p with reason: ~p", [Username, Reason]),
      {error, db_failure}
  end.



-spec fetch_contacts({binary(), binary()}) -> {ok, [#user_contacts{}]} | {error, any()}.
fetch_contacts(Username) ->
  F = fun() ->
        Result = mnesia:match_object(#user_contacts{username = Username, _ = '_'}),
        Result
      end,
  case mnesia:transaction(F) of
    {atomic, Result} ->
      ?DEBUG("fetch_contacts: Mnesia transaction successful for username: ~p", [Username]),
      {ok, Result};
    {aborted, Reason} ->
      ?ERROR_MSG("fetch_contacts:
                  Mnesia transaction failed for username: ~p with reason: ~p", [Username, Reason]),
      {error, db_failure}
  end.



-spec check_if_contact_exists({binary(), binary()},{binary(), binary()}) -> boolean().
check_if_contact_exists(Username, Contact) ->
  F = fun() ->
        UserContact = #user_contacts{username = Username, contact = Contact, _ = '_'},
        Result = mnesia:match_object(UserContact),
        case Result of
          [] ->
              false;
          [#user_contacts{}] ->
              true
        end
      end,
  case mnesia:transaction(F) of
    {atomic, Res} ->
      ?DEBUG("check_if_contact_exists: Mnesia transaction successful for username: ~p", [Username]),
      Res;
    {aborted, Reason} ->
      ?ERROR_MSG("check_if_contact_exists:
                  Mnesia transaction failed for username: ~p with reason: ~p", [Username, Reason]),
      false
  end.


need_transform({user_contacts, _Username, _Contact}) ->
  ?INFO_MSG("Mnesia table 'user_contacts' will be modified to include timestamp", []),
  true;
need_transform(_) ->
  false.


transform({user_contacts, Username, Contact}) ->
    #user_contacts{username = Username,
                    contact = Contact,
                    timestamp = util:convert_timestamp_to_binary(erlang:timestamp())}.

