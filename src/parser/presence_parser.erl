-module(presence_parser).

-include("packets.hrl").
-include("xmpp.hrl").

-export([
    xmpp_to_proto/1,
    proto_to_xmpp/1
]).


xmpp_to_proto(XmppPresence) ->
    FromJID = XmppPresence#presence.from,
    ProtoPresence = #pb_ha_presence{
        id = XmppPresence#presence.id,
        type = XmppPresence#presence.type,
        last_seen = util_parser:maybe_convert_to_integer(XmppPresence#presence.last_seen),
        uid = util_parser:xmpp_to_proto_uid(FromJID#jid.user)
    },
    ProtoPresence.


proto_to_xmpp(ProtoPresence) ->
    ToUid = util_parser:proto_to_xmpp_uid(ProtoPresence#pb_ha_presence.uid),
    Server = util:get_host(),
    ToJID = jid:make(ToUid, Server),
    XmppPresence = #presence{
        id = ProtoPresence#pb_ha_presence.id,
        type = ProtoPresence#pb_ha_presence.type,
        last_seen = util_parser:maybe_convert_to_binary(ProtoPresence#pb_ha_presence.last_seen)},
    Result = case ProtoPresence#pb_ha_presence.type of
        subscribe ->
            XmppPresence#presence{to = ToJID};
        unsubscribe ->
            XmppPresence#presence{to = ToJID};
        _ ->
            XmppPresence
        end,
    Result.

