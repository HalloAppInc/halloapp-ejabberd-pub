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
-include("whisper.hrl").
-include("ha_types.hrl").
-include("packets.hrl").

-define(MIN_OTP_KEY_COUNT, 10).

%% gen_mod API.
-export([start/2, stop/1, reload/3, depends/2, mod_options/1]).
%% IQ handlers and hooks.
-export([
    process_local_iq/1,
    notify_key_subscribers/2,
    set_keys_and_notify/4,
    remove_user/2,
    check_whisper_keys/3,
    refresh_otp_keys/1
]).


start(Host, _Opts) ->
    gen_iq_handler:add_iq_handler(ejabberd_local, Host, pb_whisper_keys, ?MODULE, process_local_iq),
    ejabberd_hooks:add(remove_user, Host, ?MODULE, remove_user, 40),
    ok.

stop(Host) ->
    gen_iq_handler:remove_iq_handler(ejabberd_local, Host, pb_whisper_keys),
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

%TODO: (nikola) This function will get deleted after clients migrate to setting the initial keys during registration.
process_local_iq(#pb_iq{from_uid = Uid, type = set,
        payload = #pb_whisper_keys{action = set} = WhisperKeys} = IQ) ->
    ?INFO("set_keys Uid: ~s", [Uid]),
    IdentityKey = util_parser:maybe_base64_encode(WhisperKeys#pb_whisper_keys.identity_key),
    SignedKey = util_parser:maybe_base64_encode(WhisperKeys#pb_whisper_keys.signed_key),
    OneTimeKeys = lists:map(
        fun(OneTimeKey) ->
            util_parser:maybe_base64_encode(OneTimeKey)
        end, WhisperKeys#pb_whisper_keys.one_time_keys),

    case check_whisper_keys(IdentityKey, SignedKey, OneTimeKeys) of
        {error, Reason} ->
            ?ERROR("Invalid iq Reason: ~p iq: ~p", [Reason, IQ]),
            pb:make_error(IQ, util:err(Reason));
        ok ->
            set_keys_and_notify(Uid, IdentityKey, SignedKey, OneTimeKeys),
            pb:make_iq_result(IQ)
    end;

process_local_iq(#pb_iq{from_uid = Uid, type = set,
        payload = #pb_whisper_keys{action = add} = WhisperKeys} = IQ) ->
    ?INFO("add_otp_keys Uid: ~s", [Uid]),
    IdentityKey = util_parser:maybe_base64_encode(WhisperKeys#pb_whisper_keys.identity_key),
    SignedKey = util_parser:maybe_base64_encode(WhisperKeys#pb_whisper_keys.signed_key),
    OneTimeKeys = lists:map(
        fun(OneTimeKey) ->
            util_parser:maybe_base64_encode(OneTimeKey)
        end, WhisperKeys#pb_whisper_keys.one_time_keys),

    case check_one_time_keys(OneTimeKeys) of
        {error, Reason} ->
            ?ERROR("Invalid iq Reason: ~p iq: ~p", [Reason, IQ]),
            pb:make_error(IQ, util:err(Reason));
        ok ->
            if
                IdentityKey =/= undefined ->
                    ?ERROR("Invalid iq: ~p", [IQ]),
                    pb:make_error(IQ, util:err(invalid_identity_key));
                SignedKey =/= undefined ->
                    ?ERROR("Invalid iq: ~p", [IQ]),
                    pb:make_error(IQ, util:err(invalid_signed_key));
                true ->
                    ?INFO("Uid: ~s, add_otp_keys", [Uid]),
                    model_whisper_keys:add_otp_keys(Uid, OneTimeKeys),
                    pb:make_iq_result(IQ)
            end
    end;

process_local_iq(#pb_iq{from_uid = Uid, type = get,
        payload = #pb_whisper_keys{action = count}} = IQ) ->
    {ok, Count} = model_whisper_keys:count_otp_keys(Uid),
    % TODO: we should return integer and not binary ideally. Will be fixed in pb
    pb:make_iq_result(IQ, #pb_whisper_keys{
        uid = Uid,
        action = normal, %TODO: We should one day switch to type = count, iOS is
        % currently depending on the normal type. Check with iOS team after 2021-04-01
        otp_key_count = Count});

process_local_iq(#pb_iq{from_uid = Uid, type = get,
        payload = #pb_whisper_keys{uid = Ouid, action = get}} = IQ) ->
    %%TODO(murali@): check if user is allowed to access keys of username.
    Server = util:get_host(),
    ?INFO("get_keys Uid: ~s, Ouid: ~s", [Uid, Ouid]),
    case Ouid of
        undefined ->
            ?ERROR("Invalid iq: ~p", [IQ]),
            pb:make_error(IQ, util:err(undefined_uid));
        _ ->
            {ok, WhisperKeySet} = model_whisper_keys:get_key_set(Ouid),
            case WhisperKeySet of
                undefined ->
                    pb:make_iq_result(IQ, #pb_whisper_keys{uid = Ouid});
                _ ->
                    %% Uid requests keys of Ouid to establish a session.
                    %% We need to add Uid as subscriber of Ouid's keys and vice-versa.
                    %% When a user resets their keys on the server: these subscribers are then notified.
                    ok = model_whisper_keys:add_key_subscriber(Ouid, Uid),
                    ok = model_whisper_keys:add_key_subscriber(Uid, Ouid),
                    check_count_and_notify_user(Ouid, Server),
                    IdentityKey = util_parser:maybe_base64_decode(WhisperKeySet#user_whisper_key_set.identity_key),
                    SignedKey = util_parser:maybe_base64_decode(WhisperKeySet#user_whisper_key_set.signed_key),
                    OneTimeKeys = case WhisperKeySet#user_whisper_key_set.one_time_key of
                        undefined -> [];
                        OneTimeKey -> [util_parser:maybe_base64_decode(OneTimeKey)]
                    end,
                    pb:make_iq_result(IQ, #pb_whisper_keys{uid = Ouid, identity_key = IdentityKey,
                            signed_key = SignedKey, one_time_keys = OneTimeKeys})
            end
    end.


-spec remove_user(Uid :: binary(), Server :: binary()) -> ok.
remove_user(Uid, _Server) ->
    ?INFO("Uid: ~s", [Uid]),
    model_whisper_keys:remove_all_keys(Uid),
    model_whisper_keys:remove_all_key_subscribers(Uid).


-spec check_whisper_keys(IdentityKeyB64 :: binary(), SignedKeyB64 :: binary(),
        OneTimeKeysB64 :: [binary()]) -> ok | {error, Reason :: any()}.
check_whisper_keys(_IdentityKeyB64, _SignedKeyB64, OneTimeKeysB64) when not is_list(OneTimeKeysB64) ->
    {error, invalid_one_time_keys};
check_whisper_keys(undefined, _SignedKeyB64, _OneTimeKeysB64) ->
    {error, undefined_identity_key};
check_whisper_keys(_IdentityKeyB64, undefined, _OneTimeKeysB64) ->
    {error, undefined_signed_key};
check_whisper_keys(IdentityKeyB64, SignedKeyB64, OneTimeKeysB64) ->
    case check_whisper_keys(IdentityKeyB64, SignedKeyB64) of
        {error, _Reason} = Err -> Err;
        ok ->
            check_one_time_keys(OneTimeKeysB64)
    end.


-spec refresh_otp_keys(Uid :: binary()) -> ok.
refresh_otp_keys(Uid) ->
    ?INFO("Uid: ~p", [Uid]),
    ok = model_whisper_keys:delete_all_otp_keys(Uid),
    ?INFO("deleted all otp keys, uid: ~p", [Uid]),
    Server = util:get_host(),
    ?INFO("trigger upload now, uid: ~p", [Uid]),
    check_count_and_notify_user(Uid, Server),
    ok.

%%====================================================================
%% internal functions
%%====================================================================


-spec check_whisper_keys(IdentityKeyB64 :: binary(), SignedKeyB64 :: binary())
            -> ok | {error, Reason :: any()}.
check_whisper_keys(IdentityKeyB64, SignedKeyB64) ->
    IsValidB64 = is_base64_encoded(IdentityKeyB64) and is_base64_encoded(SignedKeyB64),
    if
        not IsValidB64 -> {error, bad_base64_key};
        IdentityKeyB64 =:= <<>> -> {error, missing_identity_key};
        SignedKeyB64 =:= <<>> -> {error, missing_signed_key};
        byte_size(IdentityKeyB64) > ?MAX_KEY_SIZE -> {error, too_big_identity_key};
        byte_size(SignedKeyB64) > ?MAX_KEY_SIZE -> {error, too_big_signed_key};
        byte_size(IdentityKeyB64) < ?MIN_KEY_SIZE -> {error, too_small_identity_key};
        byte_size(SignedKeyB64) < ?MIN_KEY_SIZE -> {error, too_small_signed_key};
        true -> ok
    end.


-spec check_one_time_keys(OneTimeKeysB64 :: list(binary())) -> ok | {error, Reason :: any()}.
check_one_time_keys(OneTimeKeysB64) ->
    IsValidB64 = lists:all(fun (X) -> X end, lists:map(fun is_base64_encoded/1, OneTimeKeysB64)),
    TooBigOTK = lists:any(fun(K) -> byte_size(K) > ?MAX_KEY_SIZE end, OneTimeKeysB64),
    TooSmallOTK = lists:any(fun(K) -> byte_size(K) < ?MIN_KEY_SIZE end, OneTimeKeysB64),
    if
        not IsValidB64 -> {error, bad_base64_one_time_keys};
        length(OneTimeKeysB64) < ?MIN_OTK_LENGTH -> {error, too_few_one_time_keys};
        length(OneTimeKeysB64) > ?MAX_OTK_LENGTH -> {error, too_many_one_time_keys};
        TooBigOTK -> {error, too_big_one_time_keys};
        TooSmallOTK -> {error, too_small_one_time_keys};
        true -> ok
    end.


-spec check_count_and_notify_user(Uid :: binary(), Server :: binary()) -> ok.
check_count_and_notify_user(Uid, Server) ->
    {ok, Count} = model_whisper_keys:count_otp_keys(Uid),
    ?INFO("Uid: ~s, Count: ~p, MinCount: ~p", [Uid, Count, ?MIN_OTP_KEY_COUNT]),
    case Count < ?MIN_OTP_KEY_COUNT of
        true ->
            Message = #pb_msg{
                id = util:new_msg_id(),
                to_uid = Uid,
                payload = #pb_whisper_keys{uid = Uid, otp_key_count = Count}
            },
            ejabberd_router:route(Message);
        false ->
            ok
    end.


-spec set_keys_and_notify(Uid :: uid(), IdentityKey :: binary(), SignedKey :: binary(),
        OneTimeKeys :: [binary()]) -> ok.
set_keys_and_notify(Uid, IdentityKey, SignedKey, OneTimeKeys) ->
    ?INFO("Uid: ~s, set_keys", [Uid]),
    ok = model_whisper_keys:set_keys(Uid, IdentityKey, SignedKey, OneTimeKeys),
    ok = notify_key_subscribers(Uid, util:get_host()),
    ok.


-spec notify_key_subscribers(Uid :: binary(), Server :: binary()) -> ok.
notify_key_subscribers(Uid, Server) ->
    ?INFO("Uid: ~s", [Uid]),
    {ok, Ouids} = model_whisper_keys:get_all_key_subscribers(Uid),
    Packet = #pb_msg{
        id = util:new_msg_id(),
        payload = #pb_whisper_keys{action = update, uid = Uid}
    },
    ejabberd_router:route_multicast(<<>>, Ouids, Packet),
    ok.


is_base64_encoded(Data) ->
    try
        base64:decode(Data),
        true
    catch
        _Class : _Reason : _Stacktrace ->
            false
    end.
