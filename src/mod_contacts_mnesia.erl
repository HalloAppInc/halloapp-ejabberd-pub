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

%% exported debug commands for console use only.
-export([fetch_and_transform_just_contacts/0, update_contacts_new_table/0]).

init(_Host, _Opts) ->
  ejabberd_mnesia:create(?MODULE, user_contacts,
                        [{disc_copies, [node()]},
                        {type, bag},
                        {attributes, record_info(fields, user_contacts)}]),
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
        mnesia:write(#user_contacts{username = Username,
                                    contact = Contact}),
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
        Result1 = mnesia:match_object(UserContactNew),
        Return1 = case Result1 of
          [] ->
              none;
          [#user_contacts_new{} = ActualContactNew] ->
              mnesia:delete_object(ActualContactNew)
        end,
        UserContact = #user_contacts{username = Username, contact = Contact},
        Result2 = mnesia:match_object(UserContact),
        Return2 = case Result2 of
          [] ->
              none;
          [#user_contacts{} = ActualContact] ->
              mnesia:delete_object(ActualContact)
        end,
        case {Return1, Return2} of
          {none, none} -> none;
          _ -> ok
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
        Result1 = mnesia:match_object(UserContactNew),
        Return1 = case Result1 of
          [] ->
              none;
          [#user_contacts_new{} = ActualContactNew] ->
              mnesia:delete_object(ActualContactNew)
        end,
        UserContact = #user_contacts{username = Username, contact = Contact},
        Result2 = mnesia:match_object(UserContact),
        Return2 = case Result2 of
          [] ->
              none;
          [#user_contacts{}] ->
              mnesia:delete_object(UserContact)
        end,
        case {Return1, Return2} of
          {none, none} -> none;
          _ -> ok
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
        Result1 = mnesia:match_object(#user_contacts_new{username = Username, _ = '_'}),
        Return1 = case Result1 of
          [] ->
              none;
          [#user_contacts_new{} | _] ->
              mnesia:delete({user_contacts_new, Username})
        end,
        Result2 = mnesia:match_object(#user_contacts{username = Username, _ = '_'}),
        Return2 = case Result2 of
          [] ->
              none;
          [#user_contacts{} | _] ->
              mnesia:delete({user_contacts, Username})
        end,
        case {Return1, Return2} of
          {none, none} -> none;
          _ -> ok
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
        UserSyncId = case fetch_syncid(Username) of
                        {ok, [#user_syncids{syncid = SyncId}]} -> SyncId;
                        _ -> <<"">>
                      end,
        Result1 = mnesia:match_object(#user_contacts_new{username = Username, _ = '_'}),
        Result2 = lists:map(fun(#user_contacts{username = ActualUsername, contact = Contact}) ->
                                UserContactNewRecord = #user_contacts_new{username = ActualUsername,
                                                                          contact = Contact,
                                                                          syncid = UserSyncId},
                                UserContactOldRecord = #user_contacts_new{username = ActualUsername,
                                                                          contact = Contact,
                                                                          syncid = <<"undefined">>},
                                case Result1 of
                                  [] -> UserContactNewRecord;
                                  _ ->
                                    case lists:member(UserContactNewRecord, Result1) of
                                      true -> UserContactNewRecord;
                                      false -> UserContactOldRecord
                                    end
                                end
                            end, mnesia:match_object(#user_contacts{username = Username, _ = '_'})),
        FinalResult = lists:merge([Result1, Result2]),
        sets:to_list(sets:from_list(FinalResult))
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
        Result = mnesia:match_object(#user_syncids{username = Username, _ = '_'}),
        Result
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
        Result1 = mnesia:match_object(UserContactNew),
        Boolean1 = case Result1 of
                    [] ->
                        false;
                    [#user_contacts_new{}] ->
                        true
                  end,
        UserContact = #user_contacts{username = Username, contact = Contact},
        Result2 = mnesia:match_object(UserContact),
        Boolean2 = case Result2 of
                    [] ->
                        false;
                    [#user_contacts{}] ->
                        true
                  end,
        Boolean1 or Boolean2
      end,
  case mnesia:transaction(F) of
    {atomic, Res} ->
      Res;
    {aborted, Reason} ->
      ?ERROR_MSG("check_if_contact_exists:
                  Mnesia transaction failed for username: ~p with reason: ~p", [Username, Reason]),
      false
  end.



-spec fetch_and_transform_just_contacts() -> {ok, [#user_contacts_new{}]} | {error, any()}.
fetch_and_transform_just_contacts() ->
  F = fun() ->
        lists:map(fun(#user_contacts{username = Username, contact = Contact}) ->
                    UserSyncId = case fetch_syncid(Username) of
                                    {ok, [#user_syncids{syncid = SyncId}]} -> SyncId;
                                    _ -> <<"">>
                                  end,
                    #user_contacts_new{username = Username,
                                      contact = Contact,
                                      syncid = UserSyncId}
                  end, mnesia:match_object(#user_contacts{_ = '_'}))
      end,
  case mnesia:transaction(F) of
    {atomic, Result} ->
      {ok, Result};
    {aborted, Reason} ->
      ?ERROR_MSG("fetch_contacts:
              Mnesia transaction failed for all contacts with reason: ~p", [Reason]),
      {error, db_failure}
  end.



-spec update_contacts_new_table() -> {ok, ok} | {error, any()}.
update_contacts_new_table() ->
  F = fun() ->
        case fetch_and_transform_just_contacts() of
          {ok, TransformedContacts} ->
            lists:foreach(fun(#user_contacts_new{} = UserContactNew) ->
                            mnesia:write(UserContactNew)
                          end, TransformedContacts),
            {ok, ok};
          {error, _} ->
            {error, db_failure}
        end
      end,
  case mnesia:transaction(F) of
    {atomic, Result} ->
      {ok, Result};
    {aborted, Reason} ->
      ?ERROR_MSG("update_contacts_new_table:
              Mnesia transaction failed for all contacts with reason: ~p", [Reason]),
      {error, db_failure}
  end.

