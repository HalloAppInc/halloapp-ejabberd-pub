%%%-------------------------------------------------------------------
%%% @author yexin
%%% @copyright (C) 2020, HalloApp, Inc.
%%% @doc
%%%
%%% @end
%%% Created : 13. Jul 2020 12:28 PM
%%%-------------------------------------------------------------------
-module(ack_parser_tests).
-author("yexin").

-include_lib("eunit/include/eunit.hrl").
-include("packets.hrl").
-include("xmpp.hrl").

-define(JID1, #jid{
    user = <<"1000000000045484920">>,
    server = <<"s.halloapp.net">>,
    resource = <<"iphone">>
}).
-define(XMPP_ACK1,
    #ack{
        id = <<"TgJNGKUsEeqhxg5_sD_LJQ">>,
        from = ?JID1,
        to = ?JID1, 
        timestamp = <<"'1591056019'">>
    }
).
-define(PROTO_ACK1, 
    #pb_ha_ack{
        id = <<"TgJNGKUsEeqhxg5_sD_LJQ">>,
        timestamp = <<"'1591056019'">>
    }
).
-define(JID2,
    #jid{
        user = <<"1000000000519345762">>,
        server = <<"s.halloapp.net">>,
        resource = <<"iphone">>
    }
).
-define(XMPP_ACK2,
    #ack{
        id = <<"18C5554A-C220-42DB-A0A1-C3AD3AD2B28D">>,
        from = ?JID2,
        to = ?JID2, 
        timestamp = <<"1591141620">>
    }
).
-define(PROTO_ACK2, 
    #pb_ha_ack{
        id = <<"18C5554A-C220-42DB-A0A1-C3AD3AD2B28D">>,
        timestamp = <<"1591141620">>
    }
).


%% -------------------------------------------- %%
%% Tests
%% -------------------------------------------- %%


ack_xml_to_proto_test() -> 
    ProtoAck1 = ack_parser:xmpp_to_proto(?XMPP_ACK1),
    ?assertEqual(true, is_record(ProtoAck1, pb_ha_ack)),
    ?assertEqual(?PROTO_ACK1, ProtoAck1),
    
    ProtoAck2 = ack_parser:xmpp_to_proto(?XMPP_ACK2),
    ?assertEqual(true, is_record(ProtoAck2, pb_ha_ack)),
    ?assertEqual(?PROTO_ACK2, ProtoAck2).


ack_proto_to_xml_test() -> 
    XmppEl1 = ack_parser:proto_to_xmpp(?PROTO_ACK1),
    ?assertEqual(true, is_record(XmppEl1, ack)),
    ?assertEqual(XmppEl1#ack.id, ?XMPP_ACK1#ack.id),
    ?assertEqual(XmppEl1#ack.timestamp, ?XMPP_ACK1#ack.timestamp),
    
    XmppEl2 = ack_parser:proto_to_xmpp(?PROTO_ACK2),
    ?assertEqual(true, is_record(XmppEl2, ack)),
    ?assertEqual(XmppEl2#ack.id, ?XMPP_ACK2#ack.id),
    ?assertEqual(XmppEl2#ack.timestamp, ?XMPP_ACK2#ack.timestamp).

