%%%-----------------------------------------------------------------------------------
%%% File    : mod_user_privacy.erl
%%%
%%% Copyright (C) 2020 halloappinc.
%%%
%%%
%%%-----------------------------------------------------------------------------------

-module(mod_user_privacy).
-author('murali').
-behaviour(gen_mod).

-include("logger.hrl").
-include("xmpp.hrl").
-include("packets.hrl").

-define(STAT_PRIVACY, "HA/Privacy").
-define(COMMA_CHAR, <<",">>).
-define(HASH_FUNC, sha256).

-type phone_el() :: #pb_phone_element{}.

-ifdef(TEST).
-export([update_privacy_type/4, update_privacy_type2/4]).
-endif.

%% gen_mod API
-export([start/2, stop/1, reload/3, depends/2, mod_options/1]).

%% iq handler and API.
-export([
    process_local_iq/1,
    privacy_check_packet/4,
    get_privacy_type/1,
    remove_user/2,
    register_user/4
]).


%%====================================================================
%% gen_mod API.
%%====================================================================

start(Host, _Opts) ->
    ?INFO("start", []),
    gen_iq_handler:add_iq_handler(ejabberd_local, Host, pb_privacy_list, ?MODULE, process_local_iq),
    gen_iq_handler:add_iq_handler(ejabberd_local, Host, pb_privacy_lists, ?MODULE, process_local_iq),
    ejabberd_hooks:add(privacy_check_packet, Host, ?MODULE, privacy_check_packet, 30),
    ejabberd_hooks:add(register_user, Host, ?MODULE, register_user, 50),
    ejabberd_hooks:add(remove_user, Host, ?MODULE, remove_user, 50),
    ok.

stop(Host) ->
    ?INFO("stop", []),
    gen_iq_handler:remove_iq_handler(ejabberd_local, Host, pb_privacy_list),
    gen_iq_handler:remove_iq_handler(ejabberd_local, Host, pb_privacy_lists),
    ejabberd_hooks:delete(privacy_check_packet, Host, ?MODULE, privacy_check_packet, 30),
    ejabberd_hooks:delete(register_user, Host, ?MODULE, register_user, 50),
    ejabberd_hooks:delete(remove_user, Host, ?MODULE, remove_user, 50),
    ok.

depends(_Host, _Opts) ->
    [].

reload(_Host, _NewOpts, _OldOpts) ->
    ok.

mod_options(_Host) ->
    [].


%%====================================================================
%% IQ handlers and hooks.
%%====================================================================


-spec process_local_iq(IQ :: pb_iq()) -> pb_iq().
process_local_iq(#pb_iq{from_uid = Uid, type = set,
        payload = #pb_privacy_list{type = Type, hash = HashValue,
        uid_elements = UidEls, phone_elements = [], using_phones = false}} = IQ) ->
    ?INFO("Uid: ~s, set-iq for privacy_list, type: ~p", [Uid, Type]),
    case update_privacy_type(Uid, Type, HashValue, UidEls) of
        ok ->
            pb:make_iq_result(IQ);
        {error, hash_mismatch, _ServerHashValue} ->
            ?WARNING("Uid: ~s, hash_mismatch type: ~p", [Uid, Type]),
            pb:make_error(IQ, util:err(hash_mismatch));
        {error, invalid_type} ->
            ?WARNING("Uid: ~s, invalid privacy_list_type: ~p", [Uid, Type]),
            pb:make_error(IQ, util:err(invalid_type));
        {error, unexpected_uids} ->
            ?WARNING("Uid: ~s, unexpected_uids for type: ~p", [Uid, Type]),
            pb:make_error(IQ, util:err(unexpected_uids))
    end;
%% Use Uid's client_version to filter out requests.
process_local_iq(#pb_iq{from_uid = Uid, type = set,
        payload = #pb_privacy_list{type = Type, hash = HashValue,
        uid_elements = [], phone_elements = PhoneEls, using_phones = true}} = IQ) ->
    ?INFO("Uid: ~s, set-iq for privacy_list, type: ~p", [Uid, Type]),
    case update_privacy_type2(Uid, Type, HashValue, PhoneEls) of
        ok ->
            pb:make_iq_result(IQ);
        {error, hash_mismatch, _ServerHashValue} ->
            ?WARNING("Uid: ~s, hash_mismatch type: ~p", [Uid, Type]),
            pb:make_error(IQ, util:err(hash_mismatch));
        {error, invalid_type} ->
            ?WARNING("Uid: ~s, invalid privacy_list_type: ~p", [Uid, Type]),
            pb:make_error(IQ, util:err(invalid_type));
        {error, unexpected_phones} ->
            ?WARNING("Uid: ~s, unexpected_phones for type: ~p", [Uid, Type]),
            pb:make_error(IQ, util:err(unexpected_phones))
    end;
process_local_iq(#pb_iq{from_uid = Uid, type = get,
        payload = #pb_privacy_lists{lists = PrivacyLists}} = IQ) ->
    ?INFO("Uid: ~s, get-iq for privacy_list", [Uid]),
    ListTypes = lists:map(fun(#pb_privacy_list{type = Type}) -> Type end, PrivacyLists),
    Types = case ListTypes of
        [] -> [except, only, mute, block];
        _ -> ListTypes
    end,
    UserPrivacyLists = get_privacy_lists(Uid, Types),
    ActiveType = get_privacy_type(Uid),
    pb:make_iq_result(IQ,
            #pb_privacy_lists{
                active_type = ActiveType,
                lists = UserPrivacyLists
            });
process_local_iq(#pb_iq{} = IQ) ->
    pb:make_error(IQ, util:err(invalid_request)).


-spec privacy_check_packet(Acc :: allow | deny, State :: halloapp_c2s:state(),
        Packet :: stanza(), Dir :: in | out) -> allow | deny | {stop, deny}.
%% When routing, handle privacy_checks from the receiver's perspective for messages.
%% This hook runs just before storing these message stanzas.
privacy_check_packet(allow, _State, #pb_msg{} = Packet, in = Dir) ->
    FromUid = pb:get_from(Packet),
    PayloadType = pb:get_payload_type(Packet),
    case FromUid =:= undefined orelse FromUid =:= <<>> of
        true -> allow;  %% Allow server generated messages.
        false ->
            %% Else check payload and inspect these messages.
            case is_payload_always_allowed(PayloadType) of
                true -> allow;
                false -> check_blocked(Packet, Dir)
            end
    end;

privacy_check_packet(allow, _State, #pb_presence{type = Type} = Packet, in = Dir)
        when Type =:= available; Type =:= away ->
    %% inspect the addresses for presence stanzas sent by the server.
    check_blocked(Packet, Dir);

privacy_check_packet(allow, _State, #pb_chat_state{thread_type = group_chat} = _Packet, in) ->
    %% always allow typing indicators in groups.
    allow;

privacy_check_packet(allow, _State, #pb_chat_state{} = Packet, in = Dir) ->
    %% inspect the addresses for chat_state stanzas sent by the server.
    check_blocked(Packet, Dir);


%% Now the following runs on the sender's c2s process on outgoing packets.
%% Runs on senders c2s process.
privacy_check_packet(allow, _State, #pb_presence{type = Type}, out = _Dir)
        when Type =:= available; Type =:= away ->
    %% always allow presence stanzas updating their own status.
    allow;

privacy_check_packet(allow, _State, #pb_presence{type = Type} = Packet, out = _Dir)
        when Type =:= subscribe; Type =:= unsubscribe ->
    %% inspect requests to another user's presence.
    %% subscribe and unsubscribe requests must be checked from receiver's perspective.
    %% so we reverse the direction and then check for blocked.
    check_blocked(Packet, in);

privacy_check_packet(allow, _State, #pb_chat_state{thread_type = group_chat} = _Packet, out) ->
    %% always allow typing indicators in groups.
    allow;

privacy_check_packet(allow, _State, #pb_chat_state{} = Packet, out = Dir) ->
    %% inspect sending chat_state updates to another user.
    check_blocked(Packet, Dir);

privacy_check_packet(allow, _State, #pb_msg{type = groupchat}, out = _Dir) ->
    %% always allow all group_chat stanzas.
    allow;
privacy_check_packet(allow, _State, #pb_msg{} = Packet, out = Dir) ->
    %% check payload and then inspect addresses if necessary.
    PayloadType = util:get_payload_type(Packet),
    case is_payload_always_allowed(PayloadType) of
        true -> allow;
        false -> check_blocked(Packet, Dir)
    end;

privacy_check_packet(deny, _State, _Pkt, _Dir) ->
    deny.


-spec remove_user(Uid :: binary(), Server :: binary()) -> ok.
remove_user(Uid, _Server) ->
    %% TODO (murali@): Update hook to include phone.
    {ok, Phone} = model_accounts:get_phone(Uid),
    model_privacy:remove_user(Uid, Phone),
    ok.


-spec register_user(Uid :: binary(), Server :: binary(), Phone :: binary(), CampaignId :: binary()) -> ok.
register_user(Uid, _Server, Phone, _CampaignId) ->
    ?INFO("Uid: ~p, Phone: ~p", [Uid, Phone]),
    model_privacy:register_user(Uid, Phone),
    ok.


%%====================================================================
%% internal functions.
%%====================================================================

%% TODO: add tests for all kinds of stanzas.
%% We allow message payloads of types: delivery_receipts, seen_receipts,
%% group_chats, group_feed and retract stanzas between any users including blocked users.
%% For all other stanzas/categories: we are not sure.
%% since we need to check the relationship between the sender and receiver.
-spec is_payload_always_allowed(PayloadType :: atom()) -> boolean().
%% seen and delivery receipts.
is_payload_always_allowed(pb_seen_receipt) -> true;
is_payload_always_allowed(pb_delivery_receipt) -> true;
is_payload_always_allowed(pb_screenshot_receipt) -> true;
%% group stanzas.
is_payload_always_allowed(pb_group_stanza) -> true;
%% group chat stanzas.
is_payload_always_allowed(pb_group_chat) -> true;
is_payload_always_allowed(pb_groupchat_retract) -> true;
%% group feed stanzas.
is_payload_always_allowed(pb_group_feed_item) -> true;
is_payload_always_allowed(pb_group_feed_items) -> true;
is_payload_always_allowed(pb_group_feed_rerequest) -> true;
%% server generated.
is_payload_always_allowed(pb_end_of_queue) -> true;
is_payload_always_allowed(pb_error_stanza) -> true;
%% everything else.
is_payload_always_allowed(_) -> false.


-spec check_blocked(Packet :: stanza(), Dir :: in | out) -> allow | deny.
check_blocked(#pb_chat_state{thread_id = ThreadId, thread_type = chat} = Packet, out = Dir) ->
    FromUid = pb:get_from(Packet),
    ToUid = ThreadId,
    check_blocked(FromUid, ToUid, Packet, Dir);
check_blocked(Packet, Dir) ->
    FromUid = pb:get_from(Packet),
    ToUid = pb:get_to(Packet),
    check_blocked(FromUid, ToUid, Packet, Dir).


-spec check_blocked(FromUid :: binary(), ToUid :: binary(),
        Packet :: stanza(), Dir :: in | out) -> allow | deny.
check_blocked(FromUid, ToUid, Packet, Dir) ->
    Id = pb:get_id(Packet),
    PacketType = element(1, Packet),
    IsBlocked = case Dir of
        %% Use updated functions here to check both old and new keys.
        in -> model_privacy:is_blocked2(ToUid, FromUid);
        out -> model_privacy:is_blocked2(FromUid, ToUid)
    end,
    case IsBlocked of
        true ->
            ?INFO("Blocked PacketType: ~p Id: ~p, from-uid: ~s to-uid: ~s",
                    [PacketType, Id, FromUid, ToUid]),
            deny;
        false -> allow
    end.


%% TODO(murali@): counts for switching privacy modes will involve another redis call.
-spec update_privacy_type(Uid :: binary(), Type :: privacy_list_type(),
        HashValue :: binary(), UidEls :: list(binary())) -> ok | {error, any(), any()}.
update_privacy_type(Uid, all = Type, _HashValue, []) ->
    set_privacy_type(Uid, Type),
    stat:count(?STAT_PRIVACY, "all"),
    ok;
update_privacy_type(Uid, Type, HashValue, UidEls) when Type =:= except; Type =:= only ->
    case update_privacy_list(Uid, Type, HashValue, UidEls) of
        ok ->
            set_privacy_type(Uid, Type),
            stat:count(?STAT_PRIVACY, atom_to_list(Type)),
            ok;
        {error, _Reason, _ServerHashValue} = Error ->
            Error
    end;
update_privacy_type(Uid, Type, HashValue, UidEls) when Type =:= mute; Type =:= block ->
    update_privacy_list(Uid, Type, HashValue, UidEls);
update_privacy_type(_Uid, all, _, _) ->
    {error, unexpected_uids};
update_privacy_type(_Uid, _, _, _) ->
    {error, invalid_type}.


%% for phone-based privacy lists.
-spec update_privacy_type2(Uid :: binary(), Type :: privacy_list_type(),
        HashValue :: binary(), PhoneEls :: list(binary())) -> ok | {error, any(), any()}.
update_privacy_type2(Uid, all = Type, _HashValue, []) ->
    set_privacy_type(Uid, Type),
    stat:count(?STAT_PRIVACY, "all_phones"),
    ok;
update_privacy_type2(Uid, Type, HashValue, PhoneEls) when Type =:= except; Type =:= only ->
    case update_privacy_list2(Uid, Type, HashValue, PhoneEls) of
        ok ->
            set_privacy_type(Uid, Type),
            stat:count(?STAT_PRIVACY, atom_to_list(Type) ++ "_phones"),
            ok;
        {error, _Reason, _ServerHashValue} = Error ->
            Error
    end;
update_privacy_type2(Uid, Type, HashValue, PhoneEls) when Type =:= mute; Type =:= block ->
    update_privacy_list2(Uid, Type, HashValue, PhoneEls);
update_privacy_type2(_Uid, all, _, _) ->
    {error, unexpected_phones};
update_privacy_type2(_Uid, _, _, _) ->
    {error, invalid_type}.


-spec set_privacy_type(Uid :: binary(), Type :: privacy_type()) -> ok.
set_privacy_type(Uid, Type) ->
    ?INFO("Uid: ~s, privacy_type: ~p", [Uid, Type]),
    model_privacy:set_privacy_type(Uid, Type).


-spec get_privacy_type(Uid :: binary()) -> privacy_type().
get_privacy_type(Uid) ->
    {ok, Type} = model_privacy:get_privacy_type(Uid),
    ?INFO("Uid: ~s, privacy_type: ~p", [Uid, Type]),
    Type.


-spec update_privacy_list(Uid :: binary(), Type :: privacy_list_type(),
        ClientHashValue :: binary(), UidEls :: list(uid_el())) -> ok.
update_privacy_list(Uid, Type, ClientHashValue, UidEls) ->
    {DeleteUidsList, AddUidsList} = lists:partition(
            fun(#pb_uid_element{action = T}) ->
                T =:= delete
            end, UidEls),
    DeleteUids = lists:map(fun extract_uid/1, DeleteUidsList),
    AddUids = lists:map(fun extract_uid/1, AddUidsList),
    ?INFO("Uid: ~s, Type: ~p, DeleteUids: ~p, AddUids: ~p", [Uid, Type, DeleteUids, AddUids]),
    ServerHashValue = compute_hash_value(Uid, Type, DeleteUids, AddUids),
    log_counters(ServerHashValue, ClientHashValue),
    %% TODO(murali@): remove support for undefined hash values here.
    case ServerHashValue =:= ClientHashValue orelse ClientHashValue =:= undefined of
        true ->
            ?INFO("Uid: ~s, Type: ~s, hash values match", [Uid, Type]),
            remove_uids_from_privacy_list(Uid, Type, DeleteUids),
            add_uids_to_privacy_list(Uid, Type, AddUids),
            ok;
        false ->
            ?ERROR("Uid: ~s, Type: ~s, hash_mismatch, ClientHash(b64): ~p, ServerHash(b64): ~p",
                    [Uid, Type, base64url:encode(ClientHashValue), base64url:encode(ServerHashValue)]),
            {error, hash_mismatch, ServerHashValue}
    end.


%% for phone-based privacy lists.
-spec update_privacy_list2(Uid :: binary(), Type :: privacy_list_type(),
        ClientHashValue :: binary(), PhoneEls :: list(phone_el())) -> ok.
update_privacy_list2(Uid, Type, ClientHashValue, PhoneEls) ->
    {DeletePhonesList, AddPhonesList} = lists:partition(
            fun(#pb_phone_element{action = T}) ->
                T =:= delete
            end, PhoneEls),
    DeletePhones = lists:map(fun extract_phone/1, DeletePhonesList),
    AddPhones = lists:map(fun extract_phone/1, AddPhonesList),
    ?INFO("Uid: ~s, Type: ~p, DeletePhones: ~p, AddPhones: ~p", [Uid, Type, DeletePhones, AddPhones]),
    ServerHashValue = compute_hash_value2(Uid, Type, DeletePhones, AddPhones),
    log_counters(ServerHashValue, ClientHashValue),
    case ServerHashValue =:= ClientHashValue of
        true ->
            ?INFO("Uid: ~s, Type: ~s, hash values match", [Uid, Type]),
            remove_phones_from_privacy_list(Uid, Type, DeletePhones),
            add_phones_to_privacy_list(Uid, Type, AddPhones),
            ok;
        false ->
            ?ERROR("Uid: ~s, Type: ~s, hash_mismatch, ClientHash(b64): ~p, ServerHash(b64): ~p",
                    [Uid, Type, base64url:encode(ClientHashValue), base64url:encode(ServerHashValue)]),
            {error, hash_mismatch, ServerHashValue}
    end.


-spec compute_hash_value(Uid :: binary(), Type :: privacy_list_type(),
        DeleteUids :: [binary()], AddUids :: [binary()]) -> binary().
compute_hash_value(Uid, Type, DeleteUids, AddUids) ->
    {ok, Ouids} = case Type of
        except -> model_privacy:get_except_uids(Uid);
        only -> model_privacy:get_only_uids(Uid);
        mute -> model_privacy:get_mutelist_uids(Uid);
        block -> model_privacy:get_blocked_uids(Uid)
    end,
    OuidsSet = sets:from_list(Ouids),
    DeleteSet = sets:from_list(DeleteUids),
    AddSet = sets:from_list(AddUids),
    FinalList = sets:to_list(sets:union(sets:subtract(OuidsSet, DeleteSet), AddSet)),
    FinalString = util:join_binary(?COMMA_CHAR, lists:sort(FinalList), <<>>),
    HashValue = crypto:hash(?HASH_FUNC, FinalString),
    ?INFO("Uid: ~s, Type: ~p, HashValue: ~p", [Uid, Type, HashValue]),
    HashValue.


%% for phone-based privacy lists.
-spec compute_hash_value2(Uid :: binary(), Type :: privacy_list_type(),
        DeletePhones :: [binary()], AddPhones :: [binary()]) -> binary().
compute_hash_value2(Uid, Type, DeletePhones, AddPhones) ->
    {ok, OPhones} = case Type of
        except -> model_privacy:get_except_phones(Uid);
        only -> model_privacy:get_only_phones(Uid);
        mute -> model_privacy:get_mutelist_phones(Uid);
        block -> model_privacy:get_blocked_phones(Uid)
    end,
    OPhonesSet = sets:from_list(OPhones),
    DeleteSet = sets:from_list(DeletePhones),
    AddSet = sets:from_list(AddPhones),
    FinalList = sets:to_list(sets:union(sets:subtract(OPhonesSet, DeleteSet), AddSet)),
    FinalString = util:join_binary(?COMMA_CHAR, lists:sort(FinalList), <<>>),
    HashValue = crypto:hash(?HASH_FUNC, FinalString),
    ?INFO("Uid: ~s, Type: ~p, HashValue: ~p", [Uid, Type, HashValue]),
    HashValue.


-spec remove_uids_from_privacy_list(Uid :: binary(),
        Type :: privacy_list_type(), Ouids :: list(binary())) -> ok.
remove_uids_from_privacy_list(_Uid, _, []) -> ok;
remove_uids_from_privacy_list(Uid, except, Ouids) ->
    model_privacy:remove_except_uids(Uid, Ouids),
    stat:count(?STAT_PRIVACY, "remove_except", length(Ouids)),
    ok;
remove_uids_from_privacy_list(Uid, only, Ouids) ->
    model_privacy:remove_only_uids(Uid, Ouids),
    stat:count(?STAT_PRIVACY, "remove_only", length(Ouids)),
    ok;
remove_uids_from_privacy_list(Uid, mute, Ouids) ->
    model_privacy:unmute_uids(Uid, Ouids),
    stat:count(?STAT_PRIVACY, "unmute", length(Ouids)),
    ok;
remove_uids_from_privacy_list(Uid, block, Ouids) ->
    model_privacy:unblock_uids(Uid, Ouids),
    stat:count(?STAT_PRIVACY, "unblock", length(Ouids)),
    Server = util:get_host(),
    ejabberd_hooks:run(unblock_uids, Server, [Uid, Server, Ouids]).


-spec add_uids_to_privacy_list(Uid :: binary(),
        Type :: privacy_list_type(), Ouids :: list(binary())) -> ok.
add_uids_to_privacy_list(_Uid, _, []) -> ok;
add_uids_to_privacy_list(Uid, except, Ouids) ->
    model_privacy:add_except_uids(Uid, Ouids),
    stat:count(?STAT_PRIVACY, "add_except", length(Ouids)),
    ok;
add_uids_to_privacy_list(Uid, only, Ouids) ->
    model_privacy:add_only_uids(Uid, Ouids),
    stat:count(?STAT_PRIVACY, "add_only", length(Ouids)),
    ok;
add_uids_to_privacy_list(Uid, mute, Ouids) ->
    model_privacy:mute_uids(Uid, Ouids),
    stat:count(?STAT_PRIVACY, "mute", length(Ouids)),
    ok;
add_uids_to_privacy_list(Uid, block, Ouids) ->
    Server = util:get_host(),
    ejabberd_hooks:run(block_uids, Server, [Uid, Server, Ouids]),
    model_privacy:block_uids(Uid, Ouids),
    stat:count(?STAT_PRIVACY, "block", length(Ouids)),
    ok.


-spec remove_phones_from_privacy_list(Uid :: binary(),
        Type :: privacy_list_type(), Phones :: list(binary())) -> ok.
remove_phones_from_privacy_list(_Uid, _, []) -> ok;
remove_phones_from_privacy_list(Uid, except, Phones) ->
    model_privacy:remove_except_phones(Uid, Phones),
    stat:count(?STAT_PRIVACY, "remove_except_phones", length(Phones)),
    ok;
remove_phones_from_privacy_list(Uid, only, Phones) ->
    model_privacy:remove_only_phones(Uid, Phones),
    stat:count(?STAT_PRIVACY, "remove_only_phones", length(Phones)),
    ok;
remove_phones_from_privacy_list(Uid, mute, Phones) ->
    model_privacy:unmute_phones(Uid, Phones),
    stat:count(?STAT_PRIVACY, "unmute_phones", length(Phones)),
    ok;
remove_phones_from_privacy_list(Uid, block, Phones) ->
    Ouids = maps:values(model_phone:get_uids(Phones)),
    model_privacy:unblock_phones(Uid, Phones),
    stat:count(?STAT_PRIVACY, "unblock_phones", length(Phones)),
    Server = util:get_host(),
    ejabberd_hooks:run(unblock_uids, Server, [Uid, Server, Ouids]).


-spec add_phones_to_privacy_list(Uid :: binary(),
        Type :: privacy_list_type(), Phones :: list(binary())) -> ok.
add_phones_to_privacy_list(_Uid, _, []) -> ok;
add_phones_to_privacy_list(Uid, except, Phones) ->
    model_privacy:add_except_phones(Uid, Phones),
    stat:count(?STAT_PRIVACY, "add_except_phones", length(Phones)),
    ok;
add_phones_to_privacy_list(Uid, only, Phones) ->
    model_privacy:add_only_phones(Uid, Phones),
    stat:count(?STAT_PRIVACY, "add_only_phones", length(Phones)),
    ok;
add_phones_to_privacy_list(Uid, mute, Phones) ->
    model_privacy:mute_phones(Uid, Phones),
    stat:count(?STAT_PRIVACY, "mute_phones", length(Phones)),
    ok;
add_phones_to_privacy_list(Uid, block, Phones) ->
    Ouids = maps:values(model_phone:get_uids(Phones)),
    model_privacy:block_phones(Uid, Phones),
    stat:count(?STAT_PRIVACY, "block_phones", length(Phones)),
    Server = util:get_host(),
    ejabberd_hooks:run(block_uids, Server, [Uid, Server, Ouids]),
    ok.


-spec get_privacy_lists(Uid :: binary(),
        Types :: list(privacy_list_type())) -> list(user_privacy_lists()).
get_privacy_lists(Uid, Types) ->
    get_privacy_lists(Uid, Types, []).


-spec get_privacy_lists(Uid :: binary(),
        Types :: list(privacy_list_type()),
        Result :: list(user_privacy_lists())) -> list(user_privacy_lists()).
get_privacy_lists(_Uid, [], Result) ->
    Result;
get_privacy_lists(Uid, [Type | Rest], Result) ->
    {ok, Ouids} = case Type of
        except -> model_privacy:get_except_uids(Uid);
        only -> model_privacy:get_only_uids(Uid);
        mute -> model_privacy:get_mutelist_uids(Uid);
        block -> model_privacy:get_blocked_uids(Uid)
    end,
    {ok, Phones} = case Type of
        except -> model_privacy:get_except_phones(Uid);
        only -> model_privacy:get_only_phones(Uid);
        mute -> model_privacy:get_mutelist_phones(Uid);
        block -> model_privacy:get_blocked_phones(Uid)
    end,
    UidEls = lists:map(
        fun(Ouid) ->
            #pb_uid_element{uid = Ouid}
        end, Ouids),
    PhoneEls = lists:map(
        fun(Phone) ->
            #pb_phone_element{phone = Phone}
        end, Phones),
    PrivacyList = #pb_privacy_list{type = Type, uid_elements = UidEls, phone_elements = PhoneEls},
    get_privacy_lists(Uid, Rest, [PrivacyList | Result]).


-spec extract_uid(UidEl :: pb_uid_element()) -> binary().
extract_uid(#pb_uid_element{uid = Uid}) -> Uid.

-spec extract_phone(PhoneEl :: pb_phone_element()) -> binary().
extract_phone(#pb_phone_element{phone = Phone}) -> Phone.

-spec log_counters(ServerHashValue :: binary(), ClientHashValue :: binary() | undefined) -> ok.
log_counters(_, undefined) ->
    ?INFO("ClientHashValue is undefined"),
    stat:count(?STAT_PRIVACY, "hash_undefined");
log_counters(Hash, Hash) ->
    stat:count(?STAT_PRIVACY, "hash_match");
log_counters(_, _) ->
    stat:count(?STAT_PRIVACY, "hash_mismatch").

