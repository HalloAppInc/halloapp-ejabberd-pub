%%%-------------------------------------------------------------------
%%% File    : mod_ack_halloapp.erl
%%%
%%% Copyright (C) 2020 halloappinc.
%%%
%%%-------------------------------------------------------------------
%% TODO(murali@): rename this file later.
-module(mod_ack_halloapp).
-author('murali').
-behaviour(gen_mod).

%% gen_mod API
-export([start/2, stop/1, reload/3, depends/2, mod_options/1]).
%% hooks
-export([user_send_packet/1]).

-include("packets.hrl").
-include("logger.hrl").

-type state() :: halloapp_c2s:state().
-define(needs_ack_packet(Pkt),
        is_record(Pkt, pb_msg)).

%%%===================================================================
%%% gen_mod API
%%%===================================================================

start(Host, _Opts) ->
    ?DEBUG("start", []),
    ejabberd_hooks:add(user_send_packet, Host, ?MODULE, user_send_packet, 90).

stop(Host) ->
    ?DEBUG("stop", []),
    ejabberd_hooks:delete(user_send_packet, Host, ?MODULE, user_send_packet, 90).

depends(_Host, _Opts) ->
    [].

reload(_Host, _NewOpts, _OldOpts) ->
    ok.

mod_options(_Host) ->
    [].

%%%===================================================================
%%% Hooks
%%%===================================================================

%% Hook called when the server receives a packet.
%% TODO(murali@): Add logic to send ack only after handling the message properly!
user_send_packet({Packet, State}) ->
    NewState = case ?needs_ack_packet(Packet) of
        true -> send_ack(State, Packet);
        false -> State
    end,
    {Packet, NewState}.


%% Sends an ack packet. Runs on c2s process.
-spec send_ack(State :: state(), Packet :: pb_msg()) -> state().
send_ack(State, #pb_msg{id = MsgId, from_uid = Uid} = Packet)
        when MsgId =:= undefined orelse MsgId =:= <<>> ->
    PayloadType = util:get_payload_type(Packet),
    ?ERROR("uid: ~s, invalid msg_id: ~s, content: ~p", [Uid, MsgId, PayloadType]),
    State;
send_ack(State, #pb_msg{id = MsgId, from_uid = Uid}) ->
    Timestamp = util:now(),
    AckPacket = #pb_ack{id = MsgId, to_uid = Uid, timestamp = Timestamp},
    ?INFO("uid: ~s, msg_id: ~s", [Uid, MsgId]),
    halloapp_c2s:route(State, {route, AckPacket}).

