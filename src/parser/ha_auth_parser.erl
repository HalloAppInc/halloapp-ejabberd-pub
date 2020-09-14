-module(ha_auth_parser).

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


xmpp_to_proto(XmppAuth) ->
    ProtoContent = case element(1, XmppAuth) of
        halloapp_auth -> xmpp_to_proto_auth_request(XmppAuth);
        halloapp_auth_result -> xmpp_to_proto_auth_result(XmppAuth)
    end,
    ProtoContent.


xmpp_to_proto_auth_request(XmppAuth) ->
    #pb_auth_request{
        uid = util_parser:xmpp_to_proto_uid(XmppAuth#halloapp_auth.uid),
        pwd = XmppAuth#halloapp_auth.pwd,
        cm = #pb_client_mode{mode = XmppAuth#halloapp_auth.client_mode},
        cv = #pb_client_version{version = XmppAuth#halloapp_auth.client_version},
        resource = XmppAuth#halloapp_auth.resource
    }.


xmpp_to_proto_auth_result(XmppAuth) ->
    #pb_auth_result{
        result = XmppAuth#halloapp_auth_result.result,
        reason = XmppAuth#halloapp_auth_result.reason,
        props_hash = base64:decode(XmppAuth#halloapp_auth_result.props_hash)
    }.


%% -------------------------------------------- %%
%% Protobuf to XMPP
%% -------------------------------------------- %%


proto_to_xmpp(ProtoAuth) ->
    XmppAuth = case element(1, ProtoAuth) of
        pb_auth_request -> proto_to_xmpp_auth_request(ProtoAuth);
        pb_auth_result -> proto_to_xmpp_auth_result(ProtoAuth)
    end,
    XmppAuth.


proto_to_xmpp_auth_request(ProtoAuth) ->
    PbClientMode = ProtoAuth#pb_auth_request.cm,
    PbClientVersion = ProtoAuth#pb_auth_request.cv,
    #halloapp_auth{
        uid = util_parser:proto_to_xmpp_uid(ProtoAuth#pb_auth_request.uid),
        pwd = ProtoAuth#pb_auth_request.pwd,
        client_mode = util:to_atom(PbClientMode#pb_client_mode.mode),
        client_version = PbClientVersion#pb_client_version.version,
        resource = ProtoAuth#pb_auth_request.resource
    }.


proto_to_xmpp_auth_result(ProtoAuth) ->
    #halloapp_auth_result{
        result = ProtoAuth#pb_auth_result.result,
        reason = ProtoAuth#pb_auth_result.reason,
        props_hash = base64:encode(ProtoAuth#pb_auth_result.props_hash)
    }.

