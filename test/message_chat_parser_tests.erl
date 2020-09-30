%%%-------------------------------------------------------------------
%%% @author yexin
%%% @copyright (C) 2020, HalloApp, Inc.
%%% @doc
%%%
%%% @end
%%% Created : 21. Jul 2020 1:00 PM
%%%-------------------------------------------------------------------
-module(message_chat_parser_tests).
-author("yexin").

-include_lib("eunit/include/eunit.hrl").
-include("packets.hrl").
-include("xmpp.hrl").

%% -------------------------------------------- %%
%% define chat constants
%% -------------------------------------------- %%

-define(XMPP_MSG_CHAT1,
    #message{
        id = <<"s9cC3v4qf40">>,
        type = normal,
        sub_els = [#chat{
                xmlns = <<"halloapp:chat:messages">>,
                timestamp = <<"2000090910">>,
                sender_name = <<"Nikola">>,
                sub_els = [{xmlel,<<"s1">>,[],[{xmlcdata,<<"MTIz">>}]},
                        {xmlel,<<"enc">>,
                            [{<<"identity_key">>, <<"Nzg5">>},
                            {<<"one_time_pre_key_id">>,<<"12">>}],
                            [{xmlcdata,<<"NDU2">>}]}]
            }
        ]
    }
).

-define(PB_MSG_CHAT1,
    #pb_msg{
        id = <<"s9cC3v4qf40">>,
        type = normal,
        to_uid = 1000000000045484920,
        from_uid = 1000000000519345762,
        payload = #pb_chat_stanza{
                timestamp = 2000090910,
                sender_name = <<"Nikola">>,
                payload = <<"123">>,
                enc_payload = <<"456">>,
                public_key = <<"789">>,
                one_time_pre_key_id = 12
            }
    }
).


-define(XMPP_MSG_CHAT2,
    #message{
        id = <<"s9cC3v4qf40">>,
        type = normal,
        sub_els = [#chat{
                xmlns = <<"halloapp:chat:messages">>,
                timestamp = undefined,
                sender_name = <<"Murali">>,
                sub_els = [{xmlel,<<"s1">>,[],[{xmlcdata,<<"MTIz">>}]},
                        {xmlel,<<"enc">>,
                            [{<<"identity_key">>, <<"Nzg5">>},
                            {<<"one_time_pre_key_id">>,<<"12">>}],
                            [{xmlcdata,<<"NDU2">>}]}]
            }
        ]
    }
).

-define(PB_MSG_CHAT2,
    #pb_msg{
        id = <<"s9cC3v4qf40">>,
        type = normal,
        to_uid = 1000000000045484920,
        from_uid = 1000000000519345762,
        payload = #pb_chat_stanza{
                timestamp = undefined,
                sender_name = <<"Murali">>,
                payload = <<"123">>,
                enc_payload = <<"456">>,
                public_key = <<"789">>,
                one_time_pre_key_id = 12
            }
    }
).


-define(XMPP_MSG_CHAT3,
    #message{
        id = <<"s9cC3v4qf40">>,
        type = normal,
        sub_els = [#chat{
                xmlns = <<"halloapp:chat:messages">>,
                timestamp = undefined,
                sender_name = <<"Murali">>,
                sub_els = [{xmlel,<<"s1">>,[],[{xmlcdata,<<"MTIz">>}]},
                        {xmlel,<<"enc">>,
                            [],
                            [{xmlcdata,<<"NDU2">>}]}]
            }
        ]
    }
).

-define(PB_MSG_CHAT3,
    #pb_msg{
        id = <<"s9cC3v4qf40">>,
        type = normal,
        to_uid = 1000000000045484920,
        from_uid = 1000000000519345762,
        payload = #pb_chat_stanza{
                timestamp = undefined,
                sender_name = <<"Murali">>,
                payload = <<"123">>,
                enc_payload = <<"456">>,
                public_key = undefined,
                one_time_pre_key_id = undefined
            }
    }
).


%% -------------------------------------------- %%
%% internal tests
%% -------------------------------------------- %%

setup() ->
    stringprep:start(),
    ok.

xmpp_to_proto_chat_test() ->
    setup(),
    ToJid = jid:make(<<"1000000000045484920">>, <<"s.halloapp.net">>),
    FromJid = jid:make(<<"1000000000519345762">>, <<"s.halloapp.net">>),

    XmppMsg = ?XMPP_MSG_CHAT1#message{to = ToJid, from = FromJid},
    ActualProtoMsg = message_parser:xmpp_to_proto(XmppMsg),
    ?assertEqual(true, is_record(ActualProtoMsg, pb_msg)),
    ?assertEqual(?PB_MSG_CHAT1, ActualProtoMsg),

    XmppMsg3 = ?XMPP_MSG_CHAT3#message{to = ToJid, from = FromJid},
    ActualProtoMsg3 = message_parser:xmpp_to_proto(XmppMsg3),
    ?assertEqual(true, is_record(ActualProtoMsg3, pb_msg)),
    ?assertEqual(?PB_MSG_CHAT3, ActualProtoMsg3).


proto_to_xmpp_chat_test() ->
    setup(),
    ToJid = jid:make(<<"1000000000045484920">>, <<"s.halloapp.net">>),
    FromJid = jid:make(<<"1000000000519345762">>, <<"s.halloapp.net">>),

    ExpectedXmppMsg = ?XMPP_MSG_CHAT2#message{to = ToJid, from = FromJid},
    ActualXmppMsg = message_parser:proto_to_xmpp(?PB_MSG_CHAT2),
    ?assertEqual(true, is_record(ActualXmppMsg, message)),
    ?assertEqual(ExpectedXmppMsg, ActualXmppMsg),

    ExpectedXmppMsg3 = ?XMPP_MSG_CHAT3#message{to = ToJid, from = FromJid},
    ActualXmppMsg3 = message_parser:proto_to_xmpp(?PB_MSG_CHAT3),
    ?assertEqual(true, is_record(ActualXmppMsg3, message)),
    ?assertEqual(ExpectedXmppMsg3, ActualXmppMsg3).

