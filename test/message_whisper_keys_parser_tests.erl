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


-define(XMPP_MSG_WHISPER_KEYS,
    #message{
        id = <<"WHIPCD988id">>,
        type = set,
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
        to_uid = 1000000000045484920,
        from_uid = 0,   %% Default value, when sent by the server.
        payload = #pb_msg_payload{
            content = {whisper_keys, #pb_whisper_keys{
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

setup() ->
    stringprep:start(),
    ok.


xmpp_to_proto_whisper_keys_test() ->
    setup(),
    ToJid = jid:make(<<"1000000000045484920">>, <<"s.halloapp.net">>),
    FromJid = jid:make(<<"s.halloapp.net">>),
    XmppMsg = ?XMPP_MSG_WHISPER_KEYS#message{to = ToJid, from = FromJid},

    ProtoMsg = message_parser:xmpp_to_proto(XmppMsg),
    ?assertEqual(true, is_record(ProtoMsg, pb_ha_message)),
    ?assertEqual(?PB_MSG_WHISPER_KEYS, ProtoMsg).

