%%%-------------------------------------------------------------------
%%% @author yexin
%%% @copyright (C) 2020, HalloApp, Inc.
%%% @doc
%%%
%%% @end
%%% Created : 20. Jul 2020 11:00 AM
%%%-------------------------------------------------------------------
-module(message_receipts_parser_tests).
-author("yexin").

-include_lib("eunit/include/eunit.hrl").
-include("packets.hrl").
-include("xmpp.hrl").

%% -------------------------------------------- %%
%% define seen and received constants
%% -------------------------------------------- %%

-define(TOJID,
    #jid{
        user = <<"1000000000045484920">>,
        server = <<"s.halloapp.net">>
    }
).

-define(FROMJID,
    #jid{
        user = <<"1000000000519345762">>,
        server = <<"s.halloapp.net">>
    }
).

-define(XMPP_MSG_SEEN,
    #message{
        id = <<"s9cCU-10">>,
        type = normal,
        to = ?TOJID,
        from = ?FROMJID,
        sub_els = [#receipt_seen{
                id = <<"7ab30vn">>,
                thread_id = <<"thlm23ca">>,
                timestamp = <<"20190910">>
            }
        ]
    }
).

-define(PB_MSG_SEEN,
    #pb_ha_message{
        id = <<"s9cCU-10">>,
        type = normal,
        to_uid = <<"1000000000045484920">>,
        from_uid = <<"1000000000519345762">>,
        payload = #pb_msg_payload{
            content = {s, #pb_seen{
                id = <<"7ab30vn">>,
                thread_id = <<"thlm23ca">>,
                timestamp = 20190910
            }}
        }
    }
).

-define(XMPP_MSG_RECEIVED,
    #message{
        id = <<"s9cC3v4qf40">>,
        type = normal,
        to = ?TOJID,
        from = ?FROMJID,
        sub_els = [#receipt_response{
                id = <<"b30vn">>,
                thread_id = <<"thlm2ere3ca">>,
                timestamp = <<"2000090910">>
            }
        ]
    }
).

-define(PB_MSG_RECEIVED,
    #pb_ha_message{
        id = <<"s9cC3v4qf40">>,
        type = normal,
        to_uid = <<"1000000000045484920">>,
        from_uid = <<"1000000000519345762">>,
        payload = #pb_msg_payload{
            content = {r, #pb_received{
                id = <<"b30vn">>,
                thread_id = <<"thlm2ere3ca">>,
                timestamp = 2000090910
            }}
        }
    }
).


%% -------------------------------------------- %%
%% internal tests
%% -------------------------------------------- %%


xmpp_to_proto_seen_test() -> 
    ProtoMSG = message_parser:xmpp_to_proto(?XMPP_MSG_SEEN),    
    ?assertEqual(true, is_record(ProtoMSG, pb_ha_message)),
    ?assertEqual(?PB_MSG_SEEN, ProtoMSG).


proto_to_xmpp_seen_test() ->
    XmppMSG = message_parser:proto_to_xmpp(?PB_MSG_SEEN),
    ?assertEqual(true, is_record(XmppMSG, message)),
    ?assertEqual(?XMPP_MSG_SEEN, XmppMSG).


xmpp_to_proto_response_test() -> 
    ProtoMSG = message_parser:xmpp_to_proto(?XMPP_MSG_RECEIVED),    
    ?assertEqual(true, is_record(ProtoMSG, pb_ha_message)),
    ?assertEqual(?PB_MSG_RECEIVED, ProtoMSG).


proto_to_xmpp_response_test() ->
    XmppMSG = message_parser:proto_to_xmpp(?PB_MSG_RECEIVED),
    ?assertEqual(true, is_record(XmppMSG, message)),
    ?assertEqual(?XMPP_MSG_RECEIVED, XmppMSG).

