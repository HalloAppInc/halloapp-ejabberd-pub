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
-include("translate.hrl").

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
user_send_packet({Packet, #{lserver := ServerHost} = _State} = Acc) ->
    case ?needs_ack_packet(Packet) of
        true -> send_ack(Packet);
        false -> ok
    end,
    case ?is_ack_packet(Packet) of
        true ->
            ejabberd_hooks:run(user_send_ack, ServerHost, [Packet]);
        false ->
            ok
    end,
    Acc.


%% Sends an ack packet.
-spec send_ack(message()) -> ok.
send_ack(#message{id = MsgId, from = #jid{user = User, server = ServerHost} = From} = Packet) ->
    PacketTs = xmpp:get_timestamp(Packet),
    Timestamp = case PacketTs of
        undefined ->
            ?WARNING_MSG("Uid: ~s, timestamp is undefined, msg_id: ~s", [User, MsgId]),
            util:now_binary();
        <<>> ->
            ?WARNING_MSG("Uid: ~s, timestamp is empty, msg_id: ~s", [User, MsgId]),
            util:now_binary();
        PacketTs -> PacketTs
    end,
    AckPacket = #ack{id = MsgId, to = From, from = jid:make(ServerHost), timestamp = Timestamp},
    ?INFO_MSG("uid: ~s, msg_id: ~s", [User, MsgId]),
    ejabberd_router:route(AckPacket).

