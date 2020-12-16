%%%-----------------------------------------------------------------------------------
%%% File    : mod_user_session.erl
%%%
%%% Copyright (C) 2020 halloappinc.
%%%
%%%
%%%-----------------------------------------------------------------------------------

-module(mod_user_session).
-author('murali').
-behaviour(gen_mod).

-include("logger.hrl").
-include("xmpp.hrl").
-include("translate.hrl").
-include("ejabberd_sm.hrl").

-define(NS_USER_MODE, <<"halloapp:user:mode">>).

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
    gen_iq_handler:add_iq_handler(ejabberd_local, Host, ?NS_USER_MODE, ?MODULE, process_local_iq),
    ok.

stop(Host) ->
    ?INFO("stop", []),
    gen_iq_handler:remove_iq_handler(ejabberd_local, Host, ?NS_USER_MODE),
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
process_local_iq(#iq{from = #jid{luser = Uid, lserver = Server}, type = set,
        lang = Lang, sub_els = [#client_mode{mode = Mode}]} = IQ) ->
    ?INFO("Uid: ~s, set-iq for client_mode, mode: ~p", [Uid, Mode]),
    if
        Mode =/= active ->
            ?WARNING("Uid: ~s, received invalid client mode: ~p", [Uid, Mode]),
            Txt = ?T("Invalid client login mode."),
            xmpp:make_error(IQ, xmpp:err_bad_request(Txt, Lang));
        true ->
            ok = ejabberd_sm:activate_session(Uid, Server),
            xmpp:make_iq_result(IQ)
    end;
process_local_iq(#iq{lang = Lang} = IQ) ->
    Txt = ?T("Unable to handle this IQ"),
    xmpp:make_error(IQ, xmpp:err_internal_server_error(Txt, Lang)).


%%====================================================================
%% internal functions.
%%====================================================================

