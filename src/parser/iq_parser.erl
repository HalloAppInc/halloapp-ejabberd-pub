-module(iq_parser).

-include("packets.hrl").
-include("logger.hrl").
-include("xmpp.hrl").

-export([
    xmpp_to_proto/1,
    proto_to_xmpp/1
]).


%% -------------------------------------------- %%
%% XMPP to Protobuf
%% -------------------------------------------- %%


xmpp_to_proto(XmppIQ) ->
    SubEls = XmppIQ#iq.sub_els,
    Content = case XmppIQ#iq.sub_els of
        [] ->
            undefined;
        _ ->
            [SubEl] = SubEls,
            iq_payload_mapping(SubEl)
    end,
    ProtoIQ = #pb_iq{
        id = XmppIQ#iq.id,
        type = XmppIQ#iq.type,
        payload = Content
    },
    ProtoIQ.


iq_payload_mapping(SubEl) ->
    SubEl.


%% -------------------------------------------- %%
%% Protobuf to XMPP
%% -------------------------------------------- %%


proto_to_xmpp(ProtoIQ) ->
    Content = ProtoIQ#pb_iq.payload,
    SubEl = xmpp_iq_subel_mapping(Content),
    XmppIQ = #iq{
        id = ProtoIQ#pb_iq.id,
        type = ProtoIQ#pb_iq.type,
        sub_els = [SubEl]
    },
    XmppIQ.


xmpp_iq_subel_mapping(ProtoPayload) ->
    ProtoPayload.
