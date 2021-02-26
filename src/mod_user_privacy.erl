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

%% Export all functions for unit tests
-ifdef(TEST).
-compile(export_all).
-endif.

%% gen_mod API
-export([start/2, stop/1, reload/3, depends/2, mod_options/1]).

%% iq handler and API.
-export([
    process_local_iq/1,
    privacy_check_packet/4,
    get_privacy_type/1,
    remove_user/2
]).

-type c2s_state() :: ejabberd_c2s:state().

%%====================================================================
%% gen_mod API.
%%====================================================================

start(Host, _Opts) ->
    ?INFO("start", []),
    gen_iq_handler:add_iq_handler(ejabberd_local, Host, pb_privacy_list, ?MODULE, process_local_iq),
    gen_iq_handler:add_iq_handler(ejabberd_local, Host, pb_privacy_lists, ?MODULE, process_local_iq),
    ejabberd_hooks:add(privacy_check_packet, Host, ?MODULE, privacy_check_packet, 30),
    ejabberd_hooks:add(remove_user, Host, ?MODULE, remove_user, 50),
    ok.

stop(Host) ->
    ?INFO("stop", []),
    gen_iq_handler:remove_iq_handler(ejabberd_local, Host, pb_privacy_list),
    gen_iq_handler:remove_iq_handler(ejabberd_local, Host, pb_privacy_lists),
    ejabberd_hooks:delete(privacy_check_packet, Host, ?MODULE, privacy_check_packet, 30),
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
        payload = #pb_privacy_list{type = Type, hash = HashValue, uid_elements = UidEls}} = IQ) ->
    ?INFO("Uid: ~s, set-iq for privacy_list, type: ~p", [Uid, Type]),
    case update_privacy_type(Uid, Type, HashValue, UidEls) of
        ok ->
            util_pb:make_iq_result(IQ);
        {error, hash_mismatch, ServerHashValue} ->
            ?WARNING("Uid: ~s, hash_mismatch type: ~p", [Uid, Type]),
            util_pb:make_error(IQ, #pb_privacy_list_result{
                    result = <<"failed">>, reason = <<"hash_mismatch">>, hash = ServerHashValue});
        {error, invalid_type} ->
            ?WARNING("Uid: ~s, invalid privacy_list_type: ~p", [Uid, Type]),
            util_pb:make_error(IQ, util:err(invalid_type));
        {error, unexcepted_uids} ->
            ?WARNING("Uid: ~s, unexcepted_uids for type: ~p", [Uid, Type]),
            util_pb:make_error(IQ, util:err(unexcepted_uids))
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
    util_pb:make_iq_result(IQ,
            #pb_privacy_lists{
                active_type = ActiveType,
                lists = UserPrivacyLists
            });
process_local_iq(#pb_iq{} = IQ) ->
    util_pb:make_error(IQ, util:err(invalid_request)).


-spec privacy_check_packet(Acc :: allow | deny, State :: c2s_state(),
        Packet :: stanza(), Dir :: in | out) -> allow | deny | {stop, deny}.
%% When routing, handle privacy_checks from the receiver's perspective for messages.
%% This hook runs just before storing these message stanzas.
privacy_check_packet(allow, _State, #message{} = Packet, in = Dir) ->
    #jid{luser = FromUid} = xmpp:get_from(Packet),
    PayloadType = util:get_payload_type(Packet),
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

privacy_check_packet(allow, _State, #pb_presence{type = Type} = Packet, out = Dir)
        when Type =:= subscribe; Type =:= unsubscribe ->
    %% inspect requests to another user's presence.
    check_blocked(Packet, Dir);

privacy_check_packet(allow, _State, #pb_chat_state{thread_type = group_chat} = _Packet, out) ->
    %% always allow typing indicators in groups.
    allow;

privacy_check_packet(allow, _State, #pb_chat_state{} = Packet, out = Dir) ->
    %% inspect sending chat_state updates to another user.
    check_blocked(Packet, Dir);

privacy_check_packet(allow, _State, #message{type = groupchat}, out = _Dir) ->
    %% always allow all group_chat stanzas.
    allow;
privacy_check_packet(allow, _State, #message{} = Packet, out = Dir) ->
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
    model_privacy:remove_user(Uid),
    ok.


%%====================================================================
%% internal functions.
%%====================================================================

%% We allow message payloads of types: delivery_receipts, seen_receipts,
%% group_chats and retract stanzas between any users including blocked users.
%% For all other stanzas/categories: we are not sure.
%% since we need to check the relationship between the sender and receiver.
-spec is_payload_always_allowed(PayloadType :: atom()) -> boolean().
is_payload_always_allowed(receipt_response) -> true;
is_payload_always_allowed(receipt_seen) -> true;
is_payload_always_allowed(group_chat) -> true;
is_payload_always_allowed(chat_retract_st) -> true;
is_payload_always_allowed(groupchat_retract_st) -> true;
is_payload_always_allowed(group_st) -> true;
is_payload_always_allowed(_) -> false.



-spec check_blocked(Packet :: stanza(), Dir :: in | out) -> allow | deny.
check_blocked(#chat_state{thread_id = ThreadId, thread_type = chat} = Packet, out = Dir) ->
    #jid{luser = FromUid} = xmpp:get_from(Packet),
    ToUid = ThreadId,
    check_blocked(FromUid, ToUid, Packet, Dir);
check_blocked(Packet, Dir) ->
    FromUid = util_pb:get_from(Packet),
    ToUid = util_pb:get_to(Packet),
    check_blocked(FromUid, ToUid, Packet, Dir).


-spec check_blocked(FromUid :: binary(), ToUid :: binary(),
        Packet :: stanza(), Dir :: in | out) -> allow | deny.
check_blocked(FromUid, ToUid, Packet, Dir) ->
    Id = util_pb:get_id(Packet),
    PacketType = element(1, Packet),
    IsBlocked = case Dir of
        in -> model_privacy:is_blocked(ToUid, FromUid);
        out -> model_privacy:is_blocked(FromUid, ToUid)
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
    {error, unexcepted_uids};
update_privacy_type(_Uid, _, _, _) ->
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
update_privacy_list(_Uid, _Type, _ClientHashValue, []) -> ok;
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
            case DeleteUids of
                [] -> ok;
                _ -> remove_uids_from_privacy_list(Uid, Type, DeleteUids)
            end,
            case AddUids of
                [] -> ok;
                _ -> add_uids_to_privacy_list(Uid, Type, AddUids)
            end,
            ok;
        false ->
            ?ERROR("Uid: ~s, Type: ~s, hash_mismatch, ClientHash: ~p, ServerHash: ~p",
                    [Uid, Type, ClientHashValue, ServerHashValue]),
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


-spec remove_uids_from_privacy_list(Uid :: binary(),
        Type :: privacy_list_type(), Ouids :: list(binary())) -> ok.
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
    model_privacy:remove_only_uids(Uid, Ouids),
    Server = util:get_host(),
    ejabberd_hooks:run(block_uids, Server, [Uid, Server, Ouids]),
    model_privacy:block_uids(Uid, Ouids),
    stat:count(?STAT_PRIVACY, "block", length(Ouids)),
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
    UidEls = lists:map(
        fun(Ouid) ->
            #pb_uid_element{uid = Ouid}
        end, Ouids),
    PrivacyList = #pb_privacy_list{type = Type, uid_elements = UidEls},
    get_privacy_lists(Uid, Rest, [PrivacyList | Result]).


-spec extract_uid(UidEl :: pb_uid_element()) -> binary().
extract_uid(#pb_uid_element{uid = Uid}) -> Uid.

-spec log_counters(ServerHashValue :: binary(), ClientHashValue :: binary() | undefined) -> ok.
log_counters(_, undefined) ->
    ?INFO("ClientHashValue is undefined"),
    stat:count(?STAT_PRIVACY, "hash_undefined");
log_counters(Hash, Hash) ->
    stat:count(?STAT_PRIVACY, "hash_match");
log_counters(_, _) ->
    stat:count(?STAT_PRIVACY, "hash_mismatch").

