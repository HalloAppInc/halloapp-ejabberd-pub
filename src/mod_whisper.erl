%%%----------------------------------------------------------------------
%%% File    : mod_whisper.erl
%%%
%%% Copyright (C) 2020 halloappinc.
%%%
%%% This file handles the iq packet queries with a custom namespace
%%% (<<"halloapp:whisper:keys">>) that we defined.
%%% We define custom xml records of the following type:
%%% "whisper_keys", "identity_key", "signed_key", "one_time_key" in xmpp/specs/xmpp_codec.spec file.
%%%
%%% The module handles both set and get iq stanzas.
%%% iq-set stanza is used to set all the user keys for a particular user.
%%% iq-get stanza is used to get a key_set for a username.
%%% Client needs to set its own keys using the iq-set stanza.
%%% Client can fetch its friends keys using the iq-set stanza.
%%% TODO(murali@): Allow clients to only fetch keys of their friends.
%%%----------------------------------------------------------------------

-module(mod_whisper).
-author('murali').
-behaviour(gen_mod).

-include("logger.hrl").
-include("xmpp.hrl").
-include("translate.hrl").
-include("whisper.hrl").

-define(NS_WHISPER, <<"halloapp:whisper:keys">>).

%% gen_mod API.
-export([start/2, stop/1, reload/3, depends/2, mod_opt_type/1, mod_options/1]).
%% IQ handlers and hooks.
-export([process_local_iq/1, remove_user/2]).
%% exports for console debug manual use
-export([delete_all_keys/1, check_keys_left_and_notify_user/2,
         notify_key_count/4]).


start(Host, Opts) ->
    gen_iq_handler:add_iq_handler(ejabberd_local, Host, ?NS_WHISPER, ?MODULE, process_local_iq),
    ejabberd_hooks:add(remove_user, Host, ?MODULE, remove_user, 40),
    mod_whisper_mnesia:init(Host, Opts),
    store_options(Opts),
    ok.

stop(Host) ->
    mod_whisper_mnesia:close(Host),
    gen_iq_handler:remove_iq_handler(ejabberd_local, Host, ?NS_WHISPER),
    ejabberd_hooks:delete(remove_user, Host, ?MODULE, remove_user, 40),
    ok.

depends(_Host, _Opts) ->
    [].

reload(_Host, _NewOpts, _OldOpts) ->
    ok.


%%====================================================================
%% iq handlers
%%====================================================================

process_local_iq(#iq{from = From, lang = Lang, type = set,
                    sub_els = [#whisper_keys{type = set} = WhisperKeys]} = IQ) ->
    Username = jid:to_string(jid:remove_resource(From)),
    delete_all_keys(Username),
    IdentityKey = WhisperKeys#whisper_keys.identity_key,
    SignedKey = WhisperKeys#whisper_keys.signed_key,
    OneTimeKeys = WhisperKeys#whisper_keys.one_time_keys,
    case IdentityKey =/= undefined andalso SignedKey =/= undefined andalso
         OneTimeKeys =/= [] of
         true ->
             mod_whisper_mnesia:insert_keys(Username, IdentityKey, SignedKey, OneTimeKeys),
             xmpp:make_iq_result(IQ);
         false ->
            Txt = ?T("Invalid request"),
            xmpp:make_error(IQ, xmpp:err_bad_request(Txt, Lang))
    end;

process_local_iq(#iq{from = From, lang = Lang, type = set,
                    sub_els = [#whisper_keys{type = add} = WhisperKeys]} = IQ) ->
    Username = jid:to_string(jid:remove_resource(From)),
    IdentityKey = WhisperKeys#whisper_keys.identity_key,
    SignedKey = WhisperKeys#whisper_keys.signed_key,
    OneTimeKeys = WhisperKeys#whisper_keys.one_time_keys,
    case IdentityKey == undefined andalso SignedKey == undefined andalso
         OneTimeKeys =/= [] of
         true ->
             mod_whisper_mnesia:insert_otp_keys(Username, OneTimeKeys),
             xmpp:make_iq_result(IQ);
         false ->
            Txt = ?T("Invalid request"),
            xmpp:make_error(IQ, xmpp:err_bad_request(Txt, Lang))
    end;

process_local_iq(#iq{from = From, lang = Lang, type = get,
                    sub_els = [#whisper_keys{type = count}]} = IQ) ->
    Username = jid:to_string(jid:remove_resource(From)),
    case mod_whisper_mnesia:get_otp_key_count(Username) of
      {ok, Count} ->
        xmpp:make_iq_result(IQ, #whisper_keys{username = Username,
                                              otp_key_count = integer_to_binary(Count)});
      {error, _} ->
        Txt = ?T("Internal server error"),
        xmpp:make_error(IQ, xmpp:err_bad_request(Txt, Lang))
    end;

process_local_iq(#iq{from = #jid{lserver = ServerHost}, lang = Lang, type = get,
                    sub_els = [#whisper_keys{username = Username, type = get}]} = IQ) ->
    %%TODO(murali@): check if user is allowed to access keys of username.
    case Username of
        undefined ->
            Txt = ?T("Invalid request"),
            xmpp:make_error(IQ, xmpp:err_bad_request(Txt, Lang));
        _ ->
            case mod_whisper_mnesia:fetch_key_set_and_delete(Username) of
              {ok, WhisperKeySet} ->
                check_keys_left_and_notify_user(Username, ServerHost),
                IdentityKey = WhisperKeySet#user_whisper_key_set.identity_key,
                SignedKey = WhisperKeySet#user_whisper_key_set.signed_key,
                OneTimeKey = WhisperKeySet#user_whisper_key_set.one_time_key,
                xmpp:make_iq_result(IQ, #whisper_keys{username = Username,
                                                      identity_key = IdentityKey,
                                                      signed_key = SignedKey,
                                                      one_time_keys = [OneTimeKey]});
              {error, _} ->
                Txt = ?T("Internal server error"),
                xmpp:make_error(IQ, xmpp:err_bad_request(Txt, Lang))
            end
    end.


%% remove_user hook deletes all keys of the user.
remove_user(User, Server) ->
    Username = jid:to_string(jid:make(User, Server)),
    mod_whisper_mnesia:delete_all_keys(Username).


%%====================================================================
%% internal functions
%%====================================================================

-spec delete_all_keys(binary()) -> ok.
delete_all_keys(Username) ->
  mod_whisper_mnesia:delete_all_keys(Username),
  ok.



-spec check_keys_left_and_notify_user(binary(), binary()) -> ok.
check_keys_left_and_notify_user(Username, ServerHost) ->
  case mod_whisper_mnesia:get_otp_key_count(Username) of
      {ok, Count} ->
        MinCount = get_min_otp_key_count(),
        notify_key_count(Username, ServerHost, Count, MinCount);
      {error, _} ->
        ok
  end.



-spec notify_key_count(binary(), binary(), integer(), integer()) -> ok.
notify_key_count(Username, ServerHost, Count, MinCount) when Count < MinCount ->
  Stanza = #message{
         from = jid:make(ServerHost),
         to = jid:from_string(Username),
         sub_els = [#whisper_keys{username = Username,
                                  otp_key_count = integer_to_binary(Count)}]},
  ?DEBUG("mod_whisper: notify_key_count: Notifying user: ~p about the count: ~p",
                                                                [Username, Count]),
  ejabberd_router:route(Stanza),
  ok;
notify_key_count(Username, _ServerHost, _Count, _MinCount) ->
  ?DEBUG("mod_whisper: Ignore notifying to user: ~p since we have enough keys", [Username]),
  ok.


%%%===================================================================
%%% Configuration processing
%%%===================================================================

store_options(Opts) ->
    MinOtpKeyCount = mod_whisper_opt:min_otp_key_count(Opts),
    %% Store MinOtpKeyCount.
    persistent_term:put({?MODULE, min_otp_key_count}, MinOtpKeyCount).


-spec get_min_otp_key_count() -> 'infinity' | pos_integer().
get_min_otp_key_count() ->
    persistent_term:get({?MODULE, min_otp_key_count}).


mod_opt_type(min_otp_key_count) ->
    econf:pos_int(infinity).


mod_options(_Host) ->
    [{min_otp_key_count, 10}].
%% minimum number of otp keys after which we sent notifications to the client about low keys.




