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
    PbClientMode = struct_util:create_pb_client_mode(active),
    PbClientVersion = struct_util:create_pb_client_version(<<"1">>, undefined),
    XmppAuthRequest = struct_util:create_pb_auth_request(?UID1, <<"123">>, PbClientMode, PbClientVersion, <<"android">>),
    PbAuthRequest = struct_util:create_pb_auth_request(?UID1_INT, <<"123">>, PbClientMode, PbClientVersion, <<"android">>),

    ActualXmppAuth = ha_auth_parser:proto_to_xmpp(PbAuthRequest),
    ?assertEqual(XmppAuthRequest, ActualXmppAuth).


