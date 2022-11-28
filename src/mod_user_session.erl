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
-include("ejabberd_sm.hrl").
-include("packets.hrl").

%% gen_mod API
-export([start/2, stop/1, reload/3, depends/2, mod_options/1]).

%% iq handler and API.
-export([
    process_local_iq/2
]).


%%====================================================================
%% gen_mod API.
%%====================================================================

start(_Host, _Opts) ->
    ?INFO("start", []),
    gen_iq_handler:add_iq_handler(ejabberd_local, halloapp, pb_client_mode, ?MODULE, process_local_iq, 2),
    gen_iq_handler:add_iq_handler(ejabberd_local, katchup, pb_client_mode, ?MODULE, process_local_iq, 2),
    ok.

stop(_Host) ->
    ?INFO("stop", []),
    gen_iq_handler:remove_iq_handler(ejabberd_local, halloapp, pb_client_mode),
    gen_iq_handler:remove_iq_handler(ejabberd_local, katchup, pb_client_mode),
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

-spec process_local_iq(IQ :: iq(), State :: map()) -> {iq(), map()}.
process_local_iq(#pb_iq{from_uid = Uid, type = set,
        payload = #pb_client_mode{mode = Mode}} = IQ, #{sid := SID} = State) ->
    ?INFO("Uid: ~s, set-iq for client_mode, mode: ~p", [Uid, Mode]),
    if
        Mode =/= active ->
            ?WARNING("Uid: ~s, received invalid client mode: ~p", [Uid, Mode]),
            {pb:make_error(IQ, util:err(invalid_login_mode)), State};
        true ->
            ok = ejabberd_sm:check_and_activate_session(Uid, SID),
            {pb:make_iq_result(IQ), State}
    end;
process_local_iq(#pb_iq{} = IQ, State) ->
    {pb:make_error(IQ, util:err(invalid_request)), State}.


%%====================================================================
%% internal functions.
%%====================================================================

