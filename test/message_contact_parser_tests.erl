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

-define(HASH1_BASE64, <<"YWI=">>).
-define(HASH1, <<"ab">>).


-define(CONTACT1, 
    #contact{
        type = add, 
        raw = <<"650-275-2675">>, 
        normalized = <<"+1 650-275-2675">>,
        userid = <<"123">>, 
        avatarid = <<"12334TCA">>,
        name = <<"alice">>,
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
        name = <<>>,
        role = <<"none">>
    }
). 

-define(XMPP_MSG_CONTACT_LIST,
    #message{
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

-define(PB_MSG_CONTACT_LIST,
    #pb_msg{
        id = <<"s9cCU-10">>,
        type = set,
        to_uid = 1000000000045484920,
        from_uid = 0,   %% Default value, when sent by the server.
        payload = #pb_contact_list{
                type = full, 
                sync_id = <<"halloapp:user:contacts">>,
                batch_index = 0,
                is_last = true,
                contacts = [?PB_CONTACT1, ?PB_CONTACT2]
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
        name = <<"alice">>,
        role = friend
    }
).

-define(PB_CONTACT2, 
    #pb_contact{
        action = delete,
        raw = <<"650-275-2600">>,
        normalized = <<"+1 650-275-2600">>,
        uid = 456,
        avatar_id = <<"12LLL334TCA">>,
        name = <<>>,
        role = none
    }
).


-define(XMPP_MSG_CONTACT_HASH,
    #message{
        id = <<"s9cCU-10">>,
        type = set,
        sub_els = [#contact_list{
                contact_hash = [?HASH1_BASE64]
            }
        ]
    }
).

-define(PB_MSG_CONTACT_HASH,
    #pb_msg{
        id = <<"s9cCU-10">>,
        type = set,
        to_uid = 1000000000045484920,
        from_uid = 0,   %% Default value, when sent by the server.
        payload = #pb_contact_hash{
                hash = ?HASH1
            }
    }
).


%% -------------------------------------------- %%
%% internal tests
%% -------------------------------------------- %%

setup() ->
    stringprep:start(),
    ok.


xmpp_to_proto_contact_list_test() ->
    setup(),
    ToJid = jid:make(<<"1000000000045484920">>, <<"s.halloapp.net">>),
    FromJid = jid:make(<<"s.halloapp.net">>),
    XmppMsg = ?XMPP_MSG_CONTACT_LIST#message{to = ToJid, from = FromJid},

    ProtoMSG = message_parser:xmpp_to_proto(XmppMsg),
    ?assertEqual(true, is_record(ProtoMSG, pb_msg)),
    ?assertEqual(?PB_MSG_CONTACT_LIST, ProtoMSG).


xmpp_to_proto_contact_hash_test() ->
    setup(),
    ToJid = jid:make(<<"1000000000045484920">>, <<"s.halloapp.net">>),
    FromJid = jid:make(<<"s.halloapp.net">>),
    XmppMsg = ?XMPP_MSG_CONTACT_HASH#message{to = ToJid, from = FromJid},

    ProtoMSG = message_parser:xmpp_to_proto(XmppMsg),
    ?assertEqual(true, is_record(ProtoMSG, pb_msg)),
    ?assertEqual(?PB_MSG_CONTACT_HASH, ProtoMSG).

