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
-include("parser_test_data.hrl").

%% -------------------------------------------- %%
%% internal tests
%% -------------------------------------------- %%


xmpp_to_proto_avatar_test() ->
    Avatar = struct_util:create_pb_avatar(?ID1, ?UID1),
    XmppIq = struct_util:create_iq_stanza(?ID2, undefined, undefined, result, Avatar),

    PbAvatar = struct_util:create_pb_avatar(?ID1, ?UID1_INT),
    PbIq = struct_util:create_pb_iq(?ID2, result, PbAvatar),

    ProtoIq = iq_parser:xmpp_to_proto(XmppIq),
    ?assertEqual(true, is_record(ProtoIq, pb_iq)),
    ?assertEqual(PbIq, ProtoIq).


xmpp_to_proto_get_avatars_test() ->
    Avatar1 = struct_util:create_pb_avatar(?ID1, ?UID1),
    Avatar2 = struct_util:create_pb_avatar(?ID2, ?UID2),
    Avatars = struct_util:create_pb_avatars([Avatar1, Avatar2]),
    XmppIq = struct_util:create_iq_stanza(?ID2, undefined, undefined, result, Avatars),

    PbAvatar1 = struct_util:create_pb_avatar(?ID1, ?UID1_INT),
    PbAvatar2 = struct_util:create_pb_avatar(?ID2, ?UID2_INT),
    PbAvatars = struct_util:create_pb_avatars([PbAvatar1, PbAvatar2]),
    PbIq = struct_util:create_pb_iq(?ID2, result, PbAvatars),

    ProtoIq = iq_parser:xmpp_to_proto(XmppIq),
    ?assertEqual(true, is_record(ProtoIq, pb_iq)),
    ?assertEqual(PbIq, ProtoIq).


proto_to_xmpp_set_avatar_test() ->
    Avatar = struct_util:create_pb_upload_avatar(undefined, ?PAYLOAD1),
    XmppIq = struct_util:create_iq_stanza(?ID2, undefined, undefined, set, Avatar),

    PbAvatar = struct_util:create_pb_upload_avatar(undefined, ?PAYLOAD1),
    PbIq = struct_util:create_pb_iq(?ID2, set, PbAvatar),

    ActualXmppIq = iq_parser:proto_to_xmpp(PbIq),
    ?assertEqual(true, is_record(ActualXmppIq, iq)),
    ?assertEqual(XmppIq, ActualXmppIq).


proto_to_xmpp_get_avatar_test() ->
    Avatar = struct_util:create_pb_avatar(undefined, ?UID1),
    XmppIq = struct_util:create_iq_stanza(?ID2, undefined, undefined, get, Avatar),

    PbAvatar = struct_util:create_pb_avatar(undefined, ?UID1_INT),
    PbIq = struct_util:create_pb_iq(?ID2, get, PbAvatar),

    ActualXmppIq = iq_parser:proto_to_xmpp(PbIq),
    ?assertEqual(true, is_record(ActualXmppIq, iq)),
    ?assertEqual(XmppIq, ActualXmppIq).


proto_to_xmpp_get_avatars_test() ->
    Avatar1 = struct_util:create_pb_avatar(undefined, ?UID1),
    Avatar2 = struct_util:create_pb_avatar(undefined, ?UID2),
    Avatars = struct_util:create_pb_avatars([Avatar1, Avatar2]),
    XmppIq = struct_util:create_iq_stanza(?ID2, undefined, undefined, get, Avatars),

    PbAvatar1 = struct_util:create_pb_avatar(undefined, ?UID1_INT),
    PbAvatar2 = struct_util:create_pb_avatar(undefined, ?UID2_INT),
    PbAvatars = struct_util:create_pb_avatars([PbAvatar1, PbAvatar2]),
    PbIq = struct_util:create_pb_iq(?ID2, get, PbAvatars),

    ActualXmppIq = iq_parser:proto_to_xmpp(PbIq),
    ?assertEqual(true, is_record(ActualXmppIq, iq)),
    ?assertEqual(XmppIq, ActualXmppIq).

