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

%% -------------------------------------------- %%
%% define client_mode and client_version constants
%% -------------------------------------------- %%

-define(XMPP_IQ_CLIENT_MODE,
    #iq{
        id = <<"clientMODEid">>,
        type = set,
        sub_els = [#client_mode{
                mode = active
            }
        ]
    }
).

-define(PB_IQ_CLIENT_MODE,
    #pb_ha_iq{
        id = <<"clientMODEid">>,
        type = set,
        payload = #pb_iq_payload{
            content = {client_mode, #pb_client_mode{
                mode = active
            }}
        }
    }
).

-define(XMPP_IQ_CLIENT_VERSION,
    #iq{
        id = <<"clientVERSIONid">>,
        type = set,
        sub_els = [#client_version{
                version = <<"2.3">>,
                seconds_left = <<"23">>
            }
        ]
    }
).

-define(PB_IQ_CLIENT_VERSION,
    #pb_ha_iq{
        id = <<"clientVERSIONid">>,
        type = set,
        payload = #pb_iq_payload{
            content = {client_version, #pb_client_version{
                version = <<"2.3">>,
                expires_in_seconds = 23
            }}
        }
    }
).


%% -------------------------------------------- %%
%% internal tests
%% -------------------------------------------- %%


xmpp_to_proto_client_mode_test() -> 
    ProtoIQ = iq_parser:xmpp_to_proto(?XMPP_IQ_CLIENT_MODE),
    ?assertEqual(true, is_record(ProtoIQ, pb_ha_iq)),
    ?assertEqual(?PB_IQ_CLIENT_MODE, ProtoIQ).


proto_to_xmpp_client_mode_test() ->
    XmppIQ = iq_parser:proto_to_xmpp(?PB_IQ_CLIENT_MODE),
    ?assertEqual(true, is_record(XmppIQ, iq)),
    ?assertEqual(?XMPP_IQ_CLIENT_MODE, XmppIQ).


xmpp_to_proto_client_version_test() -> 
    ProtoIQ = iq_parser:xmpp_to_proto(?XMPP_IQ_CLIENT_VERSION),
    ?assertEqual(true, is_record(ProtoIQ, pb_ha_iq)),
    ?assertEqual(?PB_IQ_CLIENT_VERSION, ProtoIQ).


proto_to_xmpp_client_version_test() ->
    XmppIQ = iq_parser:proto_to_xmpp(?PB_IQ_CLIENT_VERSION),
    ?assertEqual(true, is_record(XmppIQ, iq)),
    ?assertEqual(?XMPP_IQ_CLIENT_VERSION, XmppIQ).

