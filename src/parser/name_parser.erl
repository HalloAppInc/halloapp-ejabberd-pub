-module(name_parser).

-include("packets.hrl").
-include("xmpp.hrl").

-export([
    xmpp_to_proto/1,
    proto_to_xmpp/1
]).


xmpp_to_proto(XmppName) ->
    #pb_name{
        uid = XmppName#name.uid,
        name = XmppName#name.name
    }.


proto_to_xmpp(ProtoName) ->
    #name{
        uid = ProtoName#pb_name.uid,
        name = ProtoName#pb_name.name
    }.

