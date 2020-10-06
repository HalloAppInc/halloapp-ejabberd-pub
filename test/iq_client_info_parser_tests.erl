%%%-------------------------------------------------------------------
%%% @author yexin
%%% @copyright (C) 2020, HalloApp, Inc.
%%% @doc
%%%
%%% @end
%%% Created : 17. Jul 2020 3:05 PM
%%%-------------------------------------------------------------------
-module(iq_client_info_parser_tests).
-author("yexin").

-include_lib("eunit/include/eunit.hrl").
-include("packets.hrl").
-include("xmpp.hrl").
-include("parser_test_data.hrl").

%% -------------------------------------------- %%
%% internal tests
%% -------------------------------------------- %%


xmpp_to_proto_client_mode_test() ->
    ClientMode = struct_util:create_client_mode(active),
    XmppIq = struct_util:create_iq_stanza(?ID1, undefined, undefined, result, ClientMode),

    PbClientMode = struct_util:create_pb_client_mode(active),
    PbIq = struct_util:create_pb_iq(?ID1, result, PbClientMode),

    ProtoIq = iq_parser:xmpp_to_proto(XmppIq),
    ?assertEqual(true, is_record(ProtoIq, pb_iq)),
    ?assertEqual(PbIq, ProtoIq).


proto_to_xmpp_client_mode_test() ->
    ClientMode = struct_util:create_client_mode(active),
    XmppIq = struct_util:create_iq_stanza(?ID1, undefined, undefined, result, ClientMode),

    PbClientMode = struct_util:create_pb_client_mode(active),
    PbIq = struct_util:create_pb_iq(?ID1, result, PbClientMode),

    ActualXmppIq = iq_parser:proto_to_xmpp(PbIq),
    ?assertEqual(true, is_record(ActualXmppIq, iq)),
    ?assertEqual(XmppIq, ActualXmppIq).


xmpp_to_proto_client_version_test() ->
    ClientVersion = struct_util:create_client_version(<<"v1">>, <<"123">>),
    XmppIq = struct_util:create_iq_stanza(?ID1, undefined, undefined, result, ClientVersion),

    PbClientVersion = struct_util:create_pb_client_version(<<"v1">>, 123),
    PbIq = struct_util:create_pb_iq(?ID1, result, PbClientVersion),

    ProtoIq = iq_parser:xmpp_to_proto(XmppIq),
    ?assertEqual(true, is_record(ProtoIq, pb_iq)),
    ?assertEqual(PbIq, ProtoIq).


proto_to_xmpp_client_version_test() ->
    ClientVersion = struct_util:create_client_version(<<"v1">>, undefined),
    XmppIq = struct_util:create_iq_stanza(?ID1, undefined, undefined, get, ClientVersion),

    PbClientVersion = struct_util:create_pb_client_version(<<"v1">>, undefined),
    PbIq = struct_util:create_pb_iq(?ID1, get, PbClientVersion),

    ActualXmppIq = iq_parser:proto_to_xmpp(PbIq),
    ?assertEqual(true, is_record(ActualXmppIq, iq)),
    ?assertEqual(XmppIq, ActualXmppIq).

