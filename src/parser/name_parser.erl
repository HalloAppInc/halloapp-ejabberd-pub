-module(name_parser).

-include("packets.hrl").
-include("xmpp.hrl").

-export([
    xmpp_to_proto/1,
    proto_to_xmpp/1
]).


xmpp_to_proto(XmppName) ->
    #pb_name{
        uid = util_parser:xmpp_to_proto_uid(XmppName#name.uid),
        name = XmppName#name.name
    }.


proto_to_xmpp(ProtoName) ->
    #name{
        uid = util_parser:proto_to_xmpp_uid(ProtoName#pb_name.uid),
        name = ProtoName#pb_name.name
    }.

