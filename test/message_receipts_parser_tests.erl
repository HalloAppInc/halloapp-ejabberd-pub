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

-define(XMPP_MSG_SEEN,
    #message{
        id = <<"s9cCU-10">>,
        type = normal,
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
        to_uid = 1000000000045484920,
        from_uid = 1000000000519345762,
        payload = {seen, #pb_seen_receipt{
                id = <<"7ab30vn">>,
                thread_id = <<"thlm23ca">>,
                timestamp = 20190910
            }}
    }
).

-define(XMPP_MSG_RECEIVED,
    #message{
        id = <<"s9cC3v4qf40">>,
        type = normal,
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
        to_uid = 1000000000045484920,
        from_uid = 1000000000519345762,
        payload = {delivery, #pb_delivery_receipt{
                id = <<"b30vn">>,
                thread_id = <<"thlm2ere3ca">>,
                timestamp = 2000090910
            }}
    }
).


%% -------------------------------------------- %%
%% internal tests
%% -------------------------------------------- %%

setup() ->
    stringprep:start(),
    ok.


xmpp_to_proto_seen_test() ->
    setup(),
    ToJid = jid:make(<<"1000000000045484920">>, <<"s.halloapp.net">>),
    FromJid = jid:make(<<"1000000000519345762">>, <<"s.halloapp.net">>),
    XmppMsg = ?XMPP_MSG_SEEN#message{to = ToJid, from = FromJid},

    ProtoMSG = message_parser:xmpp_to_proto(XmppMsg),
    ?assertEqual(true, is_record(ProtoMSG, pb_ha_message)),
    ?assertEqual(?PB_MSG_SEEN, ProtoMSG).


proto_to_xmpp_seen_test() ->
    setup(),
    ToJid = jid:make(<<"1000000000045484920">>, <<"s.halloapp.net">>),
    FromJid = jid:make(<<"1000000000519345762">>, <<"s.halloapp.net">>),
    ExpectedXmppMsg = ?XMPP_MSG_SEEN#message{to = ToJid, from = FromJid},

    ActualXmppMsg = message_parser:proto_to_xmpp(?PB_MSG_SEEN),
    ?assertEqual(true, is_record(ActualXmppMsg, message)),
    ?assertEqual(ExpectedXmppMsg, ActualXmppMsg).


xmpp_to_proto_response_test() ->
    setup(),
    ToJid = jid:make(<<"1000000000045484920">>, <<"s.halloapp.net">>),
    FromJid = jid:make(<<"1000000000519345762">>, <<"s.halloapp.net">>),
    XmppMsg = ?XMPP_MSG_RECEIVED#message{to = ToJid, from = FromJid},

    ProtoMSG = message_parser:xmpp_to_proto(XmppMsg),
    ?assertEqual(true, is_record(ProtoMSG, pb_ha_message)),
    ?assertEqual(?PB_MSG_RECEIVED, ProtoMSG).


proto_to_xmpp_response_test() ->
    setup(),
    ToJid = jid:make(<<"1000000000045484920">>, <<"s.halloapp.net">>),
    FromJid = jid:make(<<"1000000000519345762">>, <<"s.halloapp.net">>),
    ExpectedXmppMsg = ?XMPP_MSG_RECEIVED#message{to = ToJid, from = FromJid},

    ActualXmppMsg = message_parser:proto_to_xmpp(?PB_MSG_RECEIVED),
    ?assertEqual(true, is_record(ActualXmppMsg, message)),
    ?assertEqual(ExpectedXmppMsg, ActualXmppMsg).

