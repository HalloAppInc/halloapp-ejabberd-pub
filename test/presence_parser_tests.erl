%%%-------------------------------------------------------------------
%%% @author yexin
%%% @copyright (C) 2020, HalloApp, Inc.
%%% @doc
%%%
%%% @end
%%% Created : 14. Jul 2020 1:00 PM
%%%-------------------------------------------------------------------
-module(presence_parser_tests).
-author("yexin").

-include_lib("eunit/include/eunit.hrl").
-include("packets.hrl").
-include("xmpp.hrl").
-include("parser_test_data.hrl").

%% -------------------------------------------- %%
%% Tests
%% -------------------------------------------- %%

setup() ->
    stringprep:start(),
    ok.

xmpp_to_proto_available_test() ->
    setup(),

    FromJid = struct_util:create_jid(?UID1, ?SERVER),
    XmppPresence = struct_util:create_presence(?ID1, available, undefined, FromJid, undefined),
    PbPresence = struct_util:create_pb_presence(?ID1, available, ?UID1, <<>>, ?UID1, undefined),

    ProtoPresence = presence_parser:xmpp_to_proto(XmppPresence),
    ?assertEqual(true, is_record(ProtoPresence, pb_presence)),
    ?assertEqual(PbPresence, ProtoPresence).


xmpp_to_proto_away_test() ->
    setup(),

    FromJid = struct_util:create_jid(?UID1, ?SERVER),
    XmppPresence = struct_util:create_presence(?ID1, away, undefined, FromJid, ?TIMESTAMP1),
    PbPresence = struct_util:create_pb_presence(?ID1, away, ?UID1, <<>>, ?UID1, ?TIMESTAMP1_INT),

    ProtoPresence = presence_parser:xmpp_to_proto(XmppPresence),
    ?assertEqual(true, is_record(ProtoPresence, pb_presence)),
    ?assertEqual(PbPresence, ProtoPresence).


proto_to_xmpp_available_test() ->
    setup(),

    XmppPresence = struct_util:create_presence(?ID1, available, undefined, undefined, undefined),
    PbPresence = struct_util:create_pb_presence(?ID1, available, undefined, undefined, undefined, undefined),

    ActualXmppPresence = presence_parser:proto_to_xmpp(PbPresence),
    ?assertEqual(true, is_record(ActualXmppPresence, presence)),
    ?assertEqual(XmppPresence, ActualXmppPresence).


proto_to_xmpp_away_test() ->
    setup(),

    XmppPresence = struct_util:create_presence(?ID1, away, undefined, undefined, undefined),
    PbPresence = struct_util:create_pb_presence(?ID1, away, undefined, undefined, undefined, undefined),

    ActualXmppPresence = presence_parser:proto_to_xmpp(PbPresence),
    ?assertEqual(true, is_record(ActualXmppPresence, presence)),
    ?assertEqual(XmppPresence, ActualXmppPresence).


proto_to_xmpp_subscribe_test() ->
    setup(),

    ToJid = struct_util:create_jid(?UID1, ?SERVER),
    XmppPresence = struct_util:create_presence(?ID1, subscribe, ToJid, undefined, undefined),
    PbPresence = struct_util:create_pb_presence(?ID1, subscribe, ?UID1, ?UID1, undefined, undefined),

    ActualXmppPresence = presence_parser:proto_to_xmpp(PbPresence),
    ?assertEqual(true, is_record(ActualXmppPresence, presence)),
    ?assertEqual(XmppPresence, ActualXmppPresence).

