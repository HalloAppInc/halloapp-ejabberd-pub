%%%-------------------------------------------------------------------
%%% File: props_parser.erl
%%% Copyright (C) 2020, Halloapp Inc.
%%%
%%%-------------------------------------------------------------------

-module(props_parser).
-author('murali').

-include("packets.hrl").
-include("xmpp.hrl").

-export([
    xmpp_to_proto/1,
    proto_to_xmpp/1
]).


xmpp_to_proto(SubElement) when is_record(SubElement, prop) ->
    xmpp_to_proto_prop(SubElement);
xmpp_to_proto(SubElement) when is_record(SubElement, props) ->
    xmpp_to_proto_props(SubElement).

xmpp_to_proto_prop(XmppProp) ->
    #pb_prop{
        name = util:to_binary(XmppProp#prop.name),
        value = util:to_binary(XmppProp#prop.value)
    }.

xmpp_to_proto_props(XmppProps) ->
    Props = lists:map(fun xmpp_to_proto_prop/1, XmppProps#props.props),
    #pb_props{
        hash = base64:decode(XmppProps#props.hash),
        props = Props
    }.


proto_to_xmpp(ProtoElement) when is_record(ProtoElement, pb_props) ->
    proto_to_xmpp_pb_props(ProtoElement).

proto_to_xmpp_pb_props(_ProtoInvites) ->
    #props{
        hash = <<>>,
        props = []
    }.

