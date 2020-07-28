-module(receipts_parser).

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

xmpp_to_proto(SubEl) ->
    ProtoContent = case element(1, SubEl) of
        receipt_seen -> xmpp_to_proto_seen(SubEl);
        receipt_response -> xmpp_to_proto_response(SubEl)
    end,
    ProtoContent.


xmpp_to_proto_seen(SubEl) ->
    #pb_seen_receipt{
        id = SubEl#receipt_seen.id,
        thread_id = SubEl#receipt_seen.thread_id,
        timestamp = binary_to_integer(SubEl#receipt_seen.timestamp)
    }.

xmpp_to_proto_response(SubEl) ->
    #pb_delivery_receipt{
        id = SubEl#receipt_response.id,
        thread_id = SubEl#receipt_response.thread_id,
        timestamp = binary_to_integer(SubEl#receipt_response.timestamp)
    }.


%% -------------------------------------------- %%
%% Protobuf to XMPP
%% -------------------------------------------- %%


proto_to_xmpp(ProtoPayload) ->
    SubEl = case element(1, ProtoPayload) of
        pb_seen_receipt -> proto_to_xmpp_seen(ProtoPayload);
        pb_delivery_receipt -> proto_to_xmpp_received(ProtoPayload)
    end,
    SubEl.


proto_to_xmpp_seen(ProtoPayload) ->
    #receipt_seen{
        id = ProtoPayload#pb_seen_receipt.id,
        thread_id = ProtoPayload#pb_seen_receipt.thread_id,
        timestamp = integer_to_binary(ProtoPayload#pb_seen_receipt.timestamp)
    }.


proto_to_xmpp_received(ProtoPayload) ->
    #receipt_response{
        id = ProtoPayload#pb_delivery_receipt.id,
        thread_id = ProtoPayload#pb_delivery_receipt.thread_id,
        timestamp = integer_to_binary(ProtoPayload#pb_delivery_receipt.timestamp)
    }.

