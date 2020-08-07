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
        to = ?TOJID,
        from = ?FROMJID,
        sub_els = [?XMPP_AVATAR]
    }
).

-define(PB_MSG_AVATAR,
    #pb_ha_message{
        id = <<"s9cCU-10">>,
        type = set,
        to_uid = 1000000000045484920,
        from_uid = 1000000000519345762,
        payload = #pb_msg_payload{
            content = {avatar, ?PB_AVATAR}
        }
    }
).


%% -------------------------------------------- %%
%% internal tests
%% -------------------------------------------- %%


xmpp_to_proto_avatar_test() -> 
    ProtoMSG = message_parser:xmpp_to_proto(?XMPP_MSG_AVATAR),
    ?assertEqual(true, is_record(ProtoMSG, pb_ha_message)),
    ?assertEqual(?PB_MSG_AVATAR, ProtoMSG).
    
    
proto_to_xmpp_avatar_test() ->
    XmppMSG = message_parser:proto_to_xmpp(?PB_MSG_AVATAR),
    ?assertEqual(true, is_record(XmppMSG, message)),
    ?assertEqual(?XMPP_MSG_AVATAR, XmppMSG).

