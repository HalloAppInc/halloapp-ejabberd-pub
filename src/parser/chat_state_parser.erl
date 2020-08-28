-module(chat_state_parser).

-include("packets.hrl").
-include("xmpp.hrl").

-export([
    xmpp_to_proto/1,
    proto_to_xmpp/1
]).


xmpp_to_proto(XmppChatState) ->
    FromUid = XmppChatState#chat_state.from#jid.luser,
    #pb_ha_chat_state{
        type = XmppChatState#chat_state.type,
        thread_id = XmppChatState#chat_state.thread_id,
        thread_type = XmppChatState#chat_state.thread_type,
        from_uid = util_parser:xmpp_to_proto_uid(FromUid)
    }.


proto_to_xmpp(ProtoChatState) ->
    Server = util:get_host(),
    FromUid = util_parser:proto_to_xmpp_uid(ProtoChatState#pb_ha_chat_state.from_uid),
    FromJid = jid:make(FromUid, Server),
    ToJid = jid:make(Server),
    #chat_state{
        type = ProtoChatState#pb_ha_chat_state.type,
        thread_id = ProtoChatState#pb_ha_chat_state.thread_id,
        thread_type = ProtoChatState#pb_ha_chat_state.thread_type,
        from = FromJid,
        to = ToJid
    }.

