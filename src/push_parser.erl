-module(push_parser).

-include("packets.hrl").
-include("logger.hrl").
-include("xmpp.hrl").

-export([
    xmpp_to_proto/1,
    proto_to_xmpp/1
]).


xmpp_to_proto(SubEl) ->
    PushToken = #pb_push_token{
        os = util:to_atom(element(1, SubEl#push_register.push_token)),
        token = element(2, SubEl#push_register.push_token)
    },
    #pb_push_register{
        push_token = PushToken
    }.


proto_to_xmpp(ProtoPayload) ->
    PbPushToken = ProtoPayload#pb_push_register.push_token,
    #push_register{
        push_token = {
            util:to_binary(PbPushToken#pb_push_token.os), 
            PbPushToken#pb_push_token.token
        }
    }.

