%%%----------------------------------------------------------------------
%%% File    : mod_whisper_mnesia.erl
%%%
%%% Copyright (C) 2020 halloappinc.
%%%
%%% This module handles all the mnesia related queries with whisper keys to
%%% - insert a user's whisper keys into an mnesia table
%%% - fetch a key set of a user: this will also delete the otp key used.
%%% - delete all keys of a user.
%%%----------------------------------------------------------------------

-module(mod_whisper_mnesia).

-include("logger.hrl").
-include("xmpp.hrl").
-include("translate.hrl").
-include("whisper.hrl").

-export([init/2, close/1]).

-export([insert_keys/4, insert_otp_keys/2, delete_all_keys/1,
         get_otp_key_count/1, fetch_key_set_and_delete/1]).

init(_Host, _Opts) ->
  case ejabberd_mnesia:create(?MODULE, user_whisper_keys,
                              [{disc_copies, [node()]},
                              {type, set},
                              {attributes, record_info(fields, user_whisper_keys)}]) of
    {atomic, _} ->
      case ejabberd_mnesia:create(?MODULE, user_whisper_otp_keys,
                                  [{disc_copies, [node()]},
                                  {type, bag},
                                  {attributes, record_info(fields, user_whisper_otp_keys)}]) of
        {atomic, _} -> ok;
        _ -> {error, db_failure}
      end;
    _ ->
      {error, db_failure}
  end.

close(_Host) ->
  ok.



-spec insert_keys(binary(), binary(), binary(), [binary()]) -> {ok, any()} | {error, any()}.
insert_keys(Username, IdentityKey, SignedKey, OneTimeKeys) ->
  F = fun () ->
        mnesia:write(#user_whisper_keys{username = Username,
                                        identity_key = IdentityKey,
                                        signed_key = SignedKey}),
        lists:foreach(fun(OneTimeKey) ->
                        mnesia:write(#user_whisper_otp_keys{username = Username,
                                                            one_time_key = OneTimeKey})
                      end, OneTimeKeys),
        {ok, inserted_keys}
      end,
  case mnesia:transaction(F) of
    {atomic, Result} ->
        ?DEBUG("insert_keys: Mnesia transaction successful for username: ~p", [Username]),
        Result;
    {aborted, Reason} ->
        ?ERROR_MSG("insert_keys: Mnesia transaction failed for username: ~p with reason: ~p",
                                                                  [Username, Reason]),
        {error, db_failure}
  end.


-spec insert_otp_keys(binary(), [binary()]) -> {ok, any()} | {error, any()}.
insert_otp_keys(Username, OneTimeKeys) ->
  F = fun () ->
        lists:foreach(fun(OneTimeKey) ->
                        mnesia:write(#user_whisper_otp_keys{username = Username,
                                                            one_time_key = OneTimeKey})
                      end, OneTimeKeys),
        {ok, inserted_keys}
      end,
  case mnesia:transaction(F) of
    {atomic, Result} ->
        ?DEBUG("insert_keys: Mnesia transaction successful for username: ~p", [Username]),
        Result;
    {aborted, Reason} ->
        ?ERROR_MSG("insert_keys: Mnesia transaction failed for username: ~p with reason: ~p",
                                                                  [Username, Reason]),
        {error, db_failure}
  end.



-spec delete_all_keys(binary()) -> {ok, any()} | {error, any()}.
delete_all_keys(Username) ->
  F = fun() ->
        case mnesia:match_object(#user_whisper_keys{username = Username, _ = '_'}) of
          [] ->
              ok;
          [#user_whisper_keys{} = WhisperKey] ->
              mnesia:delete_object(WhisperKey)
        end,
        case mnesia:match_object(#user_whisper_otp_keys{username = Username, _ = '_'}) of
          [] ->
              ok;
          [#user_whisper_otp_keys{} | _] = WhisperOtpKeys ->
              lists:foreach(fun(WhisperOtpKey) ->
                              mnesia:delete_object(WhisperOtpKey)
                            end, WhisperOtpKeys)
        end
      end,
  case mnesia:transaction(F) of
    {atomic, Result} ->
      ?DEBUG("delete_all_keys: Mnesia transaction successful for username: ~p", [Username]),
      {ok, Result};
    {aborted, Reason} ->
      ?ERROR_MSG("delete_all_keys: Mnesia transaction failed for username: ~p with reason: ~p",
                                                                          [Username, Reason]),
      {error, db_failure}
  end.




-spec get_otp_key_count(binary()) -> {ok, integer()} | {error, any()}.
get_otp_key_count(Username) ->
  F = fun() ->
        case mnesia:match_object(#user_whisper_otp_keys{username = Username, _ = '_'}) of
          [] -> 0;
          WhisperOtpKeys -> length(WhisperOtpKeys)
        end
      end,
  case mnesia:transaction(F) of
    {atomic, Result} ->
      ?DEBUG("get_otp_key_count: Mnesia transaction successful for username: ~p", [Username]),
      {ok, Result};
    {aborted, Reason} ->
      ?ERROR_MSG("get_otp_key_count: Mnesia transaction failed for username: ~p with reason: ~p",
                                                                          [Username, Reason]),
      {error, db_failure}
  end.



-spec fetch_key_set_and_delete(binary()) -> {ok, #user_whisper_key_set{}} | {error, any()}.
fetch_key_set_and_delete(Username) ->
  F = fun() ->
        case mnesia:match_object(#user_whisper_keys{username = Username, _ = '_'}) of
          [] ->
            IdentityKey = <<>>,
            SignedKey = <<>>;
          [#user_whisper_keys{} = WhisperKey] ->
            IdentityKey = WhisperKey#user_whisper_keys.identity_key,
            SignedKey = WhisperKey#user_whisper_keys.signed_key
        end,
        case mnesia:match_object(#user_whisper_otp_keys{username = Username, _ = '_'}) of
          [] -> 
              OneTimeKey = <<>>,
              ok;
          [#user_whisper_otp_keys{} = WhisperOtpKey| _] ->
            OneTimeKey = WhisperOtpKey#user_whisper_otp_keys.one_time_key,
            mnesia:delete_object(WhisperOtpKey)
        end,
        #user_whisper_key_set{username = Username,
                         identity_key = IdentityKey,
                         signed_key = SignedKey,
                         one_time_key = OneTimeKey}
      end,
  case mnesia:transaction(F) of
    {atomic, Result} ->
      ?DEBUG("fetch_key_set: Mnesia transaction successful for username: ~p", [Username]),
      {ok, Result};
    {aborted, Reason} ->
      ?ERROR_MSG("fetch_key_set: Mnesia transaction failed for username: ~p with reason: ~p",
                                                                          [Username, Reason]),
      {error, db_failure}
  end.



