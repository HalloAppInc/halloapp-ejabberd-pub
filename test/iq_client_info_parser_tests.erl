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
        payload = {client_mode, #pb_client_mode{
                mode = active
            }}
    }
).

-define(XMPP_IQ_CLIENT_VERSION1,
    #iq{
        id = <<"clientVERSIONid">>,
        type = result,
        sub_els = [#client_version{
                version = <<"2.3">>,
                seconds_left = <<"23">>
            }
        ]
    }
).

-define(PB_IQ_CLIENT_VERSION1,
    #pb_ha_iq{
        id = <<"clientVERSIONid">>,
        type = result,
        payload = {client_version, #pb_client_version{
                version = <<"2.3">>,
                expires_in_seconds = 23
            }}
    }
).


-define(XMPP_IQ_CLIENT_VERSION2,
    #iq{
        id = <<"clientVERSIONid">>,
        type = get,
        sub_els = [#client_version{
                version = <<"2.3">>,
                seconds_left = undefined
            }
        ]
    }
).

-define(PB_IQ_CLIENT_VERSION2,
    #pb_ha_iq{
        id = <<"clientVERSIONid">>,
        type = get,
        payload = {client_version, #pb_client_version{
                version = <<"2.3">>,
                expires_in_seconds = undefined
            }}
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
    ProtoIQ = iq_parser:xmpp_to_proto(?XMPP_IQ_CLIENT_VERSION1),
    ?assertEqual(true, is_record(ProtoIQ, pb_ha_iq)),
    ?assertEqual(?PB_IQ_CLIENT_VERSION1, ProtoIQ).


proto_to_xmpp_client_version_test() ->
    XmppIQ = iq_parser:proto_to_xmpp(?PB_IQ_CLIENT_VERSION2),
    ?assertEqual(true, is_record(XmppIQ, iq)),
    ?assertEqual(?XMPP_IQ_CLIENT_VERSION2, XmppIQ).

