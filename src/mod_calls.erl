%%%-------------------------------------------------------------------
%%% @author nikola
%%% @copyright (C) 2021, HalloApp Inc.
%%% @doc
%%% Audio Video 1v1 calls erlang API.
%%% @end
%%% Created : 11. Oct 2021 4:48 PM
%%%-------------------------------------------------------------------
-module(mod_calls).
-author("nikola").
-behaviour(gen_mod).

-include("logger.hrl").
-include("packets.hrl").
-include("ha_types.hrl").

%% API
-export([
    get_call_servers/3,
    start_call/5,
    user_receive_packet/1,
    user_send_packet/1
]).

%% gen_mod api
-export([start/2, stop/1, mod_options/1, depends/2]).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%   gen_mod API                                                                              %%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

start(Host, _Opts) ->
    ?INFO("start"),
    ejabberd_hooks:add(user_receive_packet, Host, ?MODULE, user_receive_packet, 50),
    ejabberd_hooks:add(user_send_packet, Host, ?MODULE, user_send_packet, 50),
    ok.

stop(Host) ->
    ?INFO("stop"),
    ejabberd_hooks:delete(user_send_packet, Host, ?MODULE, user_send_packet, 50),
    ejabberd_hooks:delete(user_receive_packet, Host, ?MODULE, user_receive_packet, 50),
    ok.

depends(_Host, _Opts) -> [].

mod_options(_Host) -> [].


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%   API                                                                                      %%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

-spec get_call_servers(Uid :: uid(), PeerUid :: uid(), CallType :: 'CallType'())
        -> {ok, {list(pb_stun_server()), list(pb_turn_server())}}.
get_call_servers(_Uid, _PeerUid, _CallType) ->
    % Nothing fency for now.
    stat:count("HA/call", "get_call_servers"),
    get_stun_turn_servers().

-spec start_call(CallId :: call_id(), Uid :: uid(), PeerUid :: uid(),
    CallType :: 'CallType'(), Offer :: pb_web_rtc_session_description())
        -> {ok, {list(pb_stun_server()), list(pb_turn_server())}}.
start_call(CallId, Uid, PeerUid, CallType, Offer) ->
    % TODO: (nikola): check if we should allow Uid to call Ouid. For now everything is allowed.
    stat:count("HA/call", "start_call"),
    {StunServers, TurnServers} = get_stun_turn_servers(),
    IncomingCallMsg = #pb_incoming_call{
        call_id = CallId,
        call_type = CallType,
        webrtc_offer = Offer,
        stun_servers = StunServers,
        turn_servers = TurnServers,
        timestamp_ms = util:now_ms()
    },
    MsgId = util_id:new_msg_id(),
    Packet = #pb_msg{
        id = MsgId,
        type = call,
        from_uid = Uid,
        to_uid = PeerUid,
        payload = IncomingCallMsg
    },

    ejabberd_router:route(Packet),

    {ok, {StunServers, TurnServers}}.

% TODO: (nikola) code is kind of duplicated..
user_receive_packet({#pb_msg{id = MsgId, to_uid = ToUid, from_uid = FromUid,
        payload = #pb_incoming_call{call_id = CallId}}, _State} = Acc) ->
    ?INFO("CallId: ~s incoming FromUid: ~s ToUid: ~s MsgId: ~s", [CallId, FromUid, ToUid, MsgId]),
    Acc;
user_receive_packet({#pb_msg{id = MsgId, to_uid = ToUid, from_uid = FromUid,
        payload = #pb_call_ringing{call_id = CallId}}, _State} = Acc) ->
    ?INFO("CallId: ~s ringing FromUid: ~s ToUid: ~s MsgId: ~s", [CallId, FromUid, ToUid, MsgId]),
    Acc;
user_receive_packet({#pb_msg{id = MsgId, to_uid = ToUid, from_uid = FromUid,
        payload = #pb_answer_call{call_id = CallId}}, _State} = Acc) ->
    ?INFO("CallId: ~s answer FromUid: ~s ToUid: ~s MsgId: ~s", [CallId, FromUid, ToUid, MsgId]),
    Acc;
user_receive_packet({#pb_msg{id = MsgId, to_uid = ToUid, from_uid = FromUid,
        payload = #pb_end_call{call_id = CallId, reason = Reason}}, _State} = Acc) ->
    ?INFO("CallId: ~s end_call (~s) FromUid: ~s ToUid: ~s MsgId: ~s", [CallId, Reason, FromUid, ToUid, MsgId]),
    Acc;
user_receive_packet(Acc) -> Acc.

user_send_packet({#pb_msg{id = MsgId, to_uid = ToUid, from_uid = FromUid,
        payload = #pb_call_ringing{call_id = CallId} = Payload} = Msg, State}) ->
    ?INFO("CallId: ~s ringing FromUid: ~s ToUid: ~s MsgId: ~s", [CallId, FromUid, ToUid, MsgId]),
    stat:count("HA/call", "ringing"),
    Ts = util:now_ms(),
    Msg1 = Msg#pb_msg{payload = Payload#pb_call_ringing{timestamp_ms = Ts}},
    {Msg1, State};
user_send_packet({#pb_msg{id = MsgId, to_uid = ToUid, from_uid = FromUid,
        payload = #pb_answer_call{call_id = CallId} = Payload} = Msg, State}) ->
    ?INFO("CallId: ~s answer FromUid: ~s ToUid: ~s MsgId: ~s", [CallId, FromUid, ToUid, MsgId]),
    stat:count("HA/call", "answer"),
    Ts = util:now_ms(),
    Msg1 = Msg#pb_msg{payload = Payload#pb_answer_call{timestamp_ms = Ts}},
    {Msg1, State};
user_send_packet({#pb_msg{id = MsgId, to_uid = ToUid, from_uid = FromUid,
        payload = #pb_end_call{call_id = CallId, reason = Reason} = Payload} = Msg, State}) ->
    ?INFO("CallId: ~s end_call (~s) FromUid: ~s ToUid: ~s MsgId: ~s", [CallId, Reason, FromUid, ToUid, MsgId]),
    stat:count("HA/call", "end_call"),
    Ts = util:now_ms(),
    Msg1 = Msg#pb_msg{payload = Payload#pb_end_call{timestamp_ms = Ts}},
    {Msg1, State};
user_send_packet(Acc) -> Acc.


-spec get_stun_turn_servers() -> {list(#pb_stun_server{}), list(#pb_turn_server{})}.
get_stun_turn_servers() ->
    StunServer = #pb_stun_server {
        host = <<"stun.halloapp.dev">>,
        port = 3478
    },

    TurnServer = #pb_turn_server{
        host = <<"turn.halloapp.dev">>,
        port = 3478,
        username = <<"clients">>,
        password = <<"2Nh57xoGpDy7Z7D1Sg0S">>
    },
    {[StunServer], [TurnServer]}.

