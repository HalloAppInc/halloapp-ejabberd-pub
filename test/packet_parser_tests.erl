%%%-------------------------------------------------------------------
%%% @author yexin
%%% @copyright (C) 2020, HalloApp, Inc.
%%% @doc
%%%
%%% @end
%%% Created : 22. Jul 2020 2:00 PM
%%%-------------------------------------------------------------------
-module(packet_parser_tests).
-author("yexin").

-include_lib("eunit/include/eunit.hrl").
-include("packets.hrl").
-include("xmpp.hrl").

%% -------------------------------------------- %%
%% define super packet constants
%% -------------------------------------------- %%

-define(XMPP_ACK,
    #ack{
        id = <<"TgJNGKUsEeqhxg5_sD_LJQ">>,
        timestamp = <<"'1591056019'">>
    }
).

-define(PB_ACK, 
    #pb_ha_ack{
        id = <<"TgJNGKUsEeqhxg5_sD_LJQ">>,
        timestamp = <<"'1591056019'">>
    }
).

-define(PB_PACKET_ACK,
    #pb_packet{
        stanza = {ack, ?PB_ACK}
    }
).

-define(XMPP_IQ,
    #iq{
        id = <<"3ece24923">>,
        type = set,
        sub_els = [#whisper_keys{
                uid = <<"863">>,
                type = add, 
                identity_key = <<"adf-fadsfa">>,
                signed_key = <<"2cd3c3">>,
                otp_key_count = <<"100">>,
                one_time_keys = [<<"3dd">>, <<"31d">>, <<"39e">>]
            }
        ]
    }
).

-define(PB_IQ,
    #pb_ha_iq{
        id = <<"3ece24923">>,
        type = set,
        payload = #pb_iq_payload{
            content = {whisper_keys, #pb_whisper_keys{
                uid = 863,
                action = add,   
                identity_key = <<"adf-fadsfa">>,
                signed_key = <<"2cd3c3">>,
                otp_key_count = 100,
                one_time_keys = [<<"3dd">>, <<"31d">>, <<"39e">>]
            }}
        }
    }
).

-define(PB_PACKET_IQ,
    #pb_packet{
        stanza = {iq, ?PB_IQ}
    }
).

-define(XMPP_PRESENCE,
    #presence{
        id = <<"TgJNGKUsEeqhxg5_sD_LJQ">>,
        type = available,
        from = #jid{
            user = <<"1000000000045484920">>,
            server = <<"s.halloapp.net">>
        },
        to = #jid{
            user = <<"1000000000519345762">>,
            server = <<"s.halloapp.net">>
        }
    }
).

-define(PB_PRESENCE, 
    #pb_ha_presence{
        id = <<"TgJNGKUsEeqhxg5_sD_LJQ">>,
        type = available, 
        uid = 1000000000045484920,
        last_seen = undefined
    }
).

-define(PB_PACKET_PRESENCE,
    #pb_packet{
        stanza = {presence, ?PB_PRESENCE}
    }
).

-define(XMPP_MSG,
    #message{
        id = <<"s9cCU-10">>,
        type = normal,
        to = #jid{
            user = <<"1000000000045484920">>,
            server = <<"s.halloapp.net">>
        },
        from = #jid{
            user = <<"1000000000519345762">>,
            server = <<"s.halloapp.net">>
        },
        sub_els = [#receipt_seen{
                id = <<"7ab30vn">>,
                thread_id = <<"thlm23ca">>,
                timestamp = <<"20190910">>
            }
        ]
    }
).

-define(PB_MSG,
    #pb_ha_message{
        id = <<"s9cCU-10">>,
        type = normal,
        to_uid = <<"1000000000045484920">>,
        from_uid = <<"1000000000519345762">>,
        payload = #pb_msg_payload{
            content = {seen, #pb_seen_receipt{
                id = <<"7ab30vn">>,
                thread_id = <<"thlm23ca">>,
                timestamp = 20190910
            }}
        }
    }
).

-define(PB_PACKET_MSG,
    #pb_packet{
        stanza = {msg, ?PB_MSG}
    }
).


%% -------------------------------------------- %%
%% internal tests
%% -------------------------------------------- %%


xmpp_to_proto_packet_ack_test() -> 
    ProtoAck = packet_parser:xmpp_to_proto(?XMPP_ACK),
    ?assertEqual(true, is_record(ProtoAck, pb_packet)),
    ?assertEqual(?PB_PACKET_ACK, ProtoAck).


proto_to_xmpp_packet_ack_test() -> 
    XmppAck = packet_parser:proto_to_xmpp(?PB_PACKET_ACK),
    ?assertEqual(true, is_record(XmppAck, ack)),
    ?assertEqual(?XMPP_ACK, XmppAck).


xmpp_to_proto_packet_iq_test() -> 
    ProtoIQ = packet_parser:xmpp_to_proto(?XMPP_IQ),
    ?assertEqual(true, is_record(ProtoIQ, pb_packet)),
    ?assertEqual(?PB_PACKET_IQ, ProtoIQ).


proto_to_xmpp_packet_iq_test() -> 
    XmppIQ = packet_parser:proto_to_xmpp(?PB_PACKET_IQ),
    ?assertEqual(true, is_record(XmppIQ, iq)),
    ?assertEqual(?XMPP_IQ, XmppIQ).


xmpp_to_proto_packet_presence_test() -> 
    ProtoPresence = packet_parser:xmpp_to_proto(?XMPP_PRESENCE),
    ?assertEqual(true, is_record(ProtoPresence, pb_packet)),
    ?assertEqual(?PB_PACKET_PRESENCE, ProtoPresence).


proto_to_xmpp_packet_presence_test() -> 
    XmppPresence = packet_parser:proto_to_xmpp(?PB_PACKET_PRESENCE),
    ?assertEqual(true, is_record(XmppPresence, presence)),
    ?assertEqual(XmppPresence#presence.id, ?XMPP_PRESENCE#presence.id),
    ?assertEqual(XmppPresence#presence.type, ?XMPP_PRESENCE#presence.type).


xmpp_to_proto_packet_msg_test() -> 
    ProtoMsg = packet_parser:xmpp_to_proto(?XMPP_MSG),
    ?assertEqual(true, is_record(ProtoMsg, pb_packet)),
    ?assertEqual(?PB_PACKET_MSG, ProtoMsg).


proto_to_xmpp_packet_msg_test() -> 
    XmppMsg = packet_parser:proto_to_xmpp(?PB_PACKET_MSG),
    ?assertEqual(true, is_record(XmppMsg, message)),
    ?assertEqual(?XMPP_MSG, XmppMsg).

