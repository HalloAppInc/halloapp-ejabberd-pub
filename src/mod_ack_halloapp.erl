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

-include("xmpp.hrl").
-include("logger.hrl").

-define(needs_ack_packet(Pkt),
        is_record(Pkt, message)).
-define(is_ack_packet(Pkt),
        is_record(Pkt, ack)).

%%%===================================================================
%%% gen_mod API
%%%===================================================================

start(Host, _Opts) ->
    ?DEBUG("start", []),
    ejabberd_hooks:add(user_send_packet, Host, ?MODULE, user_send_packet, 100).

stop(Host) ->
    ?DEBUG("stop", []),
    ejabberd_hooks:delete(user_send_packet, Host, ?MODULE, user_send_packet, 100).

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
user_send_packet({Packet, #{lserver := ServerHost} = State} = Acc) ->
    case ?needs_ack_packet(Packet) of
        true -> send_ack(Packet);
        false -> ok
    end,
    {Packet, State}.


%% Sends an ack packet.
-spec send_ack(message()) -> ok.
send_ack(#message{id = MsgId, from = #jid{user = User}} = Packet)
        when MsgId =:= undefined orelse MsgId =:= <<>> ->
    PayloadType = util:get_payload_type(Packet),
    ?ERROR("uid: ~s, invalid msg_id: ~s, content: ~p", [User, MsgId, PayloadType]),
    ok;
send_ack(#message{id = MsgId, from = #jid{user = User, server = ServerHost} = From} = Packet) ->
    PayloadType = util:get_payload_type(Packet),
    PacketTs = util:get_timestamp(Packet),
    Timestamp = case {PayloadType, PacketTs} of
        {rerequest_st, _} -> util:now_binary();
        {groupchat_retract_st, _} -> util:now_binary();
        {chat_retract_st, _} -> util:now_binary();
        {_, undefined} ->
            ?WARNING("Uid: ~s, timestamp is undefined, msg_id: ~s", [User, MsgId]),
            util:now_binary();
        {_, <<>>} ->
            ?WARNING("Uid: ~s, timestamp is empty, msg_id: ~s", [User, MsgId]),
            util:now_binary();
        {_, PacketTs} -> PacketTs
    end,
    AckPacket = #ack{id = MsgId, to = From, from = jid:make(ServerHost), timestamp = Timestamp},
    ?INFO("uid: ~s, msg_id: ~s", [User, MsgId]),
    ejabberd_router:route(AckPacket).

