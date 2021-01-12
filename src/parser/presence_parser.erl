-module(presence_parser).

-include("packets.hrl").
-include("xmpp.hrl").
-include("logger.hrl").

-export([
    xmpp_to_proto/1,
    proto_to_xmpp/1
]).


xmpp_to_proto(XmppPresence) ->
    FromJID = XmppPresence#presence.from,
    ProtoPresence = #pb_presence{
        id = XmppPresence#presence.id,
        type = XmppPresence#presence.type,
        last_seen = util_parser:maybe_convert_to_integer(XmppPresence#presence.last_seen),
        uid = util_parser:xmpp_to_proto_uid(FromJID#jid.user),
        from_uid = util_parser:xmpp_to_proto_uid(FromJID#jid.user)
    },
    ProtoPresence.


proto_to_xmpp(ProtoPresence) ->
    ToUid1 = util_parser:proto_to_xmpp_uid(ProtoPresence#pb_presence.uid),
    ToUid2 = util_parser:proto_to_xmpp_uid(ProtoPresence#pb_presence.to_uid),
    Server = util:get_host(),
    ToJID = case {ProtoPresence#pb_presence.type, ToUid2} of
        {subscribe, <<>>} ->
            ?WARNING("pb_presence_uid field is still being used"),
            jid:make(ToUid1, Server);
        {unsubscribe, <<>>} ->
            ?WARNING("pb_presence_uid field is still being used"),
            jid:make(ToUid1, Server);
        _ ->
            jid:make(ToUid2, Server)
    end,
    XmppPresence = #presence{
        id = ProtoPresence#pb_presence.id,
        type = ProtoPresence#pb_presence.type,
        last_seen = util_parser:maybe_convert_to_binary(ProtoPresence#pb_presence.last_seen)},
    Result = case ProtoPresence#pb_presence.type of
        subscribe ->
            XmppPresence#presence{to = ToJID};
        unsubscribe ->
            XmppPresence#presence{to = ToJID};
        _ ->
            XmppPresence
        end,
    Result.

