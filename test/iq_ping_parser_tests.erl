%%%-------------------------------------------------------------------
%%% @author yexin
%%% @copyright (C) 2020, HalloApp, Inc.
%%% @doc
%%%
%%% @end
%%% Created : 17. Jul 2020 3:28 PM
%%%-------------------------------------------------------------------
-module(iq_ping_parser_tests).
-author("yexin").

-include_lib("eunit/include/eunit.hrl").
-include("packets.hrl").
-include("xmpp.hrl").
-include("parser_test_data.hrl").

%% -------------------------------------------- %%
%% internal tests
%% -------------------------------------------- %%


xmpp_to_proto_ping_test() ->
    PbPing = struct_util:create_pb_ping(),
    PbIq = struct_util:create_pb_iq(?ID2, get, PbPing),
    XmppIq = struct_util:create_iq_stanza(?ID2, undefined, undefined, get, PbPing),

    ProtoIQ = iq_parser:xmpp_to_proto(XmppIq),
    ?assertEqual(true, is_record(ProtoIQ, pb_iq)),
    ?assertEqual(PbIq, ProtoIQ).


proto_to_xmpp_ping_test() ->
    PbPing = struct_util:create_pb_ping(),
    PbIq = struct_util:create_pb_iq(?ID2, result, PbPing),
    XmppIq = struct_util:create_iq_stanza(?ID2, undefined, undefined, result, PbPing),

    ActualXmppIQ = iq_parser:proto_to_xmpp(PbIq),
    ?assertEqual(true, is_record(ActualXmppIQ, iq)),
    ?assertEqual(XmppIq, ActualXmppIQ).

