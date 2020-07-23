%%%-------------------------------------------------------------------
%%% @author yexin
%%% @copyright (C) 2020, HalloApp, Inc.
%%% @doc
%%%
%%% @end
%%% Created : 17. Jul 2020 3:10 PM
%%%-------------------------------------------------------------------
-module(message_contact_parser_tests).
-author("yexin").

-include_lib("eunit/include/eunit.hrl").
-include("packets.hrl").
-include("xmpp.hrl").

%% -------------------------------------------- %%
%% define contact list constants
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

-define(CONTACT1, 
    #contact{
        type = add, 
        raw = <<"650-275-2675">>, 
        normalized = <<"+1 650-275-2675">>,
        userid = <<"123">>, 
        avatarid = <<"12334TCA">>,
        role = <<"friend">>
    }
). 

-define(CONTACT2, 
    #contact{
        type = delete, 
        raw = <<"650-275-2600">>, 
        normalized = <<"+1 650-275-2600">>,
        userid = <<"456">>, 
        avatarid = <<"12LLL334TCA">>,
        role = <<"none">> 
    }
). 

-define(XMPP_MSG_CONTACT_LIST,
    #message{
        id = <<"s9cCU-10">>,
        type = set,
        to = ?TOJID,
        from = ?FROMJID,
        sub_els = [#contact_list{
                type = full,
                syncid = <<"halloapp:user:contacts">>,
                index = 0, 
                last = true, 
                contacts = [?CONTACT1, ?CONTACT2]
            }
        ]
    }
).

-define(PB_MSG_CONTACT_LIST,
    #pb_ha_message{
        id = <<"s9cCU-10">>,
        type = set,
        to_uid = <<"1000000000045484920">>,
        from_uid = <<"1000000000519345762">>,
        payload = #pb_msg_payload{
            content = {cl, #pb_contact_list{
                type = full, 
                syncid = <<"halloapp:user:contacts">>,
                index = 0,
                is_last = true,
                contacts = [?PB_CONTACT1, ?PB_CONTACT2]
            }}
        }
    }
).

-define(PB_CONTACT1, 
    #pb_contact{
        action = add,
        raw = <<"650-275-2675">>,
        normalized = <<"+1 650-275-2675">>,
        uid = 123,
        avatarid = <<"12334TCA">>,
        role = friend
    }
).

-define(PB_CONTACT2, 
    #pb_contact{
        action = delete,
        raw = <<"650-275-2600">>,
        normalized = <<"+1 650-275-2600">>,
        uid = 456,
        avatarid = <<"12LLL334TCA">>,
        role = none
    }
).


%% -------------------------------------------- %%
%% internal tests
%% -------------------------------------------- %%


xmpp_to_proto_contact_list_test() -> 
    ProtoMSG = message_parser:xmpp_to_proto(?XMPP_MSG_CONTACT_LIST),
    ?assertEqual(true, is_record(ProtoMSG, pb_ha_message)),
    ?assertEqual(?PB_MSG_CONTACT_LIST, ProtoMSG). 


proto_to_xmpp_contact_list_test() ->
    XmppMSG = message_parser:proto_to_xmpp(?PB_MSG_CONTACT_LIST),
    ?assertEqual(true, is_record(XmppMSG, message)),
    ?assertEqual(?XMPP_MSG_CONTACT_LIST, XmppMSG). 

