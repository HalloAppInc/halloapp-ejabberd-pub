%%%-------------------------------------------------------------------
%%% @author yexin
%%% @copyright (C) 2020, HalloApp, Inc.
%%% @doc
%%%
%%% @end
%%% Created : 17. Jul 2020 3:10 PM
%%%-------------------------------------------------------------------
-module(iq_contact_parser_tests).
-author("yexin").

-include_lib("eunit/include/eunit.hrl").
-include("packets.hrl").
-include("xmpp.hrl").

%% -------------------------------------------- %%
%% define contact list constants
%% -------------------------------------------- %%

-define(CONTACT1, 
    #contact{
        type = add, 
        raw = <<"650-275-2675">>, 
        normalized = <<"+1 650-275-2675">>,
        userid = <<"123">>, 
        avatarid = <<"12334TCA">>,
        role = <<"friend">>,
        name = <<"alice">>
    }
). 

-define(CONTACT2, 
    #contact{
        type = delete, 
        raw = <<"650-275-2600">>, 
        normalized = <<"+1 650-275-2600">>,
        userid = <<"456">>, 
        avatarid = <<"12LLL334TCA">>,
        role = <<"none">>,
        name = <<"bob">>
    }
). 

-define(XMPP_IQ_CONTACT_LIST,
    #iq{
        id = <<"s9cCU-10">>,
        type = set,
        sub_els = [#contact_list{
                type = full,
                syncid = <<"halloapp:user:contacts">>,
                index = 0, 
                last = true, 
                contacts = [?CONTACT1, ?CONTACT2],
                contact_hash = []
            }
        ]
    }
).

-define(PB_IQ_CONTACT_LIST,
    #pb_ha_iq{
        id = <<"s9cCU-10">>,
        type = set,
        payload = #pb_iq_payload{
            content = {contact_list, #pb_contact_list{
                type = full, 
                sync_id = <<"halloapp:user:contacts">>,
                batch_index = 0,
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
        avatar_id = <<"12334TCA">>,
        role = friend,
        name = <<"alice">>
    }
).

-define(PB_CONTACT2, 
    #pb_contact{
        action = delete,
        raw = <<"650-275-2600">>,
        normalized = <<"+1 650-275-2600">>,
        uid = 456,
        avatar_id = <<"12LLL334TCA">>,
        role = none,
        name = <<"bob">>
    }
).


%% -------------------------------------------- %%
%% internal tests
%% -------------------------------------------- %%


xmpp_to_proto_contact_list_test() -> 
    ProtoIQ = iq_parser:xmpp_to_proto(?XMPP_IQ_CONTACT_LIST),
    ?assertEqual(true, is_record(ProtoIQ, pb_ha_iq)),
    ?assertEqual(?PB_IQ_CONTACT_LIST, ProtoIQ). 


proto_to_xmpp_contact_list_test() ->
    XmppIQ = iq_parser:proto_to_xmpp(?PB_IQ_CONTACT_LIST),
    ?assertEqual(true, is_record(XmppIQ, iq)),
    ?assertEqual(?XMPP_IQ_CONTACT_LIST, XmppIQ). 

