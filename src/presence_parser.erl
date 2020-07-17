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
        last_seen = XmppPresence#presence.last_seen,
        uid = FromJID#jid.user
    },
    ProtoPresence.


proto_to_xmpp(ProtoPresence) -> 
    ToJID = #jid{
        user = ProtoPresence#pb_ha_presence.uid,
        server =  util:get_host()
    },
    XmppPresence = #presence{
        id = ProtoPresence#pb_ha_presence.id,
        type = ProtoPresence#pb_ha_presence.type,
        last_seen = ProtoPresence#pb_ha_presence.last_seen
    },
    Result = case ProtoPresence#pb_ha_presence.type of 
        subscribe -> 
            XmppPresence#presence{to = ToJID};
        unsubscribe -> 
            XmppPresence#presence{to = ToJID};
        _ -> 
            XmppPresence
        end, 
    Result.

