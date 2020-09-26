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
        payload = #pb_chat{
                timestamp = 2000090910,
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
        payload = #pb_chat{
                timestamp = undefined,
                payload = <<"123">>,
                enc_payload = <<"456">>,
                public_key = <<"789">>,
                one_time_pre_key_id = 12
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
    ?assertEqual(?PB_MSG_CHAT1, ActualProtoMsg).


proto_to_xmpp_chat_test() ->
    setup(),
    ToJid = jid:make(<<"1000000000045484920">>, <<"s.halloapp.net">>),
    FromJid = jid:make(<<"1000000000519345762">>, <<"s.halloapp.net">>),
    ExpectedXmppMsg = ?XMPP_MSG_CHAT2#message{to = ToJid, from = FromJid},

    ActualXmppMsg = message_parser:proto_to_xmpp(?PB_MSG_CHAT2),
    ?assertEqual(true, is_record(ActualXmppMsg, message)),
    ?assertEqual(ExpectedXmppMsg, ActualXmppMsg).

