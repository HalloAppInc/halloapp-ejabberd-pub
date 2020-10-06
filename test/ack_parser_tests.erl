%%%-------------------------------------------------------------------
%%% @author yexin
%%% @copyright (C) 2020, HalloApp, Inc.
%%% @doc
%%%
%%% @end
%%% Created : 13. Jul 2020 12:28 PM
%%%-------------------------------------------------------------------
-module(ack_parser_tests).
-author("yexin").

-include_lib("eunit/include/eunit.hrl").
-include("packets.hrl").
-include("xmpp.hrl").
-include("parser_test_data.hrl").


%% -------------------------------------------- %%
%% Tests
%% -------------------------------------------- %%


xmpp_to_proto_test() -> 
    XmppAck = struct_util:create_ack(?ID1, undefined, undefined, ?TIMESTAMP1),
    PbAck = struct_util:create_pb_ack(?ID1, ?TIMESTAMP1_INT),

    ProtoAck = ack_parser:xmpp_to_proto(XmppAck),
    ?assertEqual(true, is_record(ProtoAck, pb_ack)),
    ?assertEqual(PbAck, ProtoAck).


proto_to_xmpp_test() ->
    XmppAck = struct_util:create_ack(?ID1, undefined, undefined, undefined),
    PbAck = struct_util:create_pb_ack(?ID1, undefined),

    ActualXmppAck = ack_parser:proto_to_xmpp(PbAck),
    ?assertEqual(true, is_record(ActualXmppAck, ack)),
    ?assertEqual(XmppAck, ActualXmppAck).

