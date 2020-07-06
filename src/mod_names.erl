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
    re_register_user/3
]).



start(Host, _Opts) ->
    gen_iq_handler:add_iq_handler(ejabberd_local, Host, ?NS_NAME, ?MODULE, process_local_iq),
    ejabberd_hooks:add(remove_user, Host, ?MODULE, remove_user, 40),
    ejabberd_hooks:add(re_register_user, Host, ?MODULE, re_register_user, 50),
    ok.

stop(Host) ->
    gen_iq_handler:remove_iq_handler(ejabberd_local, Host, ?NS_NAME),
    ejabberd_hooks:delete(remove_user, Host, ?MODULE, remove_user, 40),
    ejabberd_hooks:delete(re_register_user, Host, ?MODULE, re_register_user, 50),
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

process_local_iq(#iq{from = #jid{user = UserId} = From, lang = Lang, type = set,
                    sub_els = [#name{jid = JID, name = Name}]} = IQ) ->
    case JID =:= undefined orelse jid:remove_resource(JID) =:= jid:remove_resource(From) of
      true ->
        ok = model_accounts:set_name(UserId, Name),
        xmpp:make_iq_result(IQ);
      false ->
        Txt = ?T("Invalid jid in the request"),
        ?WARNING_MSG("process_local_iq: ~p", [Txt]),
        xmpp:make_error(IQ, xmpp:err_bad_request(Txt, Lang))
    end;
%% iq-get exists only for debugging purposes as of now.
process_local_iq(#iq{from = _From, lang = _Lang, type = get,
                    sub_els = [#name{jid = #jid{user = UID} = JID}]} = IQ) ->
    Name = model_accounts:get_name_binary(UID),
    xmpp:make_iq_result(IQ, #name{jid = JID, name = Name}).


%% remove_user hook deletes the name of the user.
remove_user(UserId, _Server) ->
    ok = model_accounts:delete_name(UserId).


-spec re_register_user(UserId :: binary(), Server :: binary(), Phone :: binary()) -> ok.
re_register_user(UserId, _Server, _Phone) ->
    ok = model_accounts:delete_name(UserId).


%%====================================================================
%% internal functions
%%====================================================================




