%%%---------------------------------------------------------------------------------
%%% File    : mod_names.erl
%%%
%%% Copyright (C) 2020 halloappinc.
%%%
%%% This file handles the iq stanza queries with a custom namespace
%%% (<<"halloapp:users:name">>) that we defined in xmpp/specs/xmpp_codec.spec file.
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
-include("xmpp.hrl").
-include("translate.hrl").

-define(NS_NAME, <<"halloapp:users:name">>).

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
    remove_user/2,
    re_register_user/3,
    user_name_updated/2
]).



start(Host, _Opts) ->
    gen_iq_handler:add_iq_handler(ejabberd_local, Host, ?NS_NAME, ?MODULE, process_local_iq),
    ejabberd_hooks:add(remove_user, Host, ?MODULE, remove_user, 40),
    ejabberd_hooks:add(re_register_user, Host, ?MODULE, re_register_user, 50),
    ejabberd_hooks:add(user_name_updated, Host, ?MODULE, user_name_updated, 50),
    ok.

stop(Host) ->
    gen_iq_handler:remove_iq_handler(ejabberd_local, Host, ?NS_NAME),
    ejabberd_hooks:delete(remove_user, Host, ?MODULE, remove_user, 40),
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

process_local_iq(#iq{from = #jid{user = Uid}, type = set,
        sub_els = [#name{uid = Ouid, name = Name}]} = IQ) ->
    case Ouid =:= <<>> orelse Ouid =:= Uid of
      true ->
        set_name(Uid, Name),
        xmpp:make_iq_result(IQ);
      false ->
        ?ERROR_MSG("Uid: ~p, Invalid userid in the iq-set request: ~p", [Uid, Ouid]),
        xmpp:make_error(IQ, util:err(invalid_uid))
    end.
%% TODO(murali@): add get-iq api if clients need it.


%% remove_user hook deletes the name of the user.
remove_user(UserId, _Server) ->
    ok = model_accounts:delete_name(UserId).


-spec re_register_user(UserId :: binary(), Server :: binary(), Phone :: binary()) -> ok.
re_register_user(UserId, _Server, _Phone) ->
    ok = model_accounts:delete_name(UserId).


-spec user_name_updated(Uid :: binary(), Name :: binary()) -> ok.
user_name_updated(Uid, Name) ->
    Server = util:get_host(),
    {ok, Phone} = model_accounts:get_phone(Uid),
    {ok, ContactUids} = model_contacts:get_contact_uids(Phone),
    lists:foreach(
        fun(ContactUid) ->
            Message = #message{
                id = util:new_msg_id(),
                to = jid:make(ContactUid, Server),
                from = jid:make(Server),
                type = normal,
                sub_els = [#name{uid = Uid, name = Name}]
            },
            ejabberd_router:route(Message)
        end, ContactUids).


%%====================================================================
%% internal functions
%%====================================================================

-spec set_name(Uid :: binary(), Name :: binary()) -> ok.
set_name(Uid, Name) ->
    Server = util:get_host(),
    ok = model_accounts:set_name(Uid, Name),
    ejabberd_hooks:run(user_name_updated, Server, [Uid, Name]),
    ok.


