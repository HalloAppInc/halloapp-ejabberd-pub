%%%-------------------------------------------------------------------
%%% @author yexin
%%% @copyright (C) 2020, HalloApp, Inc.
%%% @doc
%%%
%%% @end
%%% Created : 17. Jul 2020 3:15 PM
%%%-------------------------------------------------------------------
-module(iq_push_parser_tests).
-author("yexin").

-include_lib("eunit/include/eunit.hrl").
-include("packets.hrl").
-include("xmpp.hrl").

%% -------------------------------------------- %%
%% define push_register constants
%% -------------------------------------------- %%

-define(XMPP_IQ_PUSH_REGISTER,
    #iq{
        id = <<"cpuv9cnaid">>,
        type = set,
        sub_els = [#push_register{
                push_token = {<<"ios">>, <<"adfad">>}
            }
        ]
    }
).

-define(PB_IQ_PUSH_REGISTER,
    #pb_ha_iq{
        id = <<"cpuv9cnaid">>,
        type = set,
        payload = #pb_iq_payload{
            content = {push_register, #pb_push_register{
                push_token = #pb_push_token{
                    os = ios,
                    token = <<"adfad">>
                }
            }}
        }
    }
).


%% -------------------------------------------- %%
%% internal tests
%% -------------------------------------------- %%


xmpp_to_proto_push_register_test() -> 
    ProtoIQ = iq_parser:xmpp_to_proto(?XMPP_IQ_PUSH_REGISTER),
    ?assertEqual(true, is_record(ProtoIQ, pb_ha_iq)),
    ?assertEqual(?PB_IQ_PUSH_REGISTER, ProtoIQ).


proto_to_xmpp_push_register_test() ->
    XmppIQ = iq_parser:proto_to_xmpp(?PB_IQ_PUSH_REGISTER),
    ?assertEqual(true, is_record(XmppIQ, iq)),
    ?assertEqual(?XMPP_IQ_PUSH_REGISTER, XmppIQ).

