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
-include("translate.hrl").

-define(NS_USER_PRIVACY, <<"halloapp:user:privacy">>).
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
    gen_iq_handler:add_iq_handler(ejabberd_local, Host, ?NS_USER_PRIVACY, ?MODULE, process_local_iq),
    ejabberd_hooks:add(privacy_check_packet, Host, ?MODULE, privacy_check_packet, 30),
    ejabberd_hooks:add(remove_user, Host, ?MODULE, remove_user, 50),
    ok.

stop(Host) ->
    ?INFO("stop", []),
    gen_iq_handler:remove_iq_handler(ejabberd_local, Host, ?NS_USER_PRIVACY),
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


-spec process_local_iq(IQ :: iq()) -> iq().
process_local_iq(#iq{from = #jid{luser = Uid, lserver = _Server}, type = set,
        sub_els = [#user_privacy_list{type = Type, hash = HashValue, uid_els = UidEls}]} = IQ) ->
    ?INFO("Uid: ~s, set-iq for privacy_list, type: ~p", [Uid, Type]),
    case update_privacy_type(Uid, Type, HashValue, UidEls) of
        ok ->
            xmpp:make_iq_result(IQ);
        {error, hash_mismatch, ServerHashValue} ->
            ?WARNING("Uid: ~s, hash_mismatch type: ~p", [Uid, Type]),
            xmpp:make_error(IQ, util:err(hash_mismatch, ServerHashValue));
        {error, invalid_type} ->
            ?WARNING("Uid: ~s, invalid privacy_list_type: ~p", [Uid, Type]),
            xmpp:make_error(IQ, util:err(invalid_type));
        {error, unexcepted_uids} ->
            ?WARNING("Uid: ~s, unexcepted_uids for type: ~p", [Uid, Type]),
            xmpp:make_error(IQ, util:err(unexcepted_uids))
    end;
process_local_iq(#iq{from = #jid{luser = Uid, lserver = _Server}, type = get,
        sub_els = [#user_privacy_lists{lists = PrivacyLists}]} = IQ) ->
    ?INFO("Uid: ~s, get-iq for privacy_list", [Uid]),
    ListTypes = lists:map(fun(#user_privacy_list{type = Type}) -> Type end, PrivacyLists),
    Types = case ListTypes of
        [] -> [except, only, mute, block];
        _ -> ListTypes
    end,
    UserPrivacyLists = get_privacy_lists(Uid, Types),
    ActiveType = get_privacy_type(Uid),
    xmpp:make_iq_result(IQ,
            #user_privacy_lists{
                active_type = ActiveType,
                lists = UserPrivacyLists
            });
process_local_iq(#iq{lang = Lang} = IQ) ->
    Txt = ?T("Unable to handle this IQ"),
    xmpp:make_error(IQ, xmpp:err_internal_server_error(Txt, Lang)).


%% TODO(murali@): refactor this hook and its arguments later.
%% The call to model_privacy:is_blocked_any() could involve multiple redis calls and might be expensive.
%% Will need to use qp() and cache it.
-spec privacy_check_packet(Acc :: allow | deny, State :: c2s_state(),
        Pkt :: stanza(), Dir :: in | out) -> allow | deny | {stop, deny}.
privacy_check_packet(allow, _State, Pkt, _Dir)
        when is_record(Pkt, message); is_record(Pkt, presence); is_record(Pkt, chat_state) ->
    #jid{luser = FromUid} = xmpp:get_from(Pkt),
    #jid{luser = ToUid} = xmpp:get_to(Pkt),
    Id = xmpp:get_id(Pkt),
    PacketType = element(1, Pkt),
    FinalResult = if
        FromUid =:= undefined -> allow;
        ToUid =:= undefined -> allow;
        true ->
            Result = case model_privacy:is_blocked_any(FromUid, ToUid) of
                true ->
                    {stop, deny};
                false ->
                    allow
            end,
            %% Allow only seen receipts.
            PacketType = util:get_packet_type(Pkt),
            PayloadType = util:get_payload_type(Pkt),
            case PacketType =:= message andalso
                    (PayloadType =:= receipt_seen orelse PayloadType =:= group_chat) of
                true -> allow;
                false -> Result
            end
    end,
    case FinalResult of
        allow -> ok;
        _ ->
            ?INFO("PacketType: ~p packet-id: ~p, from-uid: ~s to-uid: ~s, result: ~p",
                    [PacketType, Id, FromUid, ToUid, FinalResult])
    end,
    FinalResult;
privacy_check_packet(Acc, _, _, _) ->
    Acc.


-spec remove_user(Uid :: binary(), Server :: binary()) -> ok.
remove_user(Uid, _Server) ->
    model_privacy:remove_user(Uid),
    ok.


%%====================================================================
%% internal functions.
%%====================================================================


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
            fun(#uid_el{type = T}) ->
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
    FullHash = crypto:hash(?HASH_FUNC, FinalString),
    HashValue = base64url:encode(FullHash),
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
            #uid_el{uid = Ouid}
        end, Ouids),
    PrivacyList = #user_privacy_list{type = Type, uid_els = UidEls},
    get_privacy_lists(Uid, Rest, [PrivacyList | Result]).


-spec extract_uid(UidEl :: uid_el()) -> binary().
extract_uid(#uid_el{uid = Uid}) -> Uid.

-spec log_counters(ServerHashValue :: binary(), ClientHashValue :: binary() | undefined) -> ok.
log_counters(_, undefined) ->
    ?INFO("ClientHashValue is undefined"),
    stat:count(?STAT_PRIVACY, "hash_undefined");
log_counters(Hash, Hash) ->
    stat:count(?STAT_PRIVACY, "hash_match");
log_counters(_, _) ->
    stat:count(?STAT_PRIVACY, "hash_mismatch").

