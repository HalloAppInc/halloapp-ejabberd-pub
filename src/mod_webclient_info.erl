%%%-----------------------------------------------------------------------------------
%%% File    : mod_webclient_info.erl
%%%
%%% Copyright (C) 2022 halloappinc.
%%%-----------------------------------------------------------------------------------

-module(mod_webclient_info).
-behaviour(gen_mod).
-author('vipin').

-include("ha_types.hrl").
-include("packets.hrl").
-include("logger.hrl").

%% gen_mod API.
-export([start/2, stop/1, reload/3, mod_options/1, depends/2]).

%% Hooks and API.
-export([
    process_local_iq/1
]).


start(Host, _Opts) ->
    gen_iq_handler:add_iq_handler(ejabberd_local, Host, pb_web_client_info, ?MODULE, process_local_iq),
    ok.

stop(Host) ->
    gen_iq_handler:remove_iq_handler(ejabberd_local, Host, pb_web_client_info),
    ok.

reload(_Host, _NewOpts, _OldOpts) ->
    ok.

depends(_Host, _Opts) ->
    [].

mod_options(_Host) ->
    [].


%%====================================================================
%% IQs
%%====================================================================

%% Authenticate Key.
process_local_iq(#pb_iq{from_uid = Uid, type = set,
        payload = #pb_web_client_info{action = authenticate_key, static_key = StaticKey}} = IQ) ->
    ?INFO("set authenticate key Uid: ~s", [Uid]),
    case authenticate_key(Uid, StaticKey) of
        ok ->
            pb:make_iq_result(IQ, #pb_web_client_info{result = ok});
        {error, Reason} ->
            ?ERROR("set authenticate key Uid: ~s, error: ~p", [Uid, Reason]),
            pb:make_error(IQ, util:err(Reason))
    end;

%% Remove Key.
process_local_iq(#pb_iq{from_uid = Uid, type = set,
        payload = #pb_web_client_info{action = remove_key, static_key = StaticKey}} = IQ) ->
    ?INFO("set remove key Uid: ~s", [Uid]),
    case remove_key(Uid, StaticKey) of
        ok ->
            pb:make_iq_result(IQ, #pb_web_client_info{result = ok});
        {error, Reason} ->
            ?ERROR("set remove key Uid: ~s, error: ~p", [Uid, Reason]),
            pb:make_error(IQ, util:err(Reason))
    end.

%%====================================================================
%% Internal functions
%%====================================================================

-spec authenticate_key(Uid :: uid(), StaticKey :: binary()) -> ok | {error, any()}.
authenticate_key(Uid, StaticKey) ->
    ?INFO("Uid: ~s", [Uid]),
    %% close all known sessions for Uid.
    websocket_handler:close_current_sessions_uid(Uid),
    ok = model_auth:autheticate_static_key(Uid, StaticKey),
    ok.

-spec remove_key(Uid :: uid(), StaticKey :: binary()) -> ok | {error, any()}.
remove_key(Uid, StaticKey) ->
    ?INFO("Uid: ~s", [Uid]),
    ok = model_auth:delete_static_key(Uid, StaticKey),
    ok.

