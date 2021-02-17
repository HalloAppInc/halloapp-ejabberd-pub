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
-include("parser_test_data.hrl").

setup() ->
    stringprep:start(),
    gen_iq_handler:start(ejabberd_local),
    ejabberd_hooks:start_link(),
    mod_redis:start(undefined, []),
    ok.


%% -------------------------------------------- %%
%% internal tests
%% -------------------------------------------- %%


%% iq-error with privacy_list_result.
xmpp_to_proto_iq_error_test() ->
    setup(),
    PrivacyListResult = struct_util:create_pb_privacy_list_result(<<"failed">>, <<"unexcepted_uids">>, <<"123">>),
    ExpectedProtoIQ = struct_util:create_pb_iq(?ID1, error, PrivacyListResult),
    ErrorIQ = struct_util:create_iq_stanza(?ID1, jid:make(?UID1, ?SERVER), jid:make(?SERVER), error, [PrivacyListResult]),

    ActualProtoIq = iq_parser:xmpp_to_proto(ErrorIQ),
    ?assertEqual(true, is_record(ActualProtoIq, pb_iq)),
    ?assertEqual(ExpectedProtoIQ, ActualProtoIq).


%% iq-set with privacy_list.
xmpp_to_proto_iq_privacy_list_test() ->
    setup(),
    XmppUidElement1 = struct_util:create_pb_uid_element(add, ?UID2),
    XmppUidElement2 = struct_util:create_pb_uid_element(add, ?UID3),
    XmppPrivacyList = struct_util:create_pb_privacy_list(except, undefined, [XmppUidElement1, XmppUidElement2]),

    UidElement1 = struct_util:create_pb_uid_element(add, ?UID2),
    UidElement2 = struct_util:create_pb_uid_element(add, ?UID3),
    PrivacyList = struct_util:create_pb_privacy_list(except, undefined, [UidElement1, UidElement2]),
    ExpectedProtoIQ = struct_util:create_pb_iq(?ID1, set, PrivacyList),
    ExceptIQ = struct_util:create_iq_stanza(?ID1, jid:make(?SERVER), jid:make(?UID1, ?SERVER), set, [XmppPrivacyList]),

    ActualProtoIq = iq_parser:xmpp_to_proto(ExceptIQ),
    ?assertEqual(true, is_record(ActualProtoIq, pb_iq)),
    ?assertEqual(ExpectedProtoIQ, ActualProtoIq).


%% iq-set with privacy_list and hash.
xmpp_to_proto_iq_privacy_list_hash_test() ->
    setup(),
    UidElement1 = struct_util:create_pb_uid_element(add, ?UID3),
    PrivacyList = struct_util:create_pb_privacy_list(except, ?HASH1, [UidElement1]),
    ExpectedProtoIQ = struct_util:create_pb_iq(?ID1, set, PrivacyList),

    XmppUidElement1 = struct_util:create_pb_uid_element(add, ?UID3),
    XmppPrivacyList = struct_util:create_pb_privacy_list(except, ?HASH1, [XmppUidElement1]),
    ExceptIQ = struct_util:create_iq_stanza(?ID1, jid:make(?SERVER), jid:make(?UID1, ?SERVER), set, [XmppPrivacyList]),

    ActualProtoIq = iq_parser:xmpp_to_proto(ExceptIQ),
    ?assertEqual(true, is_record(ActualProtoIq, pb_iq)),
    ?assertEqual(ExpectedProtoIQ, ActualProtoIq).


%% iq-empty result.
xmpp_to_proto_iq_privacy_list_result_test() ->
    setup(),
    ExceptIQ = struct_util:create_iq_stanza(?ID1, jid:make(?UID1, ?SERVER), jid:make(?SERVER), result, []),

    ExpectedProtoIQ = struct_util:create_pb_iq(?ID1, result, undefined),

    ActualProtoIq = iq_parser:xmpp_to_proto(ExceptIQ),
    ?assertEqual(true, is_record(ActualProtoIq, pb_iq)),
    ?assertEqual(ExpectedProtoIQ, ActualProtoIq).


%% iq-result with all lists.
xmpp_to_proto_iq_privacy_lists_result_test() ->
    setup(),
    UidElement1 = struct_util:create_pb_uid_element(add, ?UID2),
    UidElement2 = struct_util:create_pb_uid_element(add, ?UID3),
    UidElement3 = struct_util:create_pb_uid_element(add, ?UID4),
    UidElement4 = struct_util:create_pb_uid_element(add, ?UID5),
    PrivacyList1 = struct_util:create_pb_privacy_list(except, <<>>, [UidElement1, UidElement2]),
    PrivacyList2 = struct_util:create_pb_privacy_list(only, <<>>, [UidElement2, UidElement3]),
    PrivacyList3 = struct_util:create_pb_privacy_list(mute, <<>>, [UidElement3]),
    PrivacyList4 = struct_util:create_pb_privacy_list(block, <<>>, [UidElement4]),

    PrivacyLists = struct_util:create_pb_privacy_lists(only, [PrivacyList4, PrivacyList3, PrivacyList2, PrivacyList1]),
    ExpectedProtoIQ = struct_util:create_pb_iq(?ID1, result, PrivacyLists),

    XmppUidElement1 = struct_util:create_pb_uid_element(add, ?UID2),
    XmppUidElement2 = struct_util:create_pb_uid_element(add, ?UID3),
    XmppUidElement3 = struct_util:create_pb_uid_element(add, ?UID4),
    XmppUidElement4 = struct_util:create_pb_uid_element(add, ?UID5),
    XmppPrivacyList1 = struct_util:create_pb_privacy_list(except, <<>>, [XmppUidElement1, XmppUidElement2]),
    XmppPrivacyList2 = struct_util:create_pb_privacy_list(only, <<>>, [XmppUidElement2, XmppUidElement3]),
    XmppPrivacyList3 = struct_util:create_pb_privacy_list(mute, <<>>, [XmppUidElement3]),
    XmppPrivacyList4 = struct_util:create_pb_privacy_list(block, <<>>, [XmppUidElement4]),

    XmppPrivacyLists = struct_util:create_pb_privacy_lists(only, [XmppPrivacyList4, XmppPrivacyList3, XmppPrivacyList2, XmppPrivacyList1]),
    ExceptIQ = struct_util:create_iq_stanza(?ID1, jid:make(?UID1, ?SERVER), jid:make(?SERVER), result, [XmppPrivacyLists]),

    ActualProtoIq = iq_parser:xmpp_to_proto(ExceptIQ),
    ?assertEqual(true, is_record(ActualProtoIq, pb_iq)),
    ?assertEqual(ExpectedProtoIQ, ActualProtoIq).


%% iq-set for only privacy_list.
proto_to_xmpp_iq_only_privacy_list_test() ->
    setup(),
    UidElement1 = struct_util:create_pb_uid_element(add, ?UID2),
    UidElement2 = struct_util:create_pb_uid_element(add, ?UID3),
    PrivacyList = struct_util:create_pb_privacy_list(only, <<>>, [UidElement1, UidElement2]),
    ProtoIQ = struct_util:create_pb_iq(?ID1, set, PrivacyList),

    XmppUidElement1 = struct_util:create_pb_uid_element(add, ?UID2),
    XmppUidElement2 = struct_util:create_pb_uid_element(add, ?UID3),
    XmppPrivacyList = struct_util:create_pb_privacy_list(only, <<>>, [XmppUidElement1, XmppUidElement2]),
    ExceptedXmppIQ = struct_util:create_iq_stanza(?ID1, undefined, undefined, set, [XmppPrivacyList]),

    ActualXmppIq = iq_parser:proto_to_xmpp(ProtoIQ),
    ?assertEqual(true, is_record(ActualXmppIq, iq)),
    ?assertEqual(ExceptedXmppIQ, ActualXmppIq).


%% iq-set for only privacy_list and hash.
proto_to_xmpp_iq_only_privacy_list_hash_test() ->
    setup(),
    UidElement1 = struct_util:create_pb_uid_element(add, ?UID2),
    PrivacyList = struct_util:create_pb_privacy_list(only, ?HASH2, [UidElement1]),
    ProtoIQ = struct_util:create_pb_iq(?ID1, set, PrivacyList),

    XmppUidElement1 = struct_util:create_pb_uid_element(add, ?UID2),
    XmppPrivacyList = struct_util:create_pb_privacy_list(only, ?HASH2, [XmppUidElement1]),
    ExceptedXmppIQ = struct_util:create_iq_stanza(?ID1, undefined, undefined, set, [XmppPrivacyList]),

    ActualXmppIq = iq_parser:proto_to_xmpp(ProtoIQ),
    ?assertEqual(true, is_record(ActualXmppIq, iq)),
    ?assertEqual(ExceptedXmppIQ, ActualXmppIq).


%% iq-set for all privacy_list.
proto_to_xmpp_iq_all_privacy_list_test() ->
    setup(),
    PrivacyList = struct_util:create_pb_privacy_list(all, <<>>, []),
    ProtoIQ = struct_util:create_pb_iq(?ID1, set, PrivacyList),
    ExceptedXmppIQ = struct_util:create_iq_stanza(?ID1, undefined, undefined, set, [PrivacyList]),

    ActualXmppIq = iq_parser:proto_to_xmpp(ProtoIQ),
    ?assertEqual(true, is_record(ActualXmppIq, iq)),
    ?assertEqual(ExceptedXmppIQ, ActualXmppIq).


%% iq-get to retrieve all privacy_lists.
proto_to_xmpp_iq_privacy_lists_test() ->
    setup(),
    ExceptedXmppIQ = struct_util:create_iq_stanza(?ID1, undefined, undefined, get, [#pb_privacy_lists{}]),

    ProtoIQ = struct_util:create_pb_iq(?ID1, get, #pb_privacy_lists{}),

    ActualXmppIq = iq_parser:proto_to_xmpp(ProtoIQ),
    ?assertEqual(true, is_record(ActualXmppIq, iq)),
    ?assertEqual(ExceptedXmppIQ, ActualXmppIq).


proto_to_xmpp_iq_only_get_privacy_list_test() ->
    setup(),
    PrivacyList = struct_util:create_pb_privacy_list(only, undefined, []),
    ProtoIQ = struct_util:create_pb_iq(?ID1, set, PrivacyList),
    ExceptedXmppIQ = struct_util:create_iq_stanza(?ID1, undefined, undefined, set, [PrivacyList]),

    ActualXmppIq = iq_parser:proto_to_xmpp(ProtoIQ),
    ?assertEqual(true, is_record(ActualXmppIq, iq)),
    ?assertEqual(ExceptedXmppIQ, ActualXmppIq).

