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
%%% iq-get stanza is used to get a key_set for a uid.
%%% Client needs to set its own keys using the iq-set stanza.
%%% Client can fetch someone else's keys using the iq-set stanza.
%%%----------------------------------------------------------------------

-module(mod_whisper).
-author('murali').
-behaviour(gen_mod).

-include("logger.hrl").
-include("xmpp.hrl").
-include("translate.hrl").
-include("whisper.hrl").

-define(NS_WHISPER, <<"halloapp:whisper:keys">>).
-define(MIN_OTP_KEY_COUNT, 10).

%% gen_mod API.
-export([start/2, stop/1, reload/3, depends/2, mod_options/1]).
%% IQ handlers and hooks.
-export([
    process_local_iq/1,
    remove_user/2,
    migrate_all_keys/0
]).


start(Host, _Opts) ->
    gen_iq_handler:add_iq_handler(ejabberd_local, Host, ?NS_WHISPER, ?MODULE, process_local_iq),
    ejabberd_hooks:add(remove_user, Host, ?MODULE, remove_user, 40),
    ok.

stop(Host) ->
    gen_iq_handler:remove_iq_handler(ejabberd_local, Host, ?NS_WHISPER),
    ejabberd_hooks:delete(remove_user, Host, ?MODULE, remove_user, 40),
    ok.

depends(_Host, _Opts) ->
    [].

reload(_Host, _NewOpts, _OldOpts) ->
    ok.

mod_options(_Host) ->
    [].


%%====================================================================
%% iq handlers
%%====================================================================

process_local_iq(#iq{from = #jid{luser = Uid, lserver = Server}, lang = Lang, type = set,
                    sub_els = [#whisper_keys{type = set} = WhisperKeys]} = IQ) ->
    ?INFO_MSG("set_keys Uid: ~s", [Uid]),
    IdentityKey = WhisperKeys#whisper_keys.identity_key,
    SignedKey = WhisperKeys#whisper_keys.signed_key,
    OneTimeKeys = WhisperKeys#whisper_keys.one_time_keys,
    if
        IdentityKey =:= undefined ->
            ?INFO_MSG("Uid: ~s, undefined identity_key", [Uid]),
            Txt = ?T("undefined IdentityKey"),
            xmpp:make_error(IQ, xmpp:err_bad_request(Txt, Lang));
        SignedKey =:= undefined ->
            ?INFO_MSG("Uid: ~s, undefined signed_key", [Uid]),
            Txt = ?T("undefined SignedKey"),
            xmpp:make_error(IQ, xmpp:err_bad_request(Txt, Lang));
        OneTimeKeys =:= [] ->
            ?INFO_MSG("Uid: ~s, empty one_time_keys", [Uid]),
            Txt = ?T("empty OneTimeKeys"),
            xmpp:make_error(IQ, xmpp:err_bad_request(Txt, Lang));
        true ->
            ?INFO_MSG("Uid: ~s, set_keys", [Uid]),
            ok = model_whisper_keys:set_keys(Uid, IdentityKey, SignedKey, OneTimeKeys),
            notify_key_subscribers(Uid, Server),
            xmpp:make_iq_result(IQ)
    end;

process_local_iq(#iq{from = #jid{luser = Uid}, lang = Lang, type = set,
                    sub_els = [#whisper_keys{type = add} = WhisperKeys]} = IQ) ->
    ?INFO_MSG("add_otp_keys Uid: ~s", [Uid]),
    IdentityKey = WhisperKeys#whisper_keys.identity_key,
    SignedKey = WhisperKeys#whisper_keys.signed_key,
    OneTimeKeys = WhisperKeys#whisper_keys.one_time_keys,
    if
        IdentityKey =/= undefined ->
            ?INFO_MSG("Uid: ~s, undefined identity_key", [Uid]),
            Txt = ?T("undefined IdentityKey"),
            xmpp:make_error(IQ, xmpp:err_bad_request(Txt, Lang));
        SignedKey =/= undefined ->
            ?INFO_MSG("Uid: ~s, undefined signed_key", [Uid]),
            Txt = ?T("undefined SignedKey"),
            xmpp:make_error(IQ, xmpp:err_bad_request(Txt, Lang));
        OneTimeKeys =:= [] ->
            ?INFO_MSG("Uid: ~s, empty one_time_keys", [Uid]),
            Txt = ?T("empty OneTimeKeys"),
            xmpp:make_error(IQ, xmpp:err_bad_request(Txt, Lang));
        true ->
            ?INFO_MSG("Uid: ~s, add_otp_keys", [Uid]),
            model_whisper_keys:add_otp_keys(Uid, OneTimeKeys),
            xmpp:make_iq_result(IQ)
    end;

process_local_iq(#iq{from = #jid{luser = Uid}, lang = _Lang, type = get,
                    sub_els = [#whisper_keys{type = count}]} = IQ) ->
    {ok, Count} = model_whisper_keys:count_otp_keys(Uid),
    xmpp:make_iq_result(IQ, #whisper_keys{uid = Uid, otp_key_count = integer_to_binary(Count)});

process_local_iq(#iq{from = #jid{luser = Uid, lserver = Server}, lang = Lang, type = get,
                    sub_els = [#whisper_keys{uid = Ouid, type = get}]} = IQ) ->
    %%TODO(murali@): check if user is allowed to access keys of username.
    ?INFO_MSG("get_keys Uid: ~s, Ouid: ~s", [Uid, Ouid]),
    case Ouid of
        undefined ->
            Txt = ?T("undefined uid"),
            xmpp:make_error(IQ, xmpp:err_bad_request(Txt, Lang));
        _ ->
            {ok, WhisperKeySet} = model_whisper_keys:get_key_set(Ouid),
            case WhisperKeySet of
                undefined ->
                    xmpp:make_iq_result(IQ, #whisper_keys{uid = Ouid});
                _ ->
                    %% Uid requests keys of Ouid to establish a session.
                    %% We need to add Uid as subscriber of Ouid's keys and vice-versa.
                    %% When a user resets their keys on the server: these subscribers are then notified.
                    ok = model_whisper_keys:add_key_subscriber(Ouid, Uid),
                    ok = model_whisper_keys:add_key_subscriber(Uid, Ouid),
                    check_count_and_notify_user(Ouid, Server),
                    IdentityKey = WhisperKeySet#user_whisper_key_set.identity_key,
                    SignedKey = WhisperKeySet#user_whisper_key_set.signed_key,
                    OneTimeKeys = case WhisperKeySet#user_whisper_key_set.one_time_key of
                        undefined -> [];
                        OneTimeKey -> [OneTimeKey]
                    end,
                    xmpp:make_iq_result(IQ, #whisper_keys{uid = Ouid, identity_key = IdentityKey,
                            signed_key = SignedKey, one_time_keys = OneTimeKeys})
            end
    end.


-spec remove_user(Uid :: binary(), Server :: binary()) -> ok.
remove_user(Uid, _Server) ->
    ?INFO_MSG("Uid: ~s", [Uid]),
    model_whisper_keys:remove_all_keys(Uid),
    model_whisper_keys:remove_all_key_subscribers(Uid).


%%====================================================================
%% internal functions
%%====================================================================


-spec check_count_and_notify_user(Uid :: binary(), Server :: binary()) -> ok.
check_count_and_notify_user(Uid, Server) ->
    {ok, Count} = model_whisper_keys:count_otp_keys(Uid),
    ?INFO_MSG("Uid: ~s, Count: ~p, MinCount: ~p", [Uid, Count, ?MIN_OTP_KEY_COUNT]),
    case Count < ?MIN_OTP_KEY_COUNT of
        true ->
            Message = #message{
                    id = util:new_msg_id(),
                    from = jid:make(Server),
                    to = jid:make(Uid, Server),
                    sub_els = [#whisper_keys{uid = Uid, otp_key_count = integer_to_binary(Count)}]
            },
            ejabberd_router:route(Message);
        false ->
            ok
    end.


-spec notify_key_subscribers(Uid :: binary(), Server :: binary()) -> ok.
notify_key_subscribers(Uid, Server) ->
    ?INFO_MSG("Uid: ~s", [Uid]),
    {ok, Ouids} = model_whisper_keys:get_all_key_subscribers(Uid),
    Ojids = util:uids_to_jids(Ouids, Server),
    From = jid:make(Server),
    Packet = #message{
        id = util:new_msg_id(),
        from = From,
        sub_els = [#whisper_keys{type = update, uid = Uid}]
    },
    ejabberd_router_multicast:route_multicast(From, Server, Ojids, Packet).


migrate_all_keys() ->
    UserWhisperKeys = mnesia:dirty_match_object(mnesia:table_info(user_whisper_keys, wild_pattern)),
    lists:foreach(
            fun(#user_whisper_keys{username = Username} = UserWhisperKey) ->
                UserOtpKeys = mnesia:dirty_match_object(#user_whisper_otp_keys{username = Username, _ = '_'}),
                migrate_all_user_keys(UserWhisperKey, UserOtpKeys)
            end, UserWhisperKeys).


migrate_all_user_keys(UserWhisperKey, UserOtpKeys) ->
    Username = UserWhisperKey#user_whisper_keys.username,
    #jid{luser = Uid} = jid:from_string(Username),
    IdentityKey = UserWhisperKey#user_whisper_keys.identity_key,
    SignedKey = UserWhisperKey#user_whisper_keys.signed_key,
    OtpKeys = lists:map(
            fun(#user_whisper_otp_keys{one_time_key = OtpKey}) ->
                OtpKey
            end, UserOtpKeys),
    model_whisper_keys:set_keys(Uid, IdentityKey, SignedKey, OtpKeys).



