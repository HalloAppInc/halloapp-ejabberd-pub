-module(client_info_parser).

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
        client_mode -> xmpp_to_proto_client_mode(SubEl);
        client_version -> xmpp_to_proto_client_version(SubEl)
    end, 
    ProtoContent.

xmpp_to_proto_client_mode(SubEl) ->
    #pb_client_mode{
        mode = SubEl#client_mode.mode
    }.


xmpp_to_proto_client_version(SubEl) ->
    #pb_client_version{
        version = SubEl#client_version.version,
        expires_in_seconds = binary_to_integer(SubEl#client_version.seconds_left)
    }.


%% -------------------------------------------- %%
%% Protobuf to XMPP
%% -------------------------------------------- %%


proto_to_xmpp(ProtoPayload) ->
    SubEl = case element(1, ProtoPayload) of
        pb_client_mode -> proto_to_xmpp_client_mode(ProtoPayload);
        pb_client_version -> proto_to_xmpp_client_version(ProtoPayload)
    end, 
    SubEl.


proto_to_xmpp_client_mode(ProtoPayload) ->
    #client_mode{
        mode = ProtoPayload#pb_client_mode.mode
    }.


proto_to_xmpp_client_version(ProtoPayload) -> 
    #client_version{
        version = ProtoPayload#pb_client_version.version,
        seconds_left = integer_to_binary(ProtoPayload#pb_client_version.expires_in_seconds)
    }.

