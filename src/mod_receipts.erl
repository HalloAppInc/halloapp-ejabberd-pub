%%%----------------------------------------------------------------------
%%% File    : mod_receipts.erl
%%%
%%% Copyright (C) 2019 halloappinc.
%%%
%%% This module registers using the user_send_packet hook to be notified 
%%% on every new packet received by the server. If the packet is a message stanza
%%% and if it is about a receipt of the message by a client to another client,
%%% the server updates the timestamp on the receipt and returns the new packet.
%%% This is useful so that the clients need not worry about having the wrong
%%% timestamp on the devices.
%%% Currently, we do this for both delivery and seen receipts.
%%%----------------------------------------------------------------------

-module(mod_receipts).
-author('murali').
-behaviour(gen_mod).

-include("logger.hrl").
-include("xmpp.hrl").

%% gen_mod API.
-export([start/2, stop/1, depends/2, mod_options/1, reload/3]).
%% Hooks.
-export([user_send_packet/1, user_ack_packet/1]).

-type state() :: ejabberd_c2s:state().

start(Host, _Opts) ->
    ejabberd_hooks:add(user_send_packet, Host, ?MODULE, user_send_packet, 10),
    ejabberd_hooks:add(user_ack_packet, Host, ?MODULE, user_ack_packet, 10),
    ok.

stop(Host) ->
    ejabberd_hooks:delete(user_send_packet, Host, ?MODULE, user_send_packet, 10),
    ejabberd_hooks:delete(user_ack_packet, Host, ?MODULE, user_ack_packet, 10),
    ok.

depends(_Host, _Opts) ->
    [].

mod_options(_Host) ->
    [].

reload(_Host, _NewOpts, _OldOpts) ->
    ok.


%% This hook is invoked on every packet received from the user.
%% We check if the packet has a receipt element (could be delivery/seen) and add a timestamp.
-spec user_send_packet({stanza(), state()}) -> {stanza(), state()}.
user_send_packet({Packet, State}) ->
	TimestampSec = util:now_binary(),
	NewPacket = update_timestamp_if_receipts_message(Packet, TimestampSec),
	{NewPacket, State}.


%% Hook trigerred when user sent the server an ack stanza for this particular packet.
-spec user_ack_packet(Packet :: stanza()) -> ok.
user_ack_packet(#message{id = MsgId, to = To, from = From, sub_els = [SubElement]})
		when is_record(SubElement, chat) ->
	TimestampSec = util:now_binary(),
	FromJID = To,
	ToJID = From,
	send_receipt(ToJID, FromJID, MsgId, TimestampSec);
user_ack_packet(_Packet) ->
	ok.


%% Send a delivery receipt to the ToJID from FromJID using Id and Timestamp.
-spec send_receipt(ToJID :: jid(), FromJID :: jid(),
                    Id :: binary(), Timestamp :: binary()) -> ok.
send_receipt(ToJID, FromJID, Id, Timestamp) ->
    MessageReceipt = #message{to = ToJID, from = FromJID,
                                sub_els = [#receipt_response{id = Id, timestamp = Timestamp}]},
    ejabberd_router:route(MessageReceipt).


%% Update timestamp if the packet is message with a receipt subelement within the stanza.
%% Currently, we handle both delivery and seen receipts.
-spec update_timestamp_if_receipts_message(stanza(), binary()) -> stanza().
update_timestamp_if_receipts_message(
				#message{sub_els = [#xmlel{name = <<"seen">>} = SeenXmlEl]} = Packet,
																					TimestampSec) ->
	SeenXmlElement = xmpp:decode(SeenXmlEl),
	T = SeenXmlElement#receipt_seen.timestamp,
	case T of
		<<>> ->
			NewPacket = xmpp:set_els(Packet,
										[SeenXmlElement#receipt_seen{timestamp = TimestampSec}]);
		_ ->
			NewPacket = Packet
	end,
	?DEBUG("mod_receipts: user_send_packet: updated the timestamp on this packet: ~p", [NewPacket]),
	NewPacket;

update_timestamp_if_receipts_message(
				#message{sub_els = [#xmlel{name = <<"received">>} = ReceivedXmlEl]} = Packet,
																					TimestampSec) ->
	ReceivedXmlElement = xmpp:decode(ReceivedXmlEl),
	T = ReceivedXmlElement#receipt_response.timestamp,
	case T of
		<<>> ->
			NewPacket = xmpp:set_els(Packet,
								[ReceivedXmlElement#receipt_response{timestamp = TimestampSec}]);
		_ ->
			NewPacket = Packet
	end,
	?DEBUG("mod_receipts: user_send_packet: updated the timestamp on this packet: ~p", [NewPacket]),
	NewPacket;

update_timestamp_if_receipts_message(Packet, _TimestampSec) ->
	?DEBUG("mod_receipts: user_send_packet: this packet: ~p is not modified at all.", [Packet]),
	Packet.


