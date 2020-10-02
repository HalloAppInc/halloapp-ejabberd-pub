-module(client_log_parser).

-include("packets.hrl").
-include("logger.hrl").
-include("xmpp.hrl").

-export([
    xmpp_to_proto/1,
    proto_to_xmpp/1
]).


xmpp_to_proto(SubEl) ->
    auto_parser:xmpp_to_proto(SubEl).

proto_to_xmpp(SubEl) ->
    auto_parser:proto_to_xmpp(SubEl).

% This is the manual parser. Keeping the code for now just in case.
% The autoparser is nice.
%%xmpp_to_proto(SubEl) ->
%%    #pb_client_log{
%%        counts = xmpp_to_proto_counts(SubEl#client_log_st.counts),
%%        events = xmpp_to_proto_events(SubEl#client_log_st.events)
%%    }.
%%
%%
%%proto_to_xmpp(ProtoPayload) ->
%%    #client_log_st{
%%        counts = proto_to_xmpp_counts(ProtoPayload#pb_client_log.counts),
%%        events = proto_to_xmpp_events(ProtoPayload#pb_client_log.events)
%%    }.
%%
%%
%%xmpp_to_proto_counts(CountsSt) ->
%%    lists:map(fun xmpp_to_proto_count/1, CountsSt).
%%
%%
%%xmpp_to_proto_count(CountSt) ->
%%    #pb_count{
%%        namespace = CountSt#count_st.namespace,
%%        metric = CountSt#count_st.metric,
%%        count =  CountSt#count_st.count,
%%        dims =  xmpp_to_proto_dims(CountSt#count_st.dims)
%%    }.
%%
%%
%%xmpp_to_proto_dims(DimsSt) ->
%%    lists:map(fun xmpp_to_proto_dim/1, DimsSt).
%%
%%
%%xmpp_to_proto_dim(DimSt) ->
%%    #pb_dim{
%%        name = DimSt#dim_st.name,
%%        value = DimSt#dim_st.value
%%    }.
%%
%%
%%xmpp_to_proto_events(EventsSt) ->
%%    lists:map(fun xmpp_to_proto_event/1, EventsSt).
%%
%%
%%xmpp_to_proto_event(EventSt) ->
%%    #pb_event{
%%        namespace = EventSt#event_st.namespace,
%%        event = EventSt#event_st.event
%%    }.
%%
%%
%%proto_to_xmpp_counts(PBCounts) ->
%%    lists:map(fun proto_to_xmpp_count/1, PBCounts).
%%
%%
%%proto_to_xmpp_count(PBCount) ->
%%    #count_st{
%%        namespace = PBCount#pb_count.namespace,
%%        metric = PBCount#pb_count.metric,
%%        count = PBCount#pb_count.count,
%%        dims = proto_to_xmpp_dims(PBCount#pb_count.dims)
%%    }.
%%
%%
%%proto_to_xmpp_dims(PBDims) ->
%%    lists:map(fun proto_to_xmpp_dim/1, PBDims).
%%
%%
%%proto_to_xmpp_dim(PBDim) ->
%%    #dim_st{
%%        name = PBDim#pb_dim.name,
%%        value = PBDim#pb_dim.value
%%    }.
%%
%%
%%proto_to_xmpp_events(PBEvents) ->
%%    lists:map(fun proto_to_xmpp_event/1, PBEvents).
%%
%%
%%proto_to_xmpp_event(PBEvent) ->
%%    #event_st{
%%        namespace = PBEvent#pb_event.namespace,
%%        event = PBEvent#pb_event.event
%%    }.
%%
