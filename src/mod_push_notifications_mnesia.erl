%%%----------------------------------------------------------------------
%%% File    : mod_push_notifications_mnesia.erl
%%%
%%% Copyright (C) 2019 halloappinc.
%%%
%%% This module handles all the mnesia related queries with push notifications to 
%%% - register users with their tokens for both FCM and APNS.
%%% - unregister the user.
%%% - list all registrations for the user.
%%% In the future, need to handle caching options and also multiple devices on the same username if possible.
%%%----------------------------------------------------------------------

-module(mod_push_notifications_mnesia).
-author('murali').
-include("logger.hrl").
-include("xmpp.hrl").
-include("translate.hrl").

-record(push_registered_users, {username :: {binary(), binary()},
                                os :: binary(),
                                token :: binary(),
                                timestamp :: binary()}).

-export([init/2, close/0, register_push_fcm/3, register_push_apns/3, register_push/4, list_push_registrations/1, unregister_push/1]).
%% TODO(murali@): Think about adding cache options here!

init(_Host, _Opts) ->
  case mnesia:create_table(push_registered_users,
                            [{disc_copies, [node()]},
                            {attributes, record_info(fields, push_registered_users)}]) of
    {atomic, _} -> ok;
    _ -> {error, db_failure}
  end.

close() ->
  ok.

-spec register_push_fcm({binary(), binary()},
                        binary(), binary()) -> {ok, any()} | {error, any()}.
register_push_fcm(Username, Token, Timestamp) ->
  register_push(Username, <<"android">>, Token, Timestamp).

-spec register_push_apns({binary(), binary()},
                          binary(), binary()) -> {ok, any()} | {error, any()}.
register_push_apns(Username, Token, Timestamp) ->
  register_push(Username, <<"ios">>, Token, Timestamp).

-spec register_push({binary(), binary()}, binary(),
                    binary(), binary()) -> {ok, any()} | {error, any()}.
register_push(Username, Os, Token, Timestamp) ->
  F = fun () ->
        case mnesia:read({push_registered_users, Username}) of
          %% If no record exists for the user: insert the record.
          [] ->
              mnesia:write(#push_registered_users{username = Username, os = Os, token = Token, timestamp = Timestamp}),
              {ok, new_record};
          %% If a record exists with the same token, update the timestamp.
          [#push_registered_users{username = Username, token = Token}] ->
              mnesia:write(#push_registered_users{username = Username, os = Os, token = Token, timestamp = Timestamp}),
              {ok, update_timestamp};
          %% If a record exists with a different token, update the token and timestamp.
          [#push_registered_users{username = Username, token = _}] ->
              mnesia:write(#push_registered_users{username = Username, os = Os, token = Token, timestamp = Timestamp}),
              {ok, update_token}
        end
      end,
  case mnesia:transaction(F) of
    {atomic, Res} ->
        ?DEBUG("Mnesia transaction successful for username: ~p", [Username]),
        Res;
    {aborted, Reason} ->
        ?ERROR_MSG("Mnesia transaction failed for username: ~p with reason: ~p", [Username, Reason]),
        {error, db_failure}
  end.

-spec list_push_registrations({binary(), binary()}) -> {ok, any()} | {error, any()}.
list_push_registrations(Username) ->
  F = fun() ->
        Result = mnesia:read({push_registered_users, Username}),
        case Result of
          [] ->
              {ok, none};
          [#push_registered_users{} = Res] ->
              {ok, {Res#push_registered_users.username, Res#push_registered_users.os, Res#push_registered_users.token, Res#push_registered_users.timestamp}}
        end
      end,
  case mnesia:transaction(F) of
    {atomic, Res} ->
      ?DEBUG("Mnesia transaction successful for username: ~p", [Username]),
      Res;
    {aborted, Reason} ->
      ?ERROR_MSG("Mnesia transaction failed for username: ~p with reason: ~p", [Username, Reason]),
      {error, db_failure}
  end.

-spec unregister_push({binary(), binary()}) -> {ok, any()} | {error, any()}.
unregister_push(Username) ->
  F = fun() ->
        Result = mnesia:read({push_registered_users, Username}),
        case Result of
          [] ->
              ok;
          [#push_registered_users{}] ->
              mnesia:delete({push_registered_users, Username})
        end
      end,
  case mnesia:transaction(F) of
    {atomic, Res} ->
      ?DEBUG("Mnesia transaction successful for username: ~p", [Username]),
      {ok, Res};
    {aborted, Reason} ->
      ?ERROR_MSG("Mnesia transaction failed for username: ~p with reason: ~p", [Username, Reason]),
      {error, db_failure}
  end.






