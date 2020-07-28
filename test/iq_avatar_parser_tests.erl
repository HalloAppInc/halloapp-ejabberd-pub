%%%-------------------------------------------------------------------
%%% @author yexin
%%% @copyright (C) 2020, HalloApp, Inc.
%%% @doc
%%%
%%% @end
%%% Created : 17. Jul 2020 3:00 PM
%%%-------------------------------------------------------------------
-module(iq_avatar_parser_tests).
-author("yexin").

-include_lib("eunit/include/eunit.hrl").
-include("packets.hrl").
-include("xmpp.hrl").

%% -------------------------------------------- %%
%% define avatar and avatars constants
%% -------------------------------------------- %%

-define(XMPP_UPLOAD_AVATAR1,
    #avatar{
        id = <<"ppadfa">>,
        cdata = <<"YTgwaGZhZGtsLW0=">> 
    }
).

-define(PB_UPLOAD_AVATAR1,
    #pb_upload_avatar{
        id = <<"ppadfa">>,
        data = <<"a80hfadkl-m">>
    }
).

-define(XMPP_AVATAR1,
    #avatar{
        id = <<"ppadfa">>,
        userid = <<"397103">>
    }
).

-define(PB_AVATAR1,
    #pb_avatar{
        id = <<"ppadfa">>,
        uid = 397103
    }
).

-define(XMPP_IQ_AVATAR1,
    #iq{
        id = <<"s9cCU-10">>,
        type = set,
        sub_els = [?XMPP_UPLOAD_AVATAR1]
    }
).

-define(PB_IQ_AVATAR1,
    #pb_ha_iq{
        id = <<"s9cCU-10">>,
        type = set,
        payload = #pb_iq_payload{
            content = {avatar, ?PB_UPLOAD_AVATAR1}
        }
    }
).

-define(XMPP_AVATAR2,
    #avatar{
        id = <<"001">>,
        userid = <<"1000">>
    }
).

-define(PB_AVATAR2,
    #pb_avatar{
        id = <<"001">>,
        uid = 1000
    }
).

-define(XMPP_IQ_AVATAR2,
    #iq{
        id = <<"s9cCU-10-000">>,
        type = result,
        sub_els = [?XMPP_AVATAR2]
    }
).

-define(PB_IQ_AVATAR2,
    #pb_ha_iq{
        id = <<"s9cCU-10-000">>,
        type = result,
        payload = #pb_iq_payload{
            content = {avatar, ?PB_AVATAR2}
        }
    }
).

-define(XMPP_IQ_AVATARS,
    #iq{
        id = <<"fadsa">>,
        type = result,
        sub_els = [#avatars{
                avatars = [?XMPP_AVATAR1, ?XMPP_AVATAR2]
            }
        ]
    }
).

-define(PB_IQ_AVATARS,
    #pb_ha_iq{
        id = <<"fadsa">>,
        type = result,
        payload = #pb_iq_payload{
            content = {avatars, #pb_avatars{
                avatars = [?PB_AVATAR1, ?PB_AVATAR2]
            }}
        }
    }
).


%% -------------------------------------------- %%
%% internal tests
%% -------------------------------------------- %%


xmpp_to_proto_avatar_test() ->
    ProtoIQ2 = iq_parser:xmpp_to_proto(?XMPP_IQ_AVATAR2),
    ?assertEqual(true, is_record(ProtoIQ2, pb_ha_iq)),
    ?assertEqual(?PB_IQ_AVATAR2, ProtoIQ2).


proto_to_xmpp_avatar_test() ->
    XmppIQ1 = iq_parser:proto_to_xmpp(?PB_IQ_AVATAR1),
    ?assertEqual(true, is_record(XmppIQ1, iq)),
    ?assertEqual(?XMPP_IQ_AVATAR1, XmppIQ1),
    XmppIQ2 = iq_parser:proto_to_xmpp(?PB_IQ_AVATAR2),
    ?assertEqual(true, is_record(XmppIQ2, iq)),
    ?assertEqual(?XMPP_IQ_AVATAR2, XmppIQ2).


xmpp_to_proto_avatars_test() -> 
    ProtoIQ = iq_parser:xmpp_to_proto(?XMPP_IQ_AVATARS),
    ?assertEqual(true, is_record(ProtoIQ, pb_ha_iq)),
    ?assertEqual(?PB_IQ_AVATARS, ProtoIQ).


proto_to_xmpp_avatars_test() ->
    XmppIQ = iq_parser:proto_to_xmpp(?PB_IQ_AVATARS),
    ?assertEqual(true, is_record(XmppIQ, iq)),
    ?assertEqual(?XMPP_IQ_AVATARS, XmppIQ).

