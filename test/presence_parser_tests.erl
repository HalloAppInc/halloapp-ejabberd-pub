%%%-------------------------------------------------------------------
%%% @author yexin
%%% @copyright (C) 2020, HalloApp, Inc.
%%% @doc
%%%
%%% @end
%%% Created : 14. Jul 2020 1:00 PM
%%%-------------------------------------------------------------------
-module(presence_parser_tests).
-author("yexin").

-include_lib("eunit/include/eunit.hrl").
-include("packets.hrl").
-include("xmpp.hrl").


-define(JID1,
    #jid{
        user = <<"1000000000045484920">>,
        server = <<"s.halloapp.net">>,
        resource = <<"iphone">>
    }
).

-define(JID2,
    #jid{
        user = <<"1000000000519345762">>,
        server = <<"s.halloapp.net">>,
        resource = <<"iphone">>
    }
).

-define(XMPP_PRESENCE1,
    #presence{
        id = <<"TgJNGKUsEeqhxg5_sD_LJQ">>,
        type = available,
        lang = <<"en">>,
        from = ?JID1,
        to = ?JID2
    }
).

-define(XMPP_PRESENCE2,
    #presence{
        id = <<"ID2">>,
        type = subscribe,
        lang = <<"en">>,
        from = ?JID1,
        to = ?JID2
    }
).

-define(XMPP_PRESENCE3,
    #presence{
        id = <<"ID3">>,
        type = unsubscribe,
        lang = <<"en">>,
        from = ?JID1,
        to = ?JID2,
        last_seen = <<"1585013887">>
    }
).

-define(PROTO_ELEMENT1, 
    #pb_presence{
        id = <<"TgJNGKUsEeqhxg5_sD_LJQ">>,
        type = available, 
        uid = 1000000000045484920,
        last_seen = undefined
    }
).

-define(PROTO_ELEMENT2, 
    #pb_presence{
        id = <<"ID2">>,
        type = subscribe,
        uid = 1000000000519345762,
        last_seen = undefined
    }
).

-define(PROTO_ELEMENT3, 
    #pb_presence{
        id = <<"ID3">>,
        type = unsubscribe,
        last_seen = 1585013887,
        uid = 1000000000519345762
    }
).


%% -------------------------------------------- %%
%% Tests
%% -------------------------------------------- %%


presence_xml_to_proto_test() -> 
    ProtoPres1 = presence_parser:xmpp_to_proto(?XMPP_PRESENCE1),
    ?assertEqual(true, is_record(ProtoPres1, pb_presence)),
    ?assertEqual(?PROTO_ELEMENT1#pb_presence.id, ProtoPres1#pb_presence.id),
    ?assertEqual(?PROTO_ELEMENT1#pb_presence.type, ProtoPres1#pb_presence.type),
    ?assertEqual(?PROTO_ELEMENT1#pb_presence.uid, ProtoPres1#pb_presence.uid),
    
    ProtoPres2 = presence_parser:xmpp_to_proto(?XMPP_PRESENCE2),
    ?assertEqual(true, is_record(ProtoPres2, pb_presence)),
    ?assertEqual(?PROTO_ELEMENT2#pb_presence.id, ProtoPres2#pb_presence.id),
    ?assertEqual(?PROTO_ELEMENT2#pb_presence.type, ProtoPres2#pb_presence.type),
    
    ProtoPres3 = presence_parser:xmpp_to_proto(?XMPP_PRESENCE3),
    ?assertEqual(true, is_record(ProtoPres3, pb_presence)),
    ?assertEqual(?PROTO_ELEMENT3#pb_presence.id, ProtoPres3#pb_presence.id),
    ?assertEqual(?PROTO_ELEMENT3#pb_presence.type, ProtoPres3#pb_presence.type).
    

proto_to_xml_id_and_type_test() -> 
    XmppEl1 = presence_parser:proto_to_xmpp(?PROTO_ELEMENT1),
    ?assertEqual(true, is_record(XmppEl1, presence)),
    ?assertEqual(XmppEl1#presence.id, ?XMPP_PRESENCE1#presence.id),
    ?assertEqual(XmppEl1#presence.type, ?XMPP_PRESENCE1#presence.type),
    
    XmppEl2 = presence_parser:proto_to_xmpp(?PROTO_ELEMENT2),
    ?assertEqual(true, is_record(XmppEl2, presence)),
    ?assertEqual(XmppEl2#presence.id, ?XMPP_PRESENCE2#presence.id),
    ?assertEqual(XmppEl2#presence.type, ?XMPP_PRESENCE2#presence.type),
    
    XmppEl3 = presence_parser:proto_to_xmpp(?PROTO_ELEMENT3),
    ?assertEqual(true, is_record(XmppEl3, presence)),
    ?assertEqual(XmppEl3#presence.id, ?XMPP_PRESENCE3#presence.id),
    ?assertEqual(XmppEl3#presence.type, ?XMPP_PRESENCE3#presence.type).


proto_to_xml_subscribe_test() ->
    XmppEl2 = presence_parser:proto_to_xmpp(?PROTO_ELEMENT2),
    ?assertEqual(true, is_record(XmppEl2, presence)),
    XmppEl2ToJID = XmppEl2#presence.to,
    XMPP_PRESENCE2JID = ?XMPP_PRESENCE2#presence.to,
    ?assertEqual(XmppEl2ToJID#jid.user, XMPP_PRESENCE2JID#jid.user),
    
    XmppEl3 = presence_parser:proto_to_xmpp(?PROTO_ELEMENT3),
    ?assertEqual(true, is_record(XmppEl3, presence)),
    XmppEl3ToJID = XmppEl3#presence.to,
    XMPP_PRESENCE3JID = ?XMPP_PRESENCE3#presence.to,
    ?assertEqual(XmppEl3ToJID#jid.user, XMPP_PRESENCE3JID#jid.user).

