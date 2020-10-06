%%%-------------------------------------------------------------------
%%% @author yexin
%%% @copyright (C) 2020, HalloApp, Inc.
%%% @doc
%%%
%%% @end
%%% Created : 22. Jul 2020 12:00 PM
%%%-------------------------------------------------------------------
-module(ha_auth_parser_tests).
-author("yexin").

-include_lib("eunit/include/eunit.hrl").
-include("packets.hrl").
-include("xmpp.hrl").
-include("parser_test_data.hrl").


%% -------------------------------------------- %%
%% internal tests
%% -------------------------------------------- %%


proto_to_xmpp_auth_request_test() ->
    XmppAuthRequest = struct_util:create_auth_request(?UID1, <<"123">>, active, <<"1">>, <<"android">>),

    PbClientMode = struct_util:create_pb_client_mode(active),
    PbClientVersion = struct_util:create_pb_client_version(<<"1">>, undefined),
    PbAuthRequest = struct_util:create_pb_auth_request(?UID1_INT, <<"123">>, PbClientMode, PbClientVersion, <<"android">>),

    ActualXmppAuth = ha_auth_parser:proto_to_xmpp(PbAuthRequest),
    ?assertEqual(true, is_record(ActualXmppAuth, halloapp_auth)),
    ?assertEqual(XmppAuthRequest, ActualXmppAuth).


xmpp_to_proto_auth_result_test() ->
    XmppAuthResult = struct_util:create_auth_result(<<"success">>, <<"welcome!">>, <<"MTIz">>),
    PbAuthResult = struct_util:create_pb_auth_result(<<"success">>, <<"welcome!">>, <<"123">>),

    ProtoAuthResult = ha_auth_parser:xmpp_to_proto(XmppAuthResult),
    ?assertEqual(true, is_record(ProtoAuthResult, pb_auth_result)),
    ?assertEqual(PbAuthResult, ProtoAuthResult).


