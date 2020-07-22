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

%% -------------------------------------------- %%
%% define ping constants
%% -------------------------------------------- %%

-define(XMPP_IQ_PING,
    #iq{
        id = <<"WHIPCD988id">>,
        type = set,
        sub_els = [#ping{}]
    }
).

-define(PB_IQ_PING,
    #pb_ha_iq{
        id = <<"WHIPCD988id">>,
        type = set,
        payload = #pb_iq_payload{
            content = {p, #pb_ping{}}
        }
    }
).


%% -------------------------------------------- %%
%% internal tests
%% -------------------------------------------- %%


xmpp_to_proto_ping_test() -> 
    ProtoIQ = iq_parser:xmpp_to_proto(?XMPP_IQ_PING),
    ?assertEqual(true, is_record(ProtoIQ, pb_ha_iq)),
    ?assertEqual(?PB_IQ_PING, ProtoIQ).


proto_to_xmpp_ping_test() ->
    XmppIQ = iq_parser:proto_to_xmpp(?PB_IQ_PING),
    ?assertEqual(true, is_record(XmppIQ, iq)),
    ?assertEqual(?XMPP_IQ_PING, XmppIQ).

