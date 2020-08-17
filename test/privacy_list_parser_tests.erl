%%%-------------------------------------------------------------------
%%% File: privacy_list_parser_tests.erl
%%% Copyright (C) 2020, Halloapp Inc.
%%%
%%%-------------------------------------------------------------------
-module(privacy_list_parser_tests).
-author('murali').

-include_lib("eunit/include/eunit.hrl").
-include("packets.hrl").
-include("xmpp.hrl").

%% -------------------------------------------- %%
%% define chat constants
%% -------------------------------------------- %%

-define(UID1, <<"1000000000045484920">>).
-define(UID1_INT, 1000000000045484920).

-define(UID2, <<"1000000000519345762">>).
-define(UID2_INT, 1000000000519345762).

-define(UID3, <<"1000000000474745555">>).
-define(UID3_INT, 1000000000474745555).

-define(UID4, <<"1000000000634158521">>).
-define(UID4_INT, 1000000000634158521).

-define(UID5, <<"1000000000412574111">>).
-define(UID5_INT, 1000000000412574111).

-define(ID1, <<"id1">>).
-define(ID2, <<"id2">>).
-define(ID3, <<"id3">>).

-define(PAYLOAD1, <<"payload1">>).
-define(PAYLOAD2, <<"payload2">>).
-define(TIMESTAMP1, <<"2000090910">>).
-define(TIMESTAMP1_INT, 2000090910).
-define(TIMESTAMP2, <<"1850012340">>).
-define(TIMESTAMP2_INT, 1850012340).
-define(SERVER, <<"s.halloapp.net">>).


setup() ->
    stringprep:start(),
    gen_iq_handler:start(ejabberd_local),
    ejabberd_hooks:start_link(),
    mod_redis:start(undefined, []),
    ok.


create_uid_el(Type, Uid) ->
    #uid_el{
        type = Type,
        uid = Uid
    }.


create_user_privacy_list(Type, Hash, UidEls) ->
    #user_privacy_list {
        type = Type,
        hash = Hash,
        uid_els = UidEls
    }.


create_user_privacy_lists(ActiveType, Lists) ->
    #user_privacy_lists{
        active_type = ActiveType,
        lists = Lists
    }.


create_pb_uid_element(Action, Uid) ->
    #pb_uid_element{
        action = Action,
        uid = Uid
    }.


create_pb_privacy_list(Type, Hash, UidElements) ->
    #pb_privacy_list{
        type = Type,
        hash = Hash,
        uid_elements = UidElements
    }.


create_pb_privacy_lists(ActiveType, PbPrivacyLists) ->
    #pb_privacy_lists{
        active_type = ActiveType,
        lists = PbPrivacyLists
    }.


create_pb_privacy_list_result(Result, Reason, Hash) ->
    #pb_privacy_list_result{
        result = Result,
        reason = Reason,
        hash = Hash
    }.


create_error_st(Reason, Hash) ->
    #error_st{
        reason = Reason,
        hash = Hash
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
    #pb_ha_iq{
        id = Id,
        type = Type,
        payload = #pb_iq_payload{
                content = PayloadContent
            }
    }.


%% -------------------------------------------- %%
%% internal tests
%% -------------------------------------------- %%


%% iq-error with privacy_list_result.
xmpp_to_proto_iq_error_test() ->
    setup(),
    SubEl = create_error_st(unexcepted_uids, <<>>),
    ErrorIQ = create_iq_stanza(?ID1, jid:make(?UID1, ?SERVER), jid:make(?SERVER), error, [SubEl]),

    PrivacyListResult = create_pb_privacy_list_result(<<"failed">>, <<"unexcepted_uids">>, <<>>),
    ExpectedProtoIQ = create_pb_iq(?ID1, error, {privacy_list_result, PrivacyListResult}),

    ActualProtoIq = iq_parser:xmpp_to_proto(ErrorIQ),
    ?assertEqual(true, is_record(ActualProtoIq, pb_ha_iq)),
    ?assertEqual(ExpectedProtoIQ, ActualProtoIq).


%% iq-set with privacy_list.
xmpp_to_proto_iq_privacy_list_test() ->
    setup(),
    UidEl1 = create_uid_el(add, ?UID2),
    UidEl2 = create_uid_el(add, ?UID3),
    SubEl = create_user_privacy_list(except, undefined, [UidEl1, UidEl2]),
    ExceptIQ = create_iq_stanza(?ID1, jid:make(?SERVER), jid:make(?UID1, ?SERVER), set, [SubEl]),

    UidElement1 = create_pb_uid_element(add, ?UID2_INT),
    UidElement2 = create_pb_uid_element(add, ?UID3_INT),
    PrivacyList = create_pb_privacy_list(except, undefined, [UidElement1, UidElement2]),
    ExpectedProtoIQ = create_pb_iq(?ID1, set, {privacy_list, PrivacyList}),

    ActualProtoIq = iq_parser:xmpp_to_proto(ExceptIQ),
    ?assertEqual(true, is_record(ActualProtoIq, pb_ha_iq)),
    ?assertEqual(ExpectedProtoIQ, ActualProtoIq).


%% iq-empty result.
xmpp_to_proto_iq_privacy_list_result_test() ->
    setup(),
    ExceptIQ = create_iq_stanza(?ID1, jid:make(?UID1, ?SERVER), jid:make(?SERVER), result, []),

    ExpectedProtoIQ = create_pb_iq(?ID1, result, undefined),

    ActualProtoIq = iq_parser:xmpp_to_proto(ExceptIQ),
    ?assertEqual(true, is_record(ActualProtoIq, pb_ha_iq)),
    ?assertEqual(ExpectedProtoIQ, ActualProtoIq).


%% iq-result with all lists.
xmpp_to_proto_iq_privacy_lists_result_test() ->
    setup(),
    UidEl1 = create_uid_el(add, ?UID2),
    UidEl2 = create_uid_el(add, ?UID3),
    UidEl3 = create_uid_el(add, ?UID4),
    UidEl4 = create_uid_el(add, ?UID5),
    SubEl1 = create_user_privacy_list(except, <<>>, [UidEl1, UidEl2]),
    SubEl2 = create_user_privacy_list(only, <<>>, [UidEl2, UidEl3]),
    SubEl3 = create_user_privacy_list(mute, <<>>, [UidEl3]),
    SubEl4 = create_user_privacy_list(block, <<>>, [UidEl4]),

    UserPrivacyLists = create_user_privacy_lists(only, [SubEl4, SubEl3, SubEl2, SubEl1]),
    ExceptIQ = create_iq_stanza(?ID1, jid:make(?UID1, ?SERVER), jid:make(?SERVER), result, [UserPrivacyLists]),

    UidElement1 = create_pb_uid_element(add, ?UID2_INT),
    UidElement2 = create_pb_uid_element(add, ?UID3_INT),
    UidElement3 = create_pb_uid_element(add, ?UID4_INT),
    UidElement4 = create_pb_uid_element(add, ?UID5_INT),
    PrivacyList1 = create_pb_privacy_list(except, <<>>, [UidElement1, UidElement2]),
    PrivacyList2 = create_pb_privacy_list(only, <<>>, [UidElement2, UidElement3]),
    PrivacyList3 = create_pb_privacy_list(mute, <<>>, [UidElement3]),
    PrivacyList4 = create_pb_privacy_list(block, <<>>, [UidElement4]),

    PrivacyLists = create_pb_privacy_lists(only, [PrivacyList4, PrivacyList3, PrivacyList2, PrivacyList1]),
    ExpectedProtoIQ = create_pb_iq(?ID1, result, {privacy_lists, PrivacyLists}),

    ActualProtoIq = iq_parser:xmpp_to_proto(ExceptIQ),
    ?assertEqual(true, is_record(ActualProtoIq, pb_ha_iq)),
    ?assertEqual(ExpectedProtoIQ, ActualProtoIq).


%% iq-set for only privacy_list.
proto_to_xmpp_iq_only_privacy_list_test() ->
    setup(),
    UidEl1 = create_uid_el(add, ?UID2),
    UidEl2 = create_uid_el(add, ?UID3),
    SubEl = create_user_privacy_list(only, undefined, [UidEl1, UidEl2]),
    ExceptedXmppIQ = create_iq_stanza(?ID1, undefined, undefined, set, [SubEl]),

    UidElement1 = create_pb_uid_element(add, ?UID2_INT),
    UidElement2 = create_pb_uid_element(add, ?UID3_INT),
    PrivacyList = create_pb_privacy_list(only, undefined, [UidElement1, UidElement2]),
    ProtoIQ = create_pb_iq(?ID1, set, {privacy_list, PrivacyList}),

    ActualXmppIq = iq_parser:proto_to_xmpp(ProtoIQ),
    ?assertEqual(true, is_record(ActualXmppIq, iq)),
    ?assertEqual(ExceptedXmppIQ, ActualXmppIq).


%% iq-set for all privacy_list.
proto_to_xmpp_iq_all_privacy_list_test() ->
    setup(),
    SubEl = create_user_privacy_list(all, undefined, []),
    ExceptedXmppIQ = create_iq_stanza(?ID1, undefined, undefined, set, [SubEl]),

    PrivacyList = create_pb_privacy_list(all, undefined, []),
    ProtoIQ = create_pb_iq(?ID1, set, {privacy_list, PrivacyList}),

    ActualXmppIq = iq_parser:proto_to_xmpp(ProtoIQ),
    ?assertEqual(true, is_record(ActualXmppIq, iq)),
    ?assertEqual(ExceptedXmppIQ, ActualXmppIq).


%% iq-get to retrieve all privacy_lists.
proto_to_xmpp_iq_privacy_lists_test() ->
    setup(),
    ExceptedXmppIQ = create_iq_stanza(?ID1, undefined, undefined, get, [#user_privacy_lists{active_type = all}]),

    ProtoIQ = create_pb_iq(?ID1, get, {privacy_lists, #pb_privacy_lists{}}),

    ActualXmppIq = iq_parser:proto_to_xmpp(ProtoIQ),
    ?assertEqual(true, is_record(ActualXmppIq, iq)),
    ?assertEqual(ExceptedXmppIQ, ActualXmppIq).

