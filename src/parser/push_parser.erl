-module(push_parser).

-include("packets.hrl").
-include("logger.hrl").
-include("xmpp.hrl").

-export([
    xmpp_to_proto/1,
    proto_to_xmpp/1
]).


xmpp_to_proto(SubEl) when is_record(SubEl, push_register) ->
    PushToken = #pb_push_token{
        os = util:to_atom(element(1, SubEl#push_register.push_token)),
        token = element(2, SubEl#push_register.push_token)
    },
    #pb_push_register{
        push_token = PushToken
    };
xmpp_to_proto(SubEl) when is_record(SubEl, notification_prefs) ->
    PushPrefs = lists:map(
            fun(XmppPushPref) ->
                #pb_push_pref{
                    name = XmppPushPref#push_pref.name,
                    value = XmppPushPref#push_pref.value
                }
            end, SubEl#notification_prefs.push_prefs),
    #pb_notification_prefs{
        push_prefs = PushPrefs
    }.


proto_to_xmpp(ProtoPayload) when is_record(ProtoPayload, pb_push_register) ->
    PbPushToken = ProtoPayload#pb_push_register.push_token,
    #push_register{
        push_token = {
            util:to_binary(PbPushToken#pb_push_token.os),
            PbPushToken#pb_push_token.token
        }
    };
proto_to_xmpp(ProtoPayload) when is_record(ProtoPayload, pb_notification_prefs) ->
    PushPrefs = lists:map(
            fun(PbPushPref) ->
                Value = case PbPushPref#pb_push_pref.value of
                    undefined -> false;
                    V -> V
                end,
                #push_pref{
                    name = PbPushPref#pb_push_pref.name,
                    value = Value
                }
            end, ProtoPayload#pb_notification_prefs.push_prefs),
    #notification_prefs{
        push_prefs = PushPrefs
    }.

