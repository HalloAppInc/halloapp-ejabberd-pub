%%%-------------------------------------------------------------------
%%% @author yexin
%%% @copyright (C) 2020, HalloApp, Inc.
%%% @doc
%%%
%%% @end
%%% Created : 20. Jul 2020 10:40 AM
%%%-------------------------------------------------------------------
-module(message_avatar_parser_tests).
-author("yexin").

-include_lib("eunit/include/eunit.hrl").
-include("packets.hrl").
-include("xmpp.hrl").

%% -------------------------------------------- %%
%% define avatar and avatars constants
%% -------------------------------------------- %%


-define(XMPP_AVATAR,
    #avatar{
        id = <<"ppadfa">>,
        userid = <<"30084">>
    }
).

-define(PB_AVATAR,
    #pb_avatar{
        id = <<"ppadfa">>,
        uid = 30084
    }
).

-define(XMPP_MSG_AVATAR,
    #message{
        id = <<"s9cCU-10">>,
        type = set,
        sub_els = [?XMPP_AVATAR]
    }
).

-define(PB_MSG_AVATAR,
    #pb_ha_message{
        id = <<"s9cCU-10">>,
        type = set,
        to_uid = 1000000000045484920,
        from_uid = 1000000000519345762,
        payload = {avatar, ?PB_AVATAR}
    }
).


%% -------------------------------------------- %%
%% internal tests
%% -------------------------------------------- %%

setup() ->
    stringprep:start(),
    ok.

xmpp_to_proto_avatar_test() ->
    setup(),
    ToJid = jid:make(<<"1000000000045484920">>, <<"s.halloapp.net">>),
    FromJid = jid:make(<<"1000000000519345762">>, <<"s.halloapp.net">>),
    XmppMsg = ?XMPP_MSG_AVATAR#message{to = ToJid, from = FromJid},

    ActualProtoMsg = message_parser:xmpp_to_proto(XmppMsg),
    ?assertEqual(true, is_record(ActualProtoMsg, pb_ha_message)),
    ?assertEqual(?PB_MSG_AVATAR, ActualProtoMsg).
    
    
proto_to_xmpp_avatar_test() ->
    setup(),
    ToJid = jid:make(<<"1000000000045484920">>, <<"s.halloapp.net">>),
    FromJid = jid:make(<<"1000000000519345762">>, <<"s.halloapp.net">>),
    ExpectedXmppMsg = ?XMPP_MSG_AVATAR#message{to = ToJid, from = FromJid},

    ActualXmppMsg = message_parser:proto_to_xmpp(?PB_MSG_AVATAR),
    ?assertEqual(true, is_record(ActualXmppMsg, message)),
    ?assertEqual(ExpectedXmppMsg, ActualXmppMsg).

