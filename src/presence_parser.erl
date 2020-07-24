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
        last_seen = case XmppPresence#presence.last_seen of
            <<>> -> undefined;
            _ -> binary_to_integer(XmppPresence#presence.last_seen)
        end,
        uid = binary_to_integer(FromJID#jid.user)
    },
    ProtoPresence.


proto_to_xmpp(ProtoPresence) ->
    ToJID = #jid{
        user = integer_to_binary(ProtoPresence#pb_ha_presence.uid),
        server =  util:get_host()
    },
    XmppPresence = #presence{
        id = ProtoPresence#pb_ha_presence.id,
        type = ProtoPresence#pb_ha_presence.type,
        last_seen = case ProtoPresence#pb_ha_presence.last_seen of
            undefined -> <<>>;
            _ -> integer_to_binary(ProtoPresence#pb_ha_presence.last_seen)
        end
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

