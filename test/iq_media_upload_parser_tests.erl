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
-include("parser_test_data.hrl").

%% -------------------------------------------- %%
%% internal tests
%% -------------------------------------------- %%


xmpp_to_proto_upload_media_test() ->
    PbMediaUrl = struct_util:create_pb_media_url(?GET_URL, ?PUT_URL, <<>>),
    PbUploadMedia = struct_util:create_pb_upload_media(0, PbMediaUrl),
    PbIq = struct_util:create_pb_iq(?ID1, result, PbUploadMedia),
    XmppIq = struct_util:create_iq_stanza(?ID1, undefined, undefined, result, PbUploadMedia),

    ProtoIQ = iq_parser:xmpp_to_proto(XmppIq),
    ?assertEqual(true, is_record(ProtoIQ, pb_iq)),
    ?assertEqual(PbIq, ProtoIQ).

    
proto_to_xmpp_upload_media_test() ->
    PbMediaUrl = struct_util:create_pb_media_url(?GET_URL, ?PUT_URL, <<>>),
    PbUploadMedia = struct_util:create_pb_upload_media(0, PbMediaUrl),
    PbIq = struct_util:create_pb_iq(?ID1, result, PbUploadMedia),
    XmppIq = struct_util:create_iq_stanza(?ID1, undefined, undefined, result, PbUploadMedia),

    ActualXmppIq = iq_parser:proto_to_xmpp(PbIq),
    ?assertEqual(true, is_record(ActualXmppIq, iq)),
    ?assertEqual(XmppIq, ActualXmppIq).


proto_to_xmpp_upload_media2_test() ->
    PbUploadMedia = struct_util:create_pb_upload_media(0, undefined),
    PbIq = struct_util:create_pb_iq(?ID1, get, PbUploadMedia),
    XmppIq = struct_util:create_iq_stanza(?ID1, undefined, undefined, get, PbUploadMedia),

    ActualXmppIq = iq_parser:proto_to_xmpp(PbIq),   
    ?assertEqual(true, is_record(ActualXmppIq, iq)),
    ?assertEqual(XmppIq, ActualXmppIq),
    ok.


    
