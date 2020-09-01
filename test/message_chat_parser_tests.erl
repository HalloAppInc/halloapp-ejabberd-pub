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

-define(XMPP_MSG_CHAT,
    #message{
        id = <<"s9cC3v4qf40">>,
        type = normal,
        sub_els = [#chat{
                xmlns = <<"halloapp:chat:messages">>,
                timestamp = <<"2000090910">>, 
                sub_els = [{xmlel,<<"s1">>,[],[{xmlcdata,<<"Hello from pb chat!">>}]},
                        {xmlel,<<"enc">>,[],[{xmlcdata,<<"Check encrypted content!">>}]}]
            }
        ]
    }
).

-define(PB_MSG_CHAT,
    #pb_ha_message{
        id = <<"s9cC3v4qf40">>,
        type = normal,
        to_uid = 1000000000045484920,
        from_uid = 1000000000519345762,
        payload = #pb_msg_payload{
            content = {chat, #pb_chat{
                timestamp = 2000090910,
                payload = <<"Hello from pb chat!">>,
                enc_payload = <<"Check encrypted content!">>
            }}
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
    XmppMsg = ?XMPP_MSG_CHAT#message{to = ToJid, from = FromJid},

    ActualProtoMsg = message_parser:xmpp_to_proto(XmppMsg),
    ?assertEqual(true, is_record(ActualProtoMsg, pb_ha_message)),
    ?assertEqual(?PB_MSG_CHAT, ActualProtoMsg).


proto_to_xmpp_chat_test() ->
    setup(),
    ToJid = jid:make(<<"1000000000045484920">>, <<"s.halloapp.net">>),
    FromJid = jid:make(<<"1000000000519345762">>, <<"s.halloapp.net">>),
    ExpectedXmppMsg = ?XMPP_MSG_CHAT#message{to = ToJid, from = FromJid},

    ActualXmppMsg = message_parser:proto_to_xmpp(?PB_MSG_CHAT),
    ?assertEqual(true, is_record(ActualXmppMsg, message)),
    ?assertEqual(ExpectedXmppMsg, ActualXmppMsg).

