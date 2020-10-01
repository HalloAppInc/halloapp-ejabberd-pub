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

-define(HASH1_BASE64, <<"YWI">>).
-define(HASH1, <<"ab">>).
-define(HASH2_BASE64, <<"MTI">>).
-define(HASH2, <<"12">>).


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
    SubEl = struct_util:create_error_st(unexcepted_uids, <<"MTIz">>),
    ErrorIQ = struct_util:create_iq_stanza(?ID1, jid:make(?UID1, ?SERVER), jid:make(?SERVER), error, [SubEl]),

    PrivacyListResult = struct_util:create_pb_privacy_list_result(<<"failed">>, <<"unexcepted_uids">>, <<"123">>),
    ExpectedProtoIQ = struct_util:create_pb_iq(?ID1, error, PrivacyListResult),

    ActualProtoIq = iq_parser:xmpp_to_proto(ErrorIQ),
    ?assertEqual(true, is_record(ActualProtoIq, pb_iq)),
    ?assertEqual(ExpectedProtoIQ, ActualProtoIq).


%% iq-set with privacy_list.
xmpp_to_proto_iq_privacy_list_test() ->
    setup(),
    UidEl1 = struct_util:create_uid_el(add, ?UID2),
    UidEl2 = struct_util:create_uid_el(add, ?UID3),
    SubEl = struct_util:create_user_privacy_list(except, undefined, [UidEl1, UidEl2]),
    ExceptIQ = struct_util:create_iq_stanza(?ID1, jid:make(?SERVER), jid:make(?UID1, ?SERVER), set, [SubEl]),

    UidElement1 = struct_util:create_pb_uid_element(add, ?UID2_INT),
    UidElement2 = struct_util:create_pb_uid_element(add, ?UID3_INT),
    PrivacyList = struct_util:create_pb_privacy_list(except, undefined, [UidElement1, UidElement2]),
    ExpectedProtoIQ = struct_util:create_pb_iq(?ID1, set, PrivacyList),

    ActualProtoIq = iq_parser:xmpp_to_proto(ExceptIQ),
    ?assertEqual(true, is_record(ActualProtoIq, pb_iq)),
    ?assertEqual(ExpectedProtoIQ, ActualProtoIq).


%% iq-set with privacy_list and hash.
xmpp_to_proto_iq_privacy_list_hash_test() ->
    setup(),
    UidEl1 = struct_util:create_uid_el(add, ?UID3),
    SubEl = struct_util:create_user_privacy_list(except, ?HASH1_BASE64, [UidEl1]),
    ExceptIQ = struct_util:create_iq_stanza(?ID1, jid:make(?SERVER), jid:make(?UID1, ?SERVER), set, [SubEl]),

    UidElement1 = struct_util:create_pb_uid_element(add, ?UID3_INT),
    PrivacyList = struct_util:create_pb_privacy_list(except, ?HASH1, [UidElement1]),
    ExpectedProtoIQ = struct_util:create_pb_iq(?ID1, set, PrivacyList),

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
    UidEl1 = struct_util:create_uid_el(add, ?UID2),
    UidEl2 = struct_util:create_uid_el(add, ?UID3),
    UidEl3 = struct_util:create_uid_el(add, ?UID4),
    UidEl4 = struct_util:create_uid_el(add, ?UID5),
    SubEl1 = struct_util:create_user_privacy_list(except, <<>>, [UidEl1, UidEl2]),
    SubEl2 = struct_util:create_user_privacy_list(only, <<>>, [UidEl2, UidEl3]),
    SubEl3 = struct_util:create_user_privacy_list(mute, <<>>, [UidEl3]),
    SubEl4 = struct_util:create_user_privacy_list(block, <<>>, [UidEl4]),

    UserPrivacyLists = struct_util:create_user_privacy_lists(only, [SubEl4, SubEl3, SubEl2, SubEl1]),
    ExceptIQ = struct_util:create_iq_stanza(?ID1, jid:make(?UID1, ?SERVER), jid:make(?SERVER), result, [UserPrivacyLists]),

    UidElement1 = struct_util:create_pb_uid_element(add, ?UID2_INT),
    UidElement2 = struct_util:create_pb_uid_element(add, ?UID3_INT),
    UidElement3 = struct_util:create_pb_uid_element(add, ?UID4_INT),
    UidElement4 = struct_util:create_pb_uid_element(add, ?UID5_INT),
    PrivacyList1 = struct_util:create_pb_privacy_list(except, <<>>, [UidElement1, UidElement2]),
    PrivacyList2 = struct_util:create_pb_privacy_list(only, <<>>, [UidElement2, UidElement3]),
    PrivacyList3 = struct_util:create_pb_privacy_list(mute, <<>>, [UidElement3]),
    PrivacyList4 = struct_util:create_pb_privacy_list(block, <<>>, [UidElement4]),

    PrivacyLists = struct_util:create_pb_privacy_lists(only, [PrivacyList4, PrivacyList3, PrivacyList2, PrivacyList1]),
    ExpectedProtoIQ = struct_util:create_pb_iq(?ID1, result, PrivacyLists),

    ActualProtoIq = iq_parser:xmpp_to_proto(ExceptIQ),
    ?assertEqual(true, is_record(ActualProtoIq, pb_iq)),
    ?assertEqual(ExpectedProtoIQ, ActualProtoIq).


%% iq-set for only privacy_list.
proto_to_xmpp_iq_only_privacy_list_test() ->
    setup(),
    UidEl1 = struct_util:create_uid_el(add, ?UID2),
    UidEl2 = struct_util:create_uid_el(add, ?UID3),
    SubEl = struct_util:create_user_privacy_list(only, <<>>, [UidEl1, UidEl2]),
    ExceptedXmppIQ = struct_util:create_iq_stanza(?ID1, undefined, undefined, set, [SubEl]),

    UidElement1 = struct_util:create_pb_uid_element(add, ?UID2_INT),
    UidElement2 = struct_util:create_pb_uid_element(add, ?UID3_INT),
    PrivacyList = struct_util:create_pb_privacy_list(only, <<>>, [UidElement1, UidElement2]),
    ProtoIQ = struct_util:create_pb_iq(?ID1, set, PrivacyList),

    ActualXmppIq = iq_parser:proto_to_xmpp(ProtoIQ),
    ?assertEqual(true, is_record(ActualXmppIq, iq)),
    ?assertEqual(ExceptedXmppIQ, ActualXmppIq).


%% iq-set for only privacy_list and hash.
proto_to_xmpp_iq_only_privacy_list_hash_test() ->
    setup(),
    UidEl1 = struct_util:create_uid_el(add, ?UID2),
    SubEl = struct_util:create_user_privacy_list(only, ?HASH2_BASE64, [UidEl1]),
    ExceptedXmppIQ = struct_util:create_iq_stanza(?ID1, undefined, undefined, set, [SubEl]),

    UidElement1 = struct_util:create_pb_uid_element(add, ?UID2_INT),
    PrivacyList = struct_util:create_pb_privacy_list(only, ?HASH2, [UidElement1]),
    ProtoIQ = struct_util:create_pb_iq(?ID1, set, PrivacyList),

    ActualXmppIq = iq_parser:proto_to_xmpp(ProtoIQ),
    ?assertEqual(true, is_record(ActualXmppIq, iq)),
    ?assertEqual(ExceptedXmppIQ, ActualXmppIq).


%% iq-set for all privacy_list.
proto_to_xmpp_iq_all_privacy_list_test() ->
    setup(),
    SubEl = struct_util:create_user_privacy_list(all, <<>>, []),
    ExceptedXmppIQ = struct_util:create_iq_stanza(?ID1, undefined, undefined, set, [SubEl]),

    PrivacyList = struct_util:create_pb_privacy_list(all, <<>>, []),
    ProtoIQ = struct_util:create_pb_iq(?ID1, set, PrivacyList),

    ActualXmppIq = iq_parser:proto_to_xmpp(ProtoIQ),
    ?assertEqual(true, is_record(ActualXmppIq, iq)),
    ?assertEqual(ExceptedXmppIQ, ActualXmppIq).


%% iq-get to retrieve all privacy_lists.
proto_to_xmpp_iq_privacy_lists_test() ->
    setup(),
    ExceptedXmppIQ = struct_util:create_iq_stanza(?ID1, undefined, undefined, get, [#user_privacy_lists{active_type = all}]),

    ProtoIQ = struct_util:create_pb_iq(?ID1, get, #pb_privacy_lists{}),

    ActualXmppIq = iq_parser:proto_to_xmpp(ProtoIQ),
    ?assertEqual(true, is_record(ActualXmppIq, iq)),
    ?assertEqual(ExceptedXmppIQ, ActualXmppIq).


proto_to_xmpp_iq_only_get_privacy_list_test() ->
    setup(),
    SubEl = struct_util:create_user_privacy_list(only, undefined, []),
    ExceptedXmppIQ = struct_util:create_iq_stanza(?ID1, undefined, undefined, set, [SubEl]),

    PrivacyList = struct_util:create_pb_privacy_list(only, undefined, []),
    ProtoIQ = struct_util:create_pb_iq(?ID1, set, PrivacyList),

    ActualXmppIq = iq_parser:proto_to_xmpp(ProtoIQ),
    ?assertEqual(true, is_record(ActualXmppIq, iq)),
    ?assertEqual(ExceptedXmppIQ, ActualXmppIq).

