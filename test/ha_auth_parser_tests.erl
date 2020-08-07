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

%% -------------------------------------------- %%
%% define auth request and auth result constants
%% -------------------------------------------- %%

-define(XMPP_AUTH_REQUEST,
    #halloapp_auth{
        uid = <<"10093">>,
        pwd = <<"TNpwdc">>,
        client_mode = active, 
        client_version = <<"2.3">>,
        resource = <<"android">>
    }
).

-define(PB_AUTH_REQUEST,
    #pb_auth_request{
        uid = 10093,
        pwd = <<"TNpwdc">>,
        cm = #pb_client_mode{mode = active},
        cv = #pb_client_version{version = <<"2.3">>},
        resource = <<"android">>
    }
).

-define(XMPP_AUTH_RESULT,
    #halloapp_auth_result{
        result = <<"Success!">>,
        reason = <<"none">>
    }
).

-define(PB_AUTH_RESULT,
    #pb_auth_result{
        result = <<"Success!">>,
        reason = <<"none">>
    }
).


%% -------------------------------------------- %%
%% internal tests
%% -------------------------------------------- %%


xmpp_to_proto_auth_request_test() -> 
    ProtoAuth = ha_auth_parser:xmpp_to_proto(?XMPP_AUTH_REQUEST),
    ?assertEqual(true, is_record(ProtoAuth, pb_auth_request)),
    ?assertEqual(?PB_AUTH_REQUEST, ProtoAuth).


proto_to_xmpp_auth_request_test() -> 
    XmppAuth = ha_auth_parser:proto_to_xmpp(?PB_AUTH_REQUEST),
    ?assertEqual(true, is_record(XmppAuth, halloapp_auth)),
    ?assertEqual(?XMPP_AUTH_REQUEST, XmppAuth).


xmpp_to_proto_auth_result_test() -> 
    ProtoAuth = ha_auth_parser:xmpp_to_proto(?XMPP_AUTH_RESULT),
    ?assertEqual(true, is_record(ProtoAuth, pb_auth_result)),
    ?assertEqual(?PB_AUTH_RESULT, ProtoAuth).


proto_to_xmpp_auth_result_test() -> 
    XmppAuth = ha_auth_parser:proto_to_xmpp(?PB_AUTH_RESULT),
    ?assertEqual(true, is_record(XmppAuth, halloapp_auth_result)),
    ?assertEqual(?XMPP_AUTH_RESULT, XmppAuth).

