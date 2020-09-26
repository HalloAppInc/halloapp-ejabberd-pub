%%%-------------------------------------------------------------------
%%% @author yexin
%%% @copyright (C) 2020, HalloApp, Inc.
%%% @doc
%%%
%%% @end
%%% Created : 17. Jul 2020 3:25 PM
%%%-------------------------------------------------------------------
-module(iq_whisper_keys_parser_tests).
-author("yexin").

-include_lib("eunit/include/eunit.hrl").
-include("packets.hrl").
-include("xmpp.hrl").

%% -------------------------------------------- %%
%% define whisper_keys constants
%% -------------------------------------------- %%

-define(XMPP_IQ_WHISPER_KEYS1,
    #iq{
        id = <<"3ece24923">>,
        type = set,
        sub_els = [#whisper_keys{
                uid = <<"863">>,
                type = add, 
                identity_key = <<"adf-fadsfa">>,
                signed_key = <<"2cd3c3">>,
                otp_key_count = <<"100">>,
                one_time_keys = [<<"3dd">>, <<"31d">>, <<"39e">>]
            }
        ]
    }
).

-define(PB_IQ_WHISPER_KEYS1,
    #pb_iq{
        id = <<"3ece24923">>,
        type = set,
        payload = #pb_whisper_keys{
                uid = 863,
                action = add,   
                identity_key = <<"adf-fadsfa">>,
                signed_key = <<"2cd3c3">>,
                otp_key_count = 100,
                one_time_keys = [<<"3dd">>, <<"31d">>, <<"39e">>]
            }
    }
).


-define(XMPP_IQ_WHISPER_KEYS2,
    #iq{
        id = <<"3ece24923">>,
        type = get,
        sub_els = [#whisper_keys{
                uid = <<"863">>,
                type = count,
                identity_key = undefined,
                signed_key = undefined,
                otp_key_count = undefined,
                one_time_keys = []
            }
        ]
    }
).

-define(PB_IQ_WHISPER_KEYS2,
    #pb_iq{
        id = <<"3ece24923">>,
        type = get,
        payload = #pb_whisper_keys{
                uid = 863,
                action = count,
                identity_key = undefined,
                signed_key = undefined,
                otp_key_count = undefined,
                one_time_keys = []
            }
    }
).


%% -------------------------------------------- %%
%% internal tests
%% -------------------------------------------- %%


xmpp_to_proto_whisper_keys_test() -> 
    ProtoIQ = iq_parser:xmpp_to_proto(?XMPP_IQ_WHISPER_KEYS1),
    ?assertEqual(true, is_record(ProtoIQ, pb_iq)),
    ?assertEqual(?PB_IQ_WHISPER_KEYS1, ProtoIQ).


proto_to_xmpp_whisper_keys_test() ->
    XmppIQ = iq_parser:proto_to_xmpp(?PB_IQ_WHISPER_KEYS2),
    ?assertEqual(true, is_record(XmppIQ, iq)),
    ?assertEqual(?XMPP_IQ_WHISPER_KEYS2, XmppIQ).

