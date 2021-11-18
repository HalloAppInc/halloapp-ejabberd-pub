%%%-------------------------------------------------------------------
%%% @author nikola
%%% @copyright (C) 2021, HalloApp Inc.
%%% @doc
%%% Audio Video 1v1 Calls Protobuf API
%%% @end
%%% Created : 11. Oct 2021 4:25 PM
%%%-------------------------------------------------------------------
-module(mod_calls_api).
-author("nikola").
-behaviour(gen_mod).

-include("logger.hrl").
-include("packets.hrl").

%% API
-export([
    process_local_iq/1
]).

%% gen_mod api
-export([start/2, stop/1, mod_options/1, depends/2]).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%   API                                                                                      %%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%%% get_call_servers %%%
process_local_iq(#pb_iq{from_uid = Uid, type = get,
        payload = #pb_get_call_servers{call_id = CallId, peer_uid = PeerUid, call_type = CallType}} = IQ)
        when CallType =:= audio orelse CallType =:= video ->
    process_get_call_servers(IQ, Uid, PeerUid, CallId, CallType);

%%% start_call %%%
process_local_iq(#pb_iq{from_uid = Uid, type = set,
        payload = #pb_start_call{call_id = CallId, peer_uid = PeerUid, call_type = CallType, webrtc_offer = Offer}} = IQ)
        when CallType =:= audio orelse CallType =:= video ->
    process_start_call(IQ, Uid, PeerUid, CallId, CallType, Offer);

%%% error %%%
process_local_iq(#pb_iq{from_uid = Uid} = IQ) ->
    ?ERROR("Invalid IQ request: Uid: ~s, IQ: ~p", [Uid, IQ]),
    pb:make_error(IQ, util:err(bad_request)).


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%   gen_mod API                                                                              %%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%


start(Host, _Opts) ->
    ?INFO("start"),
    gen_iq_handler:add_iq_handler(ejabberd_local, Host, pb_start_call, ?MODULE, process_local_iq),
    gen_iq_handler:add_iq_handler(ejabberd_local, Host, pb_get_call_servers, ?MODULE, process_local_iq),
    ok.


stop(Host) ->
    ?INFO("stop"),
    gen_iq_handler:remove_iq_handler(ejabberd_local, Host, pb_start_call),
    gen_iq_handler:remove_iq_handler(ejabberd_local, Host, pb_get_call_servers),
    ok.


depends(_Host, _Opts) ->
    [{mod_calls, hard}].


mod_options(_Host) ->
    [].

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%   Internal                                                                                 %%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

process_get_call_servers(IQ, Uid, PeerUid, CallId, CallType) ->
    ?INFO("Uid: ~s PeerUid: ~s CallId: ~s ~s", [Uid, PeerUid, CallId, CallType]),

    {StunServers, TurnServers} = mod_calls:get_call_servers(Uid, PeerUid, CallType),
    GetServersResult = #pb_get_call_servers_result{
        result = ok,
        stun_servers = StunServers,
        turn_servers = TurnServers
    },
    pb:make_iq_result(IQ, GetServersResult).


process_start_call(IQ, Uid, PeerUid, CallId, CallType, Offer) ->
    ?INFO("Uid: ~s PeerUid: ~s CallId: ~s ~s", [Uid, PeerUid, CallId, CallType]),

    {ok, {StunServers, TurnServers}} = mod_calls:start_call(CallId, Uid, PeerUid, CallType, Offer),

    StartCallResult = #pb_start_call_result{
        result = ok,
        stun_servers = StunServers,
        turn_servers = TurnServers
    },

    pb:make_iq_result(IQ, StartCallResult).


