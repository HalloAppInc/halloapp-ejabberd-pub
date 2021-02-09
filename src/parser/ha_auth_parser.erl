-module(ha_auth_parser).

-include("packets.hrl").
-include("logger.hrl").
-include("xmpp.hrl").

-export([
    proto_to_xmpp/1
]).



%% -------------------------------------------- %%
%% Protobuf to XMPP
%% -------------------------------------------- %%


proto_to_xmpp(#pb_auth_request{} = ProtoAuth) ->
    ProtoAuth#pb_auth_request{uid = util_parser:proto_to_xmpp_uid(ProtoAuth#pb_auth_request.uid)}.

