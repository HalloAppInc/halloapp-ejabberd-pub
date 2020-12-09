%%%-------------------------------------------------------------------
%%% @author yexin
%%% @copyright (C) 2020, HalloApp, Inc.
%%% @doc
%%%
%%% @end
%%% Created : 17. Jul 2020 3:25 PM
%%%-------------------------------------------------------------------
-module(client_log_parser_tests).
-author("nikola").

-include_lib("eunit/include/eunit.hrl").
-include("packets.hrl").
-include("xmpp.hrl").
-include("parser_test_data.hrl").


%% -------------------------------------------- %%
%% internal tests
%% -------------------------------------------- %%


setup_stanzas() ->
    Dim1 = struct_util:create_dim_st(?D1NAME, ?D1VALUE1),
    Dim2 = struct_util:create_dim_st(?D2NAME, ?D2VALUE1),
    Dim3 = struct_util:create_dim_st(?D1NAME, ?D1VALUE2),
    Count1 = struct_util:create_count_st(?NS1, ?METRIC1, ?COUNT1, [Dim1, Dim2]),
    Count2 = struct_util:create_count_st(?NS2, ?METRIC2, ?COUNT2, [Dim3]),
    Event1 = struct_util:create_pb_event_data(?UID1, android, <<"0.1.2">>, ?EVENT1),
    Event2 = struct_util:create_pb_event_data(?UID1, android, <<"0.1.2">>, ?EVENT2),
    XmppClientLog = struct_util:create_client_log_st([Count1, Count2], [Event1, Event2]),

    PbDim1 = struct_util:create_pb_dim(?D1NAME, ?D1VALUE1),
    PbDim2 = struct_util:create_pb_dim(?D2NAME, ?D2VALUE1),
    PbDim3 = struct_util:create_pb_dim(?D1NAME, ?D1VALUE2),
    PbCount1 = struct_util:create_pb_count(?NS1, ?METRIC1, ?COUNT1, [PbDim1, PbDim2]),
    PbCount2 = struct_util:create_pb_count(?NS2, ?METRIC2, ?COUNT2, [PbDim3]),
    PbEvent1 = struct_util:create_pb_event_data(?UID1, android, <<"0.1.2">>, ?EVENT1),
    PbEvent2 = struct_util:create_pb_event_data(?UID1, android, <<"0.1.2">>, ?EVENT2),
    PbClientLog = struct_util:create_pb_client_log([PbCount1, PbCount2], [PbEvent1, PbEvent2]),
    {XmppClientLog, PbClientLog}.


xmpp_to_proto_client_log_test() ->
    {XmppClientLog, PbClientLog} = setup_stanzas(),
    Proto = client_log_parser:xmpp_to_proto(XmppClientLog),
    ?assertEqual(true, is_record(Proto, pb_client_log)),
    ?assertEqual(PbClientLog, Proto).


proto_to_xmpp_whisper_keys_test() ->
    {XmppClientLog, PbClientLog} = setup_stanzas(),
    Xmpp = client_log_parser:proto_to_xmpp(PbClientLog),
    ?assertEqual(true, is_record(Xmpp, client_log_st)),
    ?assertEqual(XmppClientLog, Xmpp).

