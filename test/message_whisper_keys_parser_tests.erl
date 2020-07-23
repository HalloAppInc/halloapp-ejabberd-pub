%%%-------------------------------------------------------------------
%%% @author yexin
%%% @copyright (C) 2020, HalloApp, Inc.
%%% @doc
%%%
%%% @end
%%% Created : 20. Jul 2020 10:30 PM
%%%-------------------------------------------------------------------
-module(message_whisper_keys_parser_tests).
-author("yexin").

-include_lib("eunit/include/eunit.hrl").
-include("packets.hrl").
-include("xmpp.hrl").

%% -------------------------------------------- %%
%% define whisper_keys constants
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

-define(XMPP_MSG_WHISPER_KEYS,
    #message{
        id = <<"WHIPCD988id">>,
        type = set,
        to = ?TOJID,
        from = ?FROMJID,
        sub_els = [#whisper_keys{
            uid = <<"29863">>,
            type = add, 
            identity_key = <<"adf-fadsfa">>,
            signed_key = <<"2cd3c3">>,
            otp_key_count = <<"3264653331">>,
            one_time_keys = [<<"3dd">>, <<"31d">>, <<"39e">>]
        }]
    }
).

-define(PB_MSG_WHISPER_KEYS,
    #pb_ha_message{
        id = <<"WHIPCD988id">>,
        type = set,
        to_uid = <<"1000000000045484920">>,
        from_uid = <<"1000000000519345762">>,
        payload = #pb_msg_payload{
            content = {wk, #pb_whisper_keys{
                uid = 29863,
                action = add,   
                identity_key = <<"adf-fadsfa">>,
                signed_key = <<"2cd3c3">>,
                otp_key_count = 3264653331,
                one_time_keys = [<<"3dd">>, <<"31d">>, <<"39e">>]
            }}
        }
    }
).


%% -------------------------------------------- %%
%% internal tests
%% -------------------------------------------- %%


xmpp_to_proto_whisper_keys_test() -> 
    ProtoMSG = message_parser:xmpp_to_proto(?XMPP_MSG_WHISPER_KEYS),
    ?assertEqual(true, is_record(ProtoMSG, pb_ha_message)),
    ?assertEqual(?PB_MSG_WHISPER_KEYS, ProtoMSG).


proto_to_xmpp_whisper_keys_test() ->
    XmppMSG = message_parser:proto_to_xmpp(?PB_MSG_WHISPER_KEYS),
    ?assertEqual(true, is_record(XmppMSG, message)),
    ?assertEqual(?XMPP_MSG_WHISPER_KEYS, XmppMSG).

