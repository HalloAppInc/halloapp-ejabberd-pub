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
-include("parser_test_data.hrl").


%% -------------------------------------------- %%
%% internal tests
%% -------------------------------------------- %%

setup() ->
    stringprep:start(),
    ok.


xmpp_to_proto_avatar_test() ->
    setup(),
    ToJid = struct_util:create_jid(?UID1, ?SERVER),
    FromJid = struct_util:create_jid(?UID2, ?SERVER),
    Avatar = struct_util:create_avatar(?ID1, ?UID2, <<>>),
    XmppMsg = struct_util:create_message_stanza(?ID1, ToJid, FromJid, normal, Avatar),

    PbAvatar = struct_util:create_pb_avatar(?ID1, ?UID2_INT),
    PbMsg = struct_util:create_pb_message(?ID1, ?UID1_INT, ?UID2_INT, normal, PbAvatar),

    ActualProtoMsg = message_parser:xmpp_to_proto(XmppMsg),
    ?assertEqual(true, is_record(ActualProtoMsg, pb_msg)),
    ?assertEqual(PbMsg, ActualProtoMsg).
    
    
proto_to_xmpp_avatar_test() ->
    setup(),
    ToJid = struct_util:create_jid(?UID1, ?SERVER),
    FromJid = struct_util:create_jid(?UID2, ?SERVER),
    Avatar = struct_util:create_avatar(?ID1, ?UID2, <<>>),
    XmppMsg = struct_util:create_message_stanza(?ID1, ToJid, FromJid, normal, Avatar),

    PbAvatar = struct_util:create_pb_avatar(?ID1, ?UID2_INT),
    PbMsg = struct_util:create_pb_message(?ID1, ?UID1_INT, ?UID2_INT, normal, PbAvatar),

    ActualXmppMsg = message_parser:proto_to_xmpp(PbMsg),
    ?assertEqual(true, is_record(ActualXmppMsg, message)),
    ?assertEqual(XmppMsg, ActualXmppMsg).

