%%%---------------------------------------------------------------------------------
%%% File    : mod_names.erl
%%%
%%% Copyright (C) 2021 HalloApp Inc.
%%%
%%% The module handles both set and get iq stanzas.
%%% iq-set stanza is used to set the name of the sender.
%%% iq-get stanza is used to get the name of any user on halloapp. 
%%% Client is allowed to set its own name using the iq-set stanza. 
%%% Setting others name will result in an iq-error stanza.
%%% Client can fetch any user's name on halloapp using the iq-set stanza.
%%% TODO(murali@): Use redis models and fill it up.
%%%---------------------------------------------------------------------------------

-module(mod_names).
-author('murali').
-behaviour(gen_mod).

-include("logger.hrl").
-include("packets.hrl").

%% Export all functions for unit tests
-ifdef(TEST).
-compile(export_all).
-endif.

%% gen_mod API.
%% IQ handlers and hooks.
-export([
    start/2,
    stop/1,
    reload/3,
    depends/2,
    mod_options/1,
    process_local_iq/1,
    re_register_user/3,
    user_name_updated/2
]).



start(Host, _Opts) ->
    gen_iq_handler:add_iq_handler(ejabberd_local, Host, pb_name, ?MODULE, process_local_iq),
    ejabberd_hooks:add(re_register_user, Host, ?MODULE, re_register_user, 50),
    ejabberd_hooks:add(user_name_updated, Host, ?MODULE, user_name_updated, 50),
    ok.

stop(Host) ->
    gen_iq_handler:remove_iq_handler(ejabberd_local, Host, pb_name),
    ejabberd_hooks:delete(re_register_user, Host, ?MODULE, re_register_user, 50),
    ejabberd_hooks:delete(user_name_updated, Host, ?MODULE, user_name_updated, 50),
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

process_local_iq(#pb_iq{from_uid = Uid, type = set,
        payload = #pb_name{uid = Ouid, name = Name}} = IQ) ->
    case Ouid =:= <<>> orelse Ouid =:= Uid of
      true ->
        set_name(Uid, Name),
        pb:make_iq_result(IQ);
      false ->
        ?ERROR("Uid: ~p, Invalid userid in the iq-set request: ~p", [Uid, Ouid]),
        pb:make_error(IQ, util:err(invalid_uid))
    end.
%% TODO(murali@): add get-iq api if clients need it.


-spec re_register_user(UserId :: binary(), Server :: binary(), Phone :: binary()) -> ok.
re_register_user(UserId, _Server, _Phone) ->
    ok = model_accounts:delete_name(UserId).


% TODO: (nikola): need common test.
-spec user_name_updated(Uid :: binary(), Name :: binary()) -> ok.
user_name_updated(Uid, Name) ->
    {ok, Phone} = model_accounts:get_phone(Uid),
    % TODO: (nikola): I feel like we should be notifying the contacts instead of the reverse contacts
    % The reverse contacts have phonebook name so they will not care about our push name.
    {ok, ContactUids} = model_contacts:get_contact_uids(Phone),
    GroupUidsSet = mod_groups:get_all_group_members(Uid),
    UidsToNotifySet = sets:union(sets:from_list(ContactUids), GroupUidsSet),
    UidsToNotify = sets:to_list(UidsToNotifySet),
    ?INFO("Uid: ~s name updated. notifying ~p Contacts ~p group members ~p total unique",
        [Uid, length(ContactUids), sets:size(GroupUidsSet), sets:size(UidsToNotifySet)]),
    lists:foreach(
        fun(OUid) ->
            Message = #pb_msg{
                id = util_id:new_msg_id(),
                to_uid = OUid,
                type = normal,
                payload = #pb_name{uid = Uid, name = Name}
            },
            ejabberd_router:route(Message)
        end, UidsToNotify).


%%====================================================================
%% internal functions
%%====================================================================

-spec set_name(Uid :: binary(), Name :: binary()) -> ok.
set_name(Uid, Name) ->
    ?INFO("Uid: ~p, Name: ~p", [Uid, Name]),
    Server = util:get_host(),
    ok = model_accounts:set_name(Uid, Name),
    ejabberd_hooks:run(user_name_updated, Server, [Uid, Name]),
    ok.
