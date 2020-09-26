%%%-------------------------------------------------------------------
%%% @author yexin
%%% @copyright (C) 2020, HalloApp, Inc.
%%% @doc
%%%
%%% @end
%%% Created : 17. Jul 2020 3:12 PM
%%%-------------------------------------------------------------------
-module(iq_media_upload_parser_tests).
-author("yexin").

-include_lib("eunit/include/eunit.hrl").
-include("packets.hrl").
-include("xmpp.hrl").

%% -------------------------------------------- %%
%% define upload media constants
%% -------------------------------------------- %%

-define(JID1,
    #jid{
        user = <<"1000000000045484920">>,
        server = <<"s.halloapp.net">>,
        resource = <<"iphone">>
    }
).

-define(JID2,
    #jid{
        user = <<"1000000000519345762">>,
        server = <<"s.halloapp.net">>,
        resource = <<"iphone">>
    }
).

-define(UPLOAD_MEDIA1,
    #upload_media{
        size = <<"100">>,
        media_urls = [#media_urls{
            get = <<"https://u-cdn.halloapp.net">>,
            put = <<"https://us-e-halloapp-media.s3-accelerate">>,
            patch = <<>>
        }]
    }
).

-define(XMPP_IQ_UPLOAD_MEDIA1,
    #iq{
        id = <<"TgJNGKUsEeqhxg5_sD_LJQ">>,
        type = result,
        from = undefined,
        to = undefined,
        sub_els = [?UPLOAD_MEDIA1]
    }
).

-define(PROTO_IQ_UPLOAD_MEDIA1,
    #pb_iq{
        id = <<"TgJNGKUsEeqhxg5_sD_LJQ">>,
        type = result,
        payload = #pb_upload_media{
                size = 100,
                url = #pb_media_url{
                    get = <<"https://u-cdn.halloapp.net">>,
                    put = <<"https://us-e-halloapp-media.s3-accelerate">>,
                    patch = <<>>
                }
            }
    }
).


-define(UPLOAD_MEDIA2,
    #upload_media{
        size = <<>>,
        media_urls = []
    }
).

-define(XMPP_IQ_UPLOAD_MEDIA2,
    #iq{
        id = <<"TgJNGKUsEeqhxg5_sD_LJQ">>,
        type = get,
        from = undefined,
        to = undefined,
        sub_els = [?UPLOAD_MEDIA2]
    }
).

-define(PROTO_IQ_UPLOAD_MEDIA2,
    #pb_iq{
        id = <<"TgJNGKUsEeqhxg5_sD_LJQ">>,
        type = get,
        payload = #pb_upload_media{
                size = 0,
                url = undefined
        }
    }
).


%% -------------------------------------------- %%
%% internal tests
%% -------------------------------------------- %%


xmpp_to_proto_upload_media_test() -> 
    ProtoIQ = iq_parser:xmpp_to_proto(?XMPP_IQ_UPLOAD_MEDIA1),
    ?assertEqual(true, is_record(ProtoIQ, pb_iq)),
    ?assertEqual(?PROTO_IQ_UPLOAD_MEDIA1, ProtoIQ).

    
proto_to_xmpp_upload_media_test() ->
    XmppIQ1 = iq_parser:proto_to_xmpp(?PROTO_IQ_UPLOAD_MEDIA1),

    ?assertEqual(true, is_record(XmppIQ1, iq)),
    ?assertEqual(?XMPP_IQ_UPLOAD_MEDIA1, XmppIQ1),

    XmppIQ2 = iq_parser:proto_to_xmpp(?PROTO_IQ_UPLOAD_MEDIA2),   
    ?assertEqual(true, is_record(XmppIQ2, iq)),
    ?assertEqual(?XMPP_IQ_UPLOAD_MEDIA2, XmppIQ2),
    ok.


    
