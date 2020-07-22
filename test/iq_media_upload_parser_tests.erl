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

-define(UPLOAD_MEDIA,
    #upload_media{
        size = <<"100">>,
        media_urls = [#media_urls{
            get = <<"https://u-cdn.halloapp.net">>,
            put = <<"https://us-e-halloapp-media.s3-accelerate">>,
            patch = <<>>
        }]
    }
).

-define(XMPP_IQ_UPLOAD_MEDIA,
    #iq{
        id = <<"TgJNGKUsEeqhxg5_sD_LJQ">>,
        type = result,
        lang = <<"en">>,
        from = ?JID1,
        to = ?JID2,
        sub_els = [?UPLOAD_MEDIA]
    }
).

-define(PROTO_IQ_UPLOAD_MEDIA,
    #pb_ha_iq{
        id = <<"TgJNGKUsEeqhxg5_sD_LJQ">>,
        type = result,
        payload = #pb_iq_payload{
            content = {um, #pb_upload_media{
                size = 100,
                urls = [#pb_media_urls{
                    get = <<"https://u-cdn.halloapp.net">>,
                    put = <<"https://us-e-halloapp-media.s3-accelerate">>,
                    patch = <<>>
                }]
            }}
        }
    }
).


%% -------------------------------------------- %%
%% internal tests
%% -------------------------------------------- %%


xmpp_to_proto_upload_media_test() -> 
    ProtoIQ = iq_parser:xmpp_to_proto(?XMPP_IQ_UPLOAD_MEDIA),
    ?assertEqual(true, is_record(ProtoIQ, pb_ha_iq)),
    ?assertEqual(?PROTO_IQ_UPLOAD_MEDIA, ProtoIQ).

    
proto_to_xmpp_upload_media_test() ->
    XmppIQ = iq_parser:proto_to_xmpp(?PROTO_IQ_UPLOAD_MEDIA),
    ?assertEqual(true, is_record(XmppIQ, iq)),
    ?assertEqual(?XMPP_IQ_UPLOAD_MEDIA#iq.id, XmppIQ#iq.id),
    ?assertEqual(?XMPP_IQ_UPLOAD_MEDIA#iq.type, XmppIQ#iq.type),
    ?assertEqual(?XMPP_IQ_UPLOAD_MEDIA#iq.sub_els, XmppIQ#iq.sub_els).
    
