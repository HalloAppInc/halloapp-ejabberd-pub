%%%-----------------------------------------------------------------------------------
%%% File    : mod_user_account.erl
%%%
%%% Copyright (C) 2020 halloappinc.
%%%
%%%
%%%-----------------------------------------------------------------------------------

-module(mod_user_account).
-author('murali').
-behaviour(gen_mod).

-include("logger.hrl").
-include("xmpp.hrl").
-include("packets.hrl").
-include("ejabberd_sm.hrl").

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
    ?INFO("start", []),
    gen_iq_handler:add_iq_handler(ejabberd_local, Host, pb_delete_account, ?MODULE, process_local_iq),
    ok.

stop(Host) ->
    ?INFO("stop", []),
    gen_iq_handler:remove_iq_handler(ejabberd_local, Host, pb_delete_account),
    ok.

depends(_Host, _Opts) ->
    [].

reload(_Host, _NewOpts, _OldOpts) ->
    ok.

mod_options(_Host) ->
    [].


%%====================================================================
%% hooks.
%%====================================================================

-spec process_local_iq(IQ :: iq()) -> iq().
%% This phone must be sent with the country code.
process_local_iq(#iq{from = #jid{luser = Uid, lserver = Server}, type = set,
        sub_els = [#pb_delete_account{phone = RawPhone}]} = IQ) ->
    ?INFO("Uid: ~s, delete_account iq, raw_phone: ~p", [Uid, RawPhone]),
    NormPhone = mod_libphonenumber:normalize(RawPhone, <<"US">>),
    NormPhoneBin = util:to_binary(NormPhone),
    ResponseIq = case model_accounts:get_phone(Uid) of
        {ok, NormPhoneBin} when NormPhoneBin =/= undefined ->
            ok = ejabberd_auth:remove_user(Uid, Server),
            xmpp:make_iq_result(IQ, #pb_delete_account{});
        _ ->
            ?INFO("Uid: ~s, Failed delete_account", [Uid]),
            xmpp:make_error(IQ, util:err(invalid_phone))
    end,
    ejabberd_router:route(ResponseIq),
    ok = ejabberd_sm:disconnect_removed_user(Uid, Server),
    ignore;

process_local_iq(#iq{} = IQ) ->
    xmpp:make_error(IQ, util:err(invalid_request)).


%%====================================================================
%% internal functions.
%%====================================================================

