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
-include("account.hrl").
-include("ha_types.hrl").

%% API
-export([
    get_call_servers/3,
    start_call/5,
    user_receive_packet/1,
    user_send_packet/1,
    push_message_always_hook/1
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
    ejabberd_hooks:add(push_message_always_hook, Host, ?MODULE, push_message_always_hook, 50),
    ok.

stop(Host) ->
    ?INFO("stop"),
    ejabberd_hooks:delete(user_send_packet, Host, ?MODULE, user_send_packet, 50),
    ejabberd_hooks:delete(user_receive_packet, Host, ?MODULE, user_receive_packet, 50),
    ejabberd_hooks:delete(push_message_always_hook, Host, ?MODULE, push_message_always_hook, 50),
    ok.

depends(_Host, _Opts) -> [].

mod_options(_Host) -> [].


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%   API                                                                                      %%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

-spec get_call_servers(Uid :: uid(), PeerUid :: uid(), CallType :: 'CallType'())
        -> {ok, {list(pb_stun_server()), list(pb_turn_server())}}.
get_call_servers(Uid, PeerUid, CallType) ->
    % Nothing fency for now.
    stat:count("HA/call", "get_call_servers"),
    mod_call_servers:get_stun_turn_servers(Uid, PeerUid, CallType).

-spec start_call(CallId :: call_id(), Uid :: uid(), PeerUid :: uid(),
    CallType :: 'CallType'(), Offer :: pb_web_rtc_session_description())
        -> {ok, {list(pb_stun_server()), list(pb_turn_server())}}.
start_call(CallId, Uid, PeerUid, CallType, Offer) ->
    % TODO: (nikola): check if we should allow Uid to call Ouid. For now everything is allowed.
    stat:count("HA/call", "start_call", 1, [{type, CallType}]),
    {StunServers, TurnServers} = mod_call_servers:get_stun_turn_servers(Uid, PeerUid, CallType),
    IncomingCallMsg = #pb_incoming_call{
        call_id = CallId,
        call_type = CallType,
        webrtc_offer = Offer,
        stun_servers = StunServers,
        turn_servers = TurnServers,
        timestamp_ms = util:now_ms(),
        server_sent_ts_ms = util:now_ms()       % time at which the server send the packet
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
        payload = #pb_incoming_call{call_id = CallId, call_type = CallType} = IncomingCall} = Message, State}) ->
    ?INFO("CallId: ~s incoming FromUid: ~s ToUid: ~s MsgId: ~s", [CallId, FromUid, ToUid, MsgId]),
    stat:count("HA/call", "incoming_call", 1, [{type, CallType}]),
    Message1 = Message#pb_msg{payload = IncomingCall#pb_incoming_call{server_sent_ts_ms = util:now_ms()}},
    {Message1, State};
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
    stat:count("HA/call", "end_call", 1, [{reason, Reason}]),
    Ts = util:now_ms(),
    Msg1 = Msg#pb_msg{payload = Payload#pb_end_call{timestamp_ms = Ts}},
    {Msg1, State};
user_send_packet(Acc) -> Acc.


-spec push_message_always_hook(Packet :: pb_msg()) -> ok.
push_message_always_hook(#pb_msg{to_uid = Uid} = Packet) ->
    %% Handle special case of voip messages for ios clients.
    case util:is_voip_incoming_message(Packet) of
        true ->
            %% ios versions upto 14.5 need some special logic here.
            %% we should always send a push in these cases as of now.
            {ok, Account} = model_accounts:get_account(Uid),
            case util_ua:is_ios(Account#account.client_version) of
                true ->
                    case Account#account.os_version of
                        undefined -> push_message(Packet);
                        Version when Version < <<"14.5">> -> push_message(Packet);
                        _ -> ok
                    end;
                false ->
                    %% Ignore for other os.
                    ok
            end;
        false -> ok
    end;
push_message_always_hook(_) -> ok.


-spec push_message(Packet :: pb_msg()) -> ok.
push_message(#pb_msg{to_uid = Uid, id = MsgId} = Packet) ->
    ?INFO("Uid: ~p MsgId: ~p", [Uid, MsgId]),
    ejabberd_sm:push_message(Packet),
    ok.

