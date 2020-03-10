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
%%%----------------------------------------------------------------------

-module(mod_whisper).

-behaviour(gen_mod).

-include("logger.hrl").
-include("xmpp.hrl").
-include("translate.hrl").
-include("whisper.hrl").

-define(NS_WHISPER, <<"halloapp:whisper:keys">>).

%% gen_mod API.
-export([start/2, stop/1, reload/3, depends/2, mod_options/1]).
%% IQ handlers and hooks.
-export([process_local_iq/1, remove_user/2]).


start(Host, Opts) ->
    gen_iq_handler:add_iq_handler(ejabberd_local, Host, ?NS_WHISPER, ?MODULE, process_local_iq),
    ejabberd_hooks:add(remove_user, Host, ?MODULE, remove_user, 40),
    mod_whisper_mnesia:init(Host, Opts),
    ok.

stop(Host) ->
    mod_whisper_mnesia:close(Host),
    gen_iq_handler:remove_iq_handler(ejabberd_local, Host, ?NS_WHISPER),
    ejabberd_hooks:delete(remove_user, Host, ?MODULE, remove_user, 40),
    ok.

depends(_Host, _Opts) ->
    [].

mod_options(_Host) ->
    [].

reload(_Host, _NewOpts, _OldOpts) ->
    ok.


%%====================================================================
%% iq handlers
%%====================================================================

process_local_iq(#iq{from = #jid{luser = User, lserver = Server}, lang = Lang, type = set,
                    sub_els = [#whisper_keys{identity_key = IdentityKey, 
                                             signed_key = SignedKey,
                                             one_time_keys = OneTimeKeys}]} = IQ) ->
    Username = jid:to_string(jid:make(User, Server)),
    case IdentityKey =/= undefined andalso SignedKey =/= undefined andalso
         OneTimeKeys =/= [] of
         true ->
             mod_whisper_mnesia:insert_keys(Username, IdentityKey, SignedKey, OneTimeKeys),
             xmpp:make_iq_result(IQ);
         false ->
            Txt = ?T("Invalid request"),
            xmpp:make_error(IQ, xmpp:err_bad_request(Txt, Lang))
    end;

process_local_iq(#iq{from = #jid{luser = _User, lserver = _Server}, lang = Lang, type = get,
                    sub_els = [#whisper_keys{username = Username}]} = IQ) ->
    %%TODO(murali@): check if user is allowed to access keys of username.
    case Username of
        undefined ->
            Txt = ?T("Invalid request"),
            xmpp:make_error(IQ, xmpp:err_bad_request(Txt, Lang));
        _ ->
            case mod_whisper_mnesia:fetch_key_set_and_delete(Username) of
              {ok, WhisperKeySet} ->
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



