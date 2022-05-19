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
-include("whisper.hrl").
-include("ha_types.hrl").
-include("packets.hrl").

-define(MIN_OTP_KEY_COUNT, 15).
-define(STAT_NS, "HA/whisper").

%% gen_mod API.
-export([start/2, stop/1, reload/3, depends/2, mod_options/1]).
%% IQ handlers and hooks.
-export([
    process_local_iq/1,
    notify_key_subscribers/2,
    set_keys_and_notify/4,
    remove_user/2,
    check_whisper_keys/3,
    c2s_session_opened/1,
    refresh_otp_keys/1
]).


start(Host, _Opts) ->
    gen_iq_handler:add_iq_handler(ejabberd_local, Host, pb_whisper_keys, ?MODULE, process_local_iq),
    gen_iq_handler:add_iq_handler(ejabberd_local, Host, pb_whisper_keys_collection, ?MODULE, process_local_iq),
    gen_iq_handler:add_iq_handler(ejabberd_local, Host, pb_trunc_whisper_keys_collection, ?MODULE, process_local_iq),
    ejabberd_hooks:add(c2s_session_opened, Host, ?MODULE, c2s_session_opened, 50),
    ejabberd_hooks:add(remove_user, Host, ?MODULE, remove_user, 40),
    ok.

stop(Host) ->
    gen_iq_handler:remove_iq_handler(ejabberd_local, Host, pb_whisper_keys),
    gen_iq_handler:remove_iq_handler(ejabberd_local, Host, pb_whisper_keys_collection),
    gen_iq_handler:remove_iq_handler(ejabberd_local, Host, pb_trunc_whisper_keys_collection),
    ejabberd_hooks:delete(c2s_session_opened, Host, ?MODULE, c2s_session_opened, 50),
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

%% TODO(murali@): add api to rotate signed keys.

process_local_iq(#pb_iq{from_uid = Uid, type = set,
        payload = #pb_whisper_keys{action = add} = WhisperKeys} = IQ) ->
    ?INFO("add_otp_keys Uid: ~s", [Uid]),
    IdentityKey = util:maybe_base64_encode(WhisperKeys#pb_whisper_keys.identity_key),
    SignedKey = util:maybe_base64_encode(WhisperKeys#pb_whisper_keys.signed_key),
    OneTimeKeys = lists:map(
        fun(OneTimeKey) ->
            util:maybe_base64_encode(OneTimeKey)
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
                    stat:count(?STAT_NS, "add_otp_keys"),
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
    ?INFO("get_keys Uid: ~s, Ouid: ~s", [Uid, Ouid]),
    AccountExists = model_accounts:account_exists(Ouid),
    case Ouid of
        undefined ->
            ?ERROR("Invalid iq: ~p", [IQ]),
            pb:make_error(IQ, util:err(undefined_uid));
        Uid ->
            %% We allow clients to fetch their own identity keys to ensure they are not out of sync.
            %% This query does not use any otp keys.
            {ok, WhisperKeySet} = model_whisper_keys:get_key_set_without_otp(Ouid),
            ?INFO("Uid: ~s requesting own keys: IK: ~p SK: ~p", [Uid,
                WhisperKeySet#user_whisper_key_set.identity_key,
                WhisperKeySet#user_whisper_key_set.signed_key]),
            IdentityKey = util:maybe_base64_decode(WhisperKeySet#user_whisper_key_set.identity_key),
            SignedKey = util:maybe_base64_decode(WhisperKeySet#user_whisper_key_set.signed_key),
            pb:make_iq_result(IQ,
                #pb_whisper_keys{
                    uid = Ouid,
                    identity_key = IdentityKey,
                    signed_key = SignedKey,
                    one_time_keys = []
                });
        _ ->
            case AccountExists of
                false ->
                    pb:make_error(IQ, util:err(invalid_uid));
                true ->
                    {IdentityKey, SignedKey, OneTimeKeys} = get_key_set(Ouid, Uid),
                    pb:make_iq_result(IQ,
                        #pb_whisper_keys{
                            uid = Ouid,
                            identity_key = IdentityKey,
                            signed_key = SignedKey,
                            one_time_keys = OneTimeKeys
                    })
            end
    end;

process_local_iq(#pb_iq{from_uid = Uid, type = get,
        payload = #pb_whisper_keys_collection{collection = Collection}} = IQ) ->
    Ouids = lists:filtermap(
        fun(#pb_whisper_keys{uid = Ouid}) ->
            %% Filter out own Uid and undefined uids.
            case Ouid =/= undefined andalso Ouid =/= Uid of
                true -> {true, Ouid};
                false -> false
            end
        end, Collection),
    ?INFO("get_keys Uid: ~s, Ouids: ~s", [Uid, Ouids]),

    case Ouids of
        [] ->
            ?ERROR("Invalid iq: ~p", [IQ]),
            pb:make_error(IQ, util:err(undefined_uids));
        _ ->
            Results = get_key_sets(Ouids, Uid),
            ResultsCollection = lists:zipwith(
                fun(Ouid, Result) ->
                    {IdentityKey, SignedKey, OneTimeKeys} = Result,
                    #pb_whisper_keys{
                        uid = Ouid,
                        identity_key = IdentityKey,
                        signed_key = SignedKey,
                        one_time_keys = OneTimeKeys
                    }
                end, Ouids, Results),
            pb:make_iq_result(IQ, #pb_whisper_keys_collection{collection = ResultsCollection})
    end;


process_local_iq(#pb_iq{from_uid = Uid, type = get,
        payload = #pb_trunc_whisper_keys_collection{collection = Collection}} = IQ) ->
    Ouids = [WhisperKeys#pb_trunc_whisper_keys.uid || WhisperKeys <- Collection,
                WhisperKeys#pb_trunc_whisper_keys.uid =/= undefined],
    ?INFO("get_trunc_identity_keys Uid: ~s, Ouids: ~p", [Uid, Ouids]),

    case Ouids of
        [] ->
            ?ERROR("Invalid iq: ~p", [IQ]),
            pb:make_error(IQ, util:err(undefined_uids));
        _ ->
            IdentityKeysMap = model_whisper_keys:get_identity_keys(Ouids),
            ResultCollection = construct_result(IdentityKeysMap, Ouids),
            pb:make_iq_result(IQ, #pb_trunc_whisper_keys_collection{collection = ResultCollection})
    end.


construct_result(IdentityKeysMap, Ouids) ->
    lists:filtermap(
        fun(Ouid) ->
            IdentityKeyBin = base64:decode(maps:get(Ouid, IdentityKeysMap, <<>>)),
            case IdentityKeyBin of
                <<>> ->
                    ?ERROR("Unable to find identity key for Uid: ~p", [Ouid]),
                    false;
                _ ->
                    try enif_protobuf:decode(IdentityKeyBin, pb_identity_key) of
                        #pb_identity_key{public_key = IPublicKey} ->
                            <<TruncIKey:?TRUNC_IKEY_LENGTH/binary, _Rest/binary>> = IPublicKey,
                            {true, #pb_trunc_whisper_keys{
                                uid = Ouid,
                                trunc_public_identity_key = TruncIKey
                            }}
                    catch Class : Reason : St ->
                        ?ERROR("failed to parse identity key: ~p, Uid: ~p",
                            [IdentityKeyBin, Ouid, lager:pr_stacktrace(St, {Class, Reason})]),
                        false
                    end
            end
        end, Ouids).
 
-spec remove_user(Uid :: binary(), Server :: binary()) -> ok.
remove_user(Uid, _Server) ->
    ?INFO("Uid: ~s", [Uid]),
    model_whisper_keys:remove_all_keys(Uid).


-spec c2s_session_opened(State :: #{}) -> #{}.
c2s_session_opened(#{user := Uid} = State) ->
    %% TODO: add tests for this first and then remove the check here.
    case config:is_testing_env() of
        true -> ok;
        false -> check_count_and_notify_user(Uid)
    end,
    State.


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
    ?INFO("trigger upload now, uid: ~p", [Uid]),
    check_count_and_notify_user(Uid),
    ok.

%%====================================================================
%% internal functions
%%====================================================================

%% Uid is requesting keyset of Ouid.
-spec get_key_set(Ouid :: binary(), Uid :: binary()) -> {binary(), binary(), [binary()]}.
get_key_set(Ouid, Uid) ->
    [KeySet] = get_key_sets([Ouid], Uid),
    KeySet.


-spec get_key_sets(Ouids :: [binary()], Uid :: binary()) -> [{binary(), binary(), [binary()]}].
get_key_sets(Ouids, Uid) ->
    {ok, WhisperKeySets} = model_whisper_keys:get_key_sets(Ouids),
    KeySets = lists:zipwith(
        fun(Ouid, WhisperKeySet) ->
            get_key_sets_info(Uid, Ouid, WhisperKeySet)
        end, Ouids, WhisperKeySets),
    KeySets.


-spec get_key_sets_info(Uid :: binary(), Ouid :: binary(),
        WhisperKeySet :: user_whisper_key_set()) -> {binary(), binary(), [binary()]}.
get_key_sets_info(Uid, Ouid, WhisperKeySet) ->
    case WhisperKeySet of
        undefined ->
            ?ERROR("Ouid: ~s WhisperKeySet is empty", [Ouid]),
            {undefined, undefined, []};
        _ ->
            %% Uid requests keys of Ouid to establish a session.
            check_count_and_notify_user(Ouid),
            ?INFO("Uid: ~s Ouid: ~s Ouid IK: ~p", [Uid, Ouid,
            WhisperKeySet#user_whisper_key_set.identity_key]),
            IdentityKey = util:maybe_base64_decode(WhisperKeySet#user_whisper_key_set.identity_key),
            SignedKey = util:maybe_base64_decode(WhisperKeySet#user_whisper_key_set.signed_key),
            OneTimeKeys = case WhisperKeySet#user_whisper_key_set.one_time_key of
                undefined ->
                    stat:count(?STAT_NS, "empty_otp_key_set"),
                    [];
                OneTimeKey ->
                    stat:count(?STAT_NS, "otp_key_set_ok"),
                    [util:maybe_base64_decode(OneTimeKey)]
            end,
            {IdentityKey, SignedKey, OneTimeKeys}
    end.


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


-spec check_count_and_notify_user(Uid :: binary()) -> ok.
check_count_and_notify_user(Uid) ->
    {ok, Count} = model_whisper_keys:count_otp_keys(Uid),
    ?INFO("Uid: ~s, Count: ~p, MinCount: ~p", [Uid, Count, ?MIN_OTP_KEY_COUNT]),
    case Count < ?MIN_OTP_KEY_COUNT of
        true ->
            Message = #pb_msg{
                id = util_id:new_msg_id(),
                to_uid = Uid,
                payload = #pb_whisper_keys{uid = Uid, otp_key_count = Count}
            },
            ejabberd_router:route(Message);
        false ->
            ok
    end.


-spec set_keys_and_notify(Uid :: uid(), IdentityKeyB64 :: binary(), SignedKeyB64 :: binary(),
        OneTimeKeysB64 :: [binary()]) -> ok.
set_keys_and_notify(Uid, IdentityKeyB64, SignedKeyB64, OneTimeKeysB64) ->
    ?INFO("Uid: ~s, set_keys IK: ~p SK: ~p", [Uid, IdentityKeyB64, SignedKeyB64]),
    ok = model_whisper_keys:set_keys(Uid, IdentityKeyB64, SignedKeyB64, OneTimeKeysB64),
    ok = notify_key_subscribers(Uid, IdentityKeyB64),
    ok.


-spec notify_key_subscribers(Uid :: binary(), IdentityKeyB64 :: binary()) -> ok.
notify_key_subscribers(Uid, IdentityKeyB64) ->
    ?INFO("Uid: ~s", [Uid]),
    %% We construct a list of potential subscribers and send the update notification to all of them.
    IdentityKey = util:maybe_base64_decode(IdentityKeyB64),

    %% Phone reverse index.
    case model_accounts:get_phone(Uid) of
        {ok, Phone} ->
            {ok, Ouids1} = model_contacts:get_contact_uids(Phone),
            %% Contact Phones. -- uid may not have any - since we clear contacts on registration.
            {ok, ContactPhones} = model_contacts:get_contacts(Uid),
            PhoneToUidMap = model_phone:get_uids(ContactPhones),
            Ouids2 = maps:values(PhoneToUidMap),

            %% GroupMember-Uids.
            %% TODO (murali@): make this a qmn query.
            Ouids3 = lists:merge(lists:map(fun model_groups:get_member_uids/1, model_groups:get_groups(Uid))),
            %% Ensure that we dont route the update message to ourselves.
            SubscriberUids = sets:to_list(sets:del_element(Uid, sets:from_list(Ouids1 ++ Ouids2 ++ Ouids3))),

            Packet = #pb_msg{
                id = util_id:new_msg_id(),
                payload = #pb_whisper_keys{action = update, uid = Uid, identity_key = IdentityKey}
            },
            ?INFO("Uid: ~s Notifying ~p Uids about key change", [Uid, length(SubscriberUids)]),
            ejabberd_router:route_multicast(<<>>, SubscriberUids, Packet);
        {error, missing} ->
            ?ERROR("Uid: ~s missing phone", [Uid])
    end,
    ok.


is_base64_encoded(Data) ->
    try
        base64:decode(Data),
        true
    catch
        _Class : _Reason : _Stacktrace ->
            false
    end.
