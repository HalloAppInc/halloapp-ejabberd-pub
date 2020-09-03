%%%-------------------------------------------------------------------
%%% File: invite_parser.erl
%%% Copyright (C) 2020, Halloapp Inc.
%%%
%%%-------------------------------------------------------------------

-module(invite_parser).
-author('murali').

-include("packets.hrl").
-include("xmpp.hrl").

-export([
    xmpp_to_proto/1,
    proto_to_xmpp/1
]).


xmpp_to_proto(SubElement) when is_record(SubElement, invite) ->
    xmpp_to_proto_invite(SubElement);
xmpp_to_proto(SubElement) when is_record(SubElement, invites) ->
    xmpp_to_proto_invites(SubElement).

xmpp_to_proto_invite(XmppInvite) ->
    Result = case XmppInvite#invite.result of
        undefined -> undefined;
        R -> util:to_binary(R)
    end,
    Reason = case XmppInvite#invite.reason of
        undefined -> undefined;
        Rn -> util:to_binary(Rn)
    end,
    #pb_invite{
        phone = XmppInvite#invite.phone,
        result = Result,
        reason = Reason
    }.

xmpp_to_proto_invites(XmppInvites) ->
    Invites = lists:map(fun xmpp_to_proto_invite/1, XmppInvites#invites.invites),
    #pb_invites{
        invites_left = XmppInvites#invites.invites_left,
        time_until_refresh = XmppInvites#invites.time_until_refresh,
        invites = Invites
    }.


proto_to_xmpp(ProtoElement) when is_record(ProtoElement, pb_invite) ->
   proto_to_xmpp_pb_invite(ProtoElement);
proto_to_xmpp(ProtoElement) when is_record(ProtoElement, pb_invites) ->
    proto_to_xmpp_pb_invites(ProtoElement).

proto_to_xmpp_pb_invite(ProtoInvite) ->
    #invite{
        phone = ProtoInvite#pb_invite.phone,
        result = util:to_atom(ProtoInvite#pb_invite.result),
        reason = util:to_atom(ProtoInvite#pb_invite.reason)
    }.

proto_to_xmpp_pb_invites(ProtoInvites) ->
    Invites = lists:map(fun proto_to_xmpp_pb_invite/1, ProtoInvites#pb_invites.invites),
    #invites{
        invites_left = ProtoInvites#pb_invites.invites_left,
        time_until_refresh = ProtoInvites#pb_invites.time_until_refresh,
        invites = Invites
    }.

