%%%-------------------------------------------------------------------
%%% @author yexin
%%% @copyright (C) 2020, HalloApp, Inc.
%%% @doc
%%%
%%% @end
%%% Created : 17. Jul 2020 3:10 PM
%%%-------------------------------------------------------------------
-module(iq_contact_parser_tests).
-author("yexin").

-include_lib("eunit/include/eunit.hrl").
-include("packets.hrl").
-include("xmpp.hrl").
-include("parser_test_data.hrl").

%% -------------------------------------------- %%
%% internal tests
%% -------------------------------------------- %%


xmpp_to_proto_contact_list_test() ->
    Contact1 = struct_util:create_contact(add, ?RAW1, ?NORM1, ?UID1, ?ID1, ?NAME1, <<"friends">>),
    Contact2 = struct_util:create_contact(delete, ?RAW2, ?NORM2, ?UID2, undefined, ?NAME2, <<"none">>),
    ContactList = struct_util:create_contact_list(full, ?ID1, 0, true, [Contact1, Contact2], []),
    XmppIq = struct_util:create_iq_stanza(?ID2, undefined, undefined, result, ContactList),

    PbContact1 = struct_util:create_pb_contact(add, ?RAW1, ?NORM1, ?UID1_INT, ?ID1, ?NAME1, friends),
    PbContact2 = struct_util:create_pb_contact(delete, ?RAW2, ?NORM2, ?UID2_INT, undefined, ?NAME2, none),
    PbContactList = struct_util:create_pb_contact_list(full, ?ID1, 0, true, [PbContact1, PbContact2]),
    PbIq = struct_util:create_pb_iq(?ID2, result, PbContactList),

    ProtoIQ = iq_parser:xmpp_to_proto(XmppIq),
    ?assertEqual(true, is_record(ProtoIQ, pb_iq)),
    ?assertEqual(PbIq, ProtoIQ).


proto_to_xmpp_contact_list_test() ->
    Contact1 = struct_util:create_contact(add, ?RAW1, undefined, <<>>, undefined, undefined, undefined),
    Contact2 = struct_util:create_contact(delete, ?RAW2, undefined, <<>>, undefined, undefined, undefined),
    ContactList = struct_util:create_contact_list(delta, ?ID1, 0, false, [Contact1, Contact2], []),
    XmppIq = struct_util:create_iq_stanza(?ID2, undefined, undefined, result, ContactList),

    PbContact1 = struct_util:create_pb_contact(add, ?RAW1, undefined, undefined, undefined, undefined, undefined),
    PbContact2 = struct_util:create_pb_contact(delete, ?RAW2, undefined, undefined, undefined, undefined, undefined),
    PbContactList = struct_util:create_pb_contact_list(delta, ?ID1, 0, false, [PbContact1, PbContact2]),
    PbIq = struct_util:create_pb_iq(?ID2, result, PbContactList),

    ActualXmppIQ = iq_parser:proto_to_xmpp(PbIq),
    ?assertEqual(true, is_record(ActualXmppIQ, iq)),
    ?assertEqual(XmppIq, ActualXmppIQ).

