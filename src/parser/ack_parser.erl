-module(ack_parser).

-include("packets.hrl").
-include("xmpp.hrl").

-export([
    xmpp_to_proto/1,
    proto_to_xmpp/1
]).


xmpp_to_proto(XmppAck) ->
    ProtoAck = #pb_ha_ack{
        id = XmppAck#ack.id,
        timestamp = binary_to_integer(XmppAck#ack.timestamp)
    },
    ProtoAck.


proto_to_xmpp(ProtoAck) ->
    XmppAck = #ack{
        id = ProtoAck#pb_ha_ack.id,
        timestamp = integer_to_binary(ProtoAck#pb_ha_ack.timestamp)
    },
    XmppAck.

