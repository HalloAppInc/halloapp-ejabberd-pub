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

%% gen_mod API
-export([start/2, stop/1, reload/3, depends/2, mod_options/1]).

%% iq handler and API.
-export([
    process_local_iq/1
]).


%%====================================================================
%% gen_mod API.
%%====================================================================

start(Host, _Opts) ->
    ?INFO_MSG("start", []),
    gen_iq_handler:add_iq_handler(ejabberd_local, Host, ?NS_USER_PRIVACY, ?MODULE, process_local_iq),
    ok.

stop(Host) ->
    ?INFO_MSG("stop", []),
    gen_iq_handler:remove_iq_handler(ejabberd_local, Host, ?NS_USER_PRIVACY),
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
        lang = Lang, sub_els = [#user_privacy_list{type = Type, uid_els = UidEls}]} = IQ) ->
    ?INFO_MSG("Uid: ~s, set-iq for privacy_list, type: ~p", [Uid, Type]),
    case update_privacy_type(Uid, Type, UidEls) of
        ok ->
            xmpp:make_iq_result(IQ);
        {error, invalid_type} ->
            ?WARNING_MSG("Uid: ~s, invalid privacy_list_type: ~p", [Uid, Type]),
            Txt = ?T("Invalid privacy_list_type."),
            xmpp:make_error(IQ, xmpp:err_bad_request(Txt, Lang));
        {error, unexcepted_uids} ->
            ?WARNING_MSG("Uid: ~s, unexcepted_uids for type: ~p", [Uid, Type]),
            Txt = ?T("unexcepted_uids for this type."),
            xmpp:make_error(IQ, xmpp:err_bad_request(Txt, Lang))
    end;
process_local_iq(#iq{from = #jid{luser = Uid, lserver = _Server}, type = get,
        lang = _Lang, sub_els = [#user_privacy_lists{lists = PrivacyLists}]} = IQ) ->
    ?INFO_MSG("Uid: ~s, get-iq for privacy_list", [Uid]),
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


%%====================================================================
%% internal functions.
%%====================================================================


%% TODO(murali@): counts for switching privacy modes will involve another redis call.
-spec update_privacy_type(Uid :: binary(),
        Type :: privacy_list_type(), UidEls :: list(binary())) -> ok | {error, any()}.
update_privacy_type(Uid, all = Type, []) ->
    set_privacy_type(Uid, Type),
    stat:count(?STAT_PRIVACY, Type),
    ok;
update_privacy_type(Uid, Type, UidEls) when Type =:= except; Type =:= only ->
    update_privacy_list(Uid, Type, UidEls),
    set_privacy_type(Uid, Type),
    stat:count(?STAT_PRIVACY, Type),
    ok;
update_privacy_type(Uid, Type, UidEls) when Type =:= mute; Type =:= block ->
    update_privacy_list(Uid, Type, UidEls);
update_privacy_type(_Uid, all, _) ->
    {error, unexcepted_uids};
update_privacy_type(_Uid, _, _) ->
    {error, invalid_type}.


-spec set_privacy_type(Uid :: binary(), Type :: privacy_type()) -> ok.
set_privacy_type(Uid, Type) ->
    ?INFO_MSG("Uid: ~s, privacy_type: ~p", [Uid, Type]),
    model_accounts:set_privacy_type(Uid, Type).


-spec get_privacy_type(Uid :: binary()) -> privacy_type().
get_privacy_type(Uid) ->
    {ok, Type} = model_accounts:get_privacy_type(Uid),
    ?INFO_MSG("Uid: ~s, privacy_type: ~p", [Uid, Type]),
    Type.


-spec update_privacy_list(Uid :: binary(),
        Type :: privacy_list_type(), UidEls :: list(binary())) -> ok.
update_privacy_list(_Uid, _Type, []) -> ok;
update_privacy_list(Uid, Type, UidEls) ->
    {DeleteUidsList, AddUidsList} = lists:partition(
            fun(#uid_el{type = T}) ->
                T == delete
            end, UidEls),
    DeleteUids = lists:map(fun extract_uid/1, DeleteUidsList),
    AddUids = lists:map(fun extract_uid/1, AddUidsList),
    ?INFO_MSG("Uid: ~s, Type: ~p, DeleteUids: ~p, AddUids: ~p", [Uid, Type, DeleteUids, AddUids]),
    case DeleteUids of
        [] -> ok;
        _ -> remove_uids_from_privacy_list(Uid, Type, DeleteUids)
    end,
    case AddUids of
        [] -> ok;
        _ -> add_uids_to_privacy_list(Uid, Type, AddUids)
    end,
    ok.


-spec extract_uid(UidEl :: uid_el()) -> binary().
extract_uid(#uid_el{uid = Uid}) -> Uid.


-spec remove_uids_from_privacy_list(Uid :: binary(),
        Type :: privacy_list_type(), Ouids :: list(binary())) -> ok.
remove_uids_from_privacy_list(Uid, except, Ouids) ->
    model_accounts:unblacklist_uids(Uid, Ouids),
    stat:count(?STAT_PRIVACY, unblacklist, length(Ouids)),
    ok;
remove_uids_from_privacy_list(Uid, only, Ouids) ->
    model_accounts:unwhitelist_uids(Uid, Ouids),
    stat:count(?STAT_PRIVACY, unwhitelist, length(Ouids)),
    ok;
remove_uids_from_privacy_list(Uid, mute, Ouids) ->
    model_accounts:unmute_uids(Uid, Ouids),
    stat:count(?STAT_PRIVACY, unmute, length(Ouids)),
    ok;
remove_uids_from_privacy_list(Uid, block, Ouids) ->
    model_accounts:unblock_uids(Uid, Ouids),
    stat:count(?STAT_PRIVACY, unblock, length(Ouids)),
    Server = util:get_host(),
    ejabberd_hooks:run(unblock_uids, Server, [Uid, Server, Ouids]).


-spec add_uids_to_privacy_list(Uid :: binary(),
        Type :: privacy_list_type(), Ouids :: list(binary())) -> ok.
add_uids_to_privacy_list(Uid, except, Ouids) ->
    model_accounts:blacklist_uids(Uid, Ouids),
    stat:count(?STAT_PRIVACY, blacklist, length(Ouids)),
    ok;
add_uids_to_privacy_list(Uid, only, Ouids) ->
    model_accounts:whitelist_uids(Uid, Ouids),
    stat:count(?STAT_PRIVACY, whitelist, length(Ouids)),
    ok;
add_uids_to_privacy_list(Uid, mute, Ouids) ->
    model_accounts:mute_uids(Uid, Ouids),
    stat:count(?STAT_PRIVACY, mute, length(Ouids)),
    ok;
add_uids_to_privacy_list(Uid, block, Ouids) ->
    model_accounts:unwhitelist_uids(Uid, Ouids),
    Server = util:get_host(),
    ejabberd_hooks:run(block_uids, Server, [Uid, Server, Ouids]),
    model_accounts:block_uids(Uid, Ouids),
    stat:count(?STAT_PRIVACY, block, length(Ouids)),
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
        except -> model_accounts:get_blacklist_uids(Uid);
        only -> model_accounts:get_whitelist_uids(Uid);
        mute -> model_accounts:get_mutelist_uids(Uid);
        block -> model_accounts:get_blocked_uids(Uid)
    end,
    UidEls = lists:map(
        fun(Ouid) ->
            #uid_el{uid = Ouid}
        end, Ouids),
    PrivacyList = #user_privacy_list{type = Type, uid_els = UidEls},
    get_privacy_lists(Uid, Rest, [PrivacyList | Result]).

