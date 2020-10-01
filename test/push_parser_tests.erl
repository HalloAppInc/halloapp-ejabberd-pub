%%%-------------------------------------------------------------------
%%% @author yexin
%%% @copyright (C) 2020, HalloApp, Inc.
%%% @doc
%%%
%%% @end
%%% Created : 17. Jul 2020 3:15 PM
%%%-------------------------------------------------------------------
-module(push_parser_tests).
-author("yexin").

-include_lib("eunit/include/eunit.hrl").
-include("packets.hrl").
-include("xmpp.hrl").


-define(ID1, <<"ID1">>).
-define(OS1, ios).
-define(OS1_BIN, <<"ios">>).
-define(TOKEN1, <<"token1">>).


%% -------------------------------------------- %%
%% internal tests
%% -------------------------------------------- %%


xmpp_to_proto_push_register_test() ->
    PbPushRegister = struct_util:create_pb_push_register(?OS1, ?TOKEN1),
    ExpectedPbIq = struct_util:create_pb_iq(?ID1, set, PbPushRegister),

    XmppPushRegister = struct_util:create_push_register(?OS1_BIN, ?TOKEN1),
    XmppIq = struct_util:create_iq_stanza(?ID1, undefined, undefined, set, [XmppPushRegister]),

    ActualPbIq = iq_parser:xmpp_to_proto(XmppIq),
    ?assertEqual(true, is_record(ActualPbIq, pb_iq)),
    ?assertEqual(ExpectedPbIq, ActualPbIq).


proto_to_xmpp_push_register_test() ->
    PbPushRegister = struct_util:create_pb_push_register(?OS1, ?TOKEN1),
    PbIq = struct_util:create_pb_iq(?ID1, set, PbPushRegister),

    XmppPushRegister = struct_util:create_push_register(?OS1_BIN, ?TOKEN1),
    ExpectedXmppIq = struct_util:create_iq_stanza(?ID1, undefined, undefined, set, [XmppPushRegister]),

    ActualXmppIq = iq_parser:proto_to_xmpp(PbIq),
    ?assertEqual(true, is_record(ActualXmppIq, iq)),
    ?assertEqual(ExpectedXmppIq, ActualXmppIq).


xmpp_to_proto_result_iq_test() ->
    ExpectedPbIq = struct_util:create_pb_iq(?ID1, result, undefined),

    XmppIq = struct_util:create_iq_stanza(?ID1, undefined, undefined, result, []),

    ActualPbIq = iq_parser:xmpp_to_proto(XmppIq),
    ?assertEqual(true, is_record(ActualPbIq, pb_iq)),
    ?assertEqual(ExpectedPbIq, ActualPbIq).



proto_to_xmpp_notification_prefs_test() ->
    PbPushPref1 = struct_util:create_pb_push_pref(post, false),
    PbPushPref2 = struct_util:create_pb_push_pref(comment, false),
    PbNotificationPref = struct_util:create_pb_notification_prefs([PbPushPref1, PbPushPref2]),
    PbIq = struct_util:create_pb_iq(?ID1, set, PbNotificationPref),

    PushPref1 = struct_util:create_push_pref(post, false),
    PushPref2 = struct_util:create_push_pref(comment, false),
    NotificationPref = struct_util:create_notification_prefs([PushPref1, PushPref2]),
    ExpectedXmppIq = struct_util:create_iq_stanza(?ID1, undefined, undefined, set, [NotificationPref]),

    ActualXmppIq = iq_parser:proto_to_xmpp(PbIq),
    ?assertEqual(true, is_record(ActualXmppIq, iq)),
    ?assertEqual(ExpectedXmppIq, ActualXmppIq).

