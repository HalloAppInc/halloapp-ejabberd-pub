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
%% define push_register constants
%% -------------------------------------------- %%

create_push_register(Os, Token) ->
    #push_register{
        push_token = {Os, Token}
    }.

create_pb_push_register(Os, Token) ->
    #pb_push_register{
        push_token = #pb_push_token{
            os = Os,
            token = Token
        }
    }.


create_push_pref(Name, Value) ->
    #push_pref{
        name = Name,
        value = Value
    }.

create_pb_push_pref(Name, Value) ->
    #pb_push_pref{
        name = Name,
        value = Value
    }.


create_notification_prefs(PushPrefs) ->
    #notification_prefs{
        push_prefs = PushPrefs
    }.


create_pb_notification_prefs(PushPrefs) ->
    #pb_notification_prefs{
        push_prefs = PushPrefs
    }.

create_iq_stanza(Id, ToJid, FromJid, Type, SubEls) ->
    #iq{
        id = Id,
        to = ToJid,
        from = FromJid,
        type = Type,
        sub_els = SubEls
    }.


create_pb_iq(Id, Type, PayloadContent) ->
    #pb_iq{
        id = Id,
        type = Type,
        payload = PayloadContent
    }.


%% -------------------------------------------- %%
%% internal tests
%% -------------------------------------------- %%


xmpp_to_proto_push_register_test() ->
    PbPushRegister = create_pb_push_register(?OS1, ?TOKEN1),
    ExpectedPbIq = create_pb_iq(?ID1, set, PbPushRegister),

    XmppPushRegister = create_push_register(?OS1_BIN, ?TOKEN1),
    XmppIq = create_iq_stanza(?ID1, undefined, undefined, set, [XmppPushRegister]),

    ActualPbIq = iq_parser:xmpp_to_proto(XmppIq),
    ?assertEqual(true, is_record(ActualPbIq, pb_iq)),
    ?assertEqual(ExpectedPbIq, ActualPbIq).


proto_to_xmpp_push_register_test() ->
    PbPushRegister = create_pb_push_register(?OS1, ?TOKEN1),
    PbIq = create_pb_iq(?ID1, set, PbPushRegister),

    XmppPushRegister = create_push_register(?OS1_BIN, ?TOKEN1),
    ExpectedXmppIq = create_iq_stanza(?ID1, undefined, undefined, set, [XmppPushRegister]),

    ActualXmppIq = iq_parser:proto_to_xmpp(PbIq),
    ?assertEqual(true, is_record(ActualXmppIq, iq)),
    ?assertEqual(ExpectedXmppIq, ActualXmppIq).


xmpp_to_proto_result_iq_test() ->
    ExpectedPbIq = create_pb_iq(?ID1, result, undefined),

    XmppIq = create_iq_stanza(?ID1, undefined, undefined, result, []),

    ActualPbIq = iq_parser:xmpp_to_proto(XmppIq),
    ?assertEqual(true, is_record(ActualPbIq, pb_iq)),
    ?assertEqual(ExpectedPbIq, ActualPbIq).



proto_to_xmpp_notification_prefs_test() ->
    PbPushPref1 = create_pb_push_pref(post, false),
    PbPushPref2 = create_pb_push_pref(comment, false),
    PbNotificationPref = create_pb_notification_prefs([PbPushPref1, PbPushPref2]),
    PbIq = create_pb_iq(?ID1, set, PbNotificationPref),

    PushPref1 = create_push_pref(post, false),
    PushPref2 = create_push_pref(comment, false),
    NotificationPref = create_notification_prefs([PushPref1, PushPref2]),
    ExpectedXmppIq = create_iq_stanza(?ID1, undefined, undefined, set, [NotificationPref]),

    ActualXmppIq = iq_parser:proto_to_xmpp(PbIq),
    ?assertEqual(true, is_record(ActualXmppIq, iq)),
    ?assertEqual(ExpectedXmppIq, ActualXmppIq).

