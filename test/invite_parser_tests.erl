%%%-------------------------------------------------------------------
%%% File: invite_parser_tests.erl
%%% Copyright (C) 2020, Halloapp Inc.
%%%
%%%-------------------------------------------------------------------

-module(invite_parser_tests).
-author('murali').

-include_lib("eunit/include/eunit.hrl").
-include("packets.hrl").
-include("xmpp.hrl").
-include("parser_test_data.hrl").

setup() ->
    stringprep:start(),
    ok.

%% -------------------------------------------- %%
%% Tests
%% -------------------------------------------- %%


invite_xmpp_to_proto_test() ->
    setup(),

    PbInvite = struct_util:create_pb_invite(?PHONE1, <<"ok">>, undefined),
    PbInvites = struct_util:create_pb_invites_response(2, 100, [PbInvite]),
    PbIq = struct_util:create_pb_iq(?ID1, result, PbInvites),

    InviteSt = struct_util:create_invite(?PHONE1, ok, undefined),
    InvitesSt = struct_util:create_invites(2, 100, [InviteSt]),
    IqSt = struct_util:create_iq_stanza(?ID1, undefined, undefined, result, InvitesSt),

    ProtoIq = iq_parser:xmpp_to_proto(IqSt),
    ?assertEqual(true, is_record(ProtoIq, pb_iq)),
    ?assertEqual(PbIq, ProtoIq).


invites_xmpp_to_proto_test() ->
    setup(),

    PbInvites = struct_util:create_pb_invites_response(2, 100, []),
    PbIq = struct_util:create_pb_iq(?ID1, result, PbInvites),

    InvitesSt = struct_util:create_invites(2, 100, []),
    IqSt = struct_util:create_iq_stanza(?ID1, undefined, undefined, result, InvitesSt),

    ProtoIq = iq_parser:xmpp_to_proto(IqSt),
    ?assertEqual(true, is_record(ProtoIq, pb_iq)),
    ?assertEqual(PbIq, ProtoIq).


invite_error_xmpp_to_proto_test() ->
    setup(),

    PbInvite = struct_util:create_pb_invite(?PHONE1, <<"failed">>, <<"invalid_number">>),
    PbInvites = struct_util:create_pb_invites_response(5, 1000, [PbInvite]),
    PbIq = struct_util:create_pb_iq(?ID1, result, PbInvites),

    InviteSt = struct_util:create_invite(?PHONE1, failed, invalid_number),
    InvitesSt = struct_util:create_invites(5, 1000, [InviteSt]),
    IqSt = struct_util:create_iq_stanza(?ID1, undefined, undefined, result, InvitesSt),

    ProtoIq = iq_parser:xmpp_to_proto(IqSt),
    ?assertEqual(true, is_record(ProtoIq, pb_iq)),
    ?assertEqual(PbIq, ProtoIq).



invite_set_proto_to_xmpp_test() ->
    setup(),

    PbInvite1 = struct_util:create_pb_invite(?PHONE1, undefined, undefined),
    PbInvite2 = struct_util:create_pb_invite(?PHONE2, undefined, undefined),
    PbInvites = struct_util:create_pb_invites_request([PbInvite1, PbInvite2]),
    PbIq = struct_util:create_pb_iq(?ID1, set, PbInvites),

    InviteSt1 = struct_util:create_invite(?PHONE1, undefined, undefined),
    InviteSt2 = struct_util:create_invite(?PHONE2, undefined, undefined),
    InvitesSt = struct_util:create_invites(undefined, undefined, [InviteSt1, InviteSt2]),
    IqSt = struct_util:create_iq_stanza(?ID1, undefined, undefined, set, InvitesSt),

    XmppIq = iq_parser:proto_to_xmpp(PbIq),
    ?assertEqual(true, is_record(XmppIq, iq)),
    ?assertEqual(IqSt, XmppIq).


invite_get_proto_to_xmpp_test() ->
    setup(),

    PbInvites = struct_util:create_pb_invites_request([]),
    PbIq = struct_util:create_pb_iq(?ID1, get, PbInvites),

    InvitesSt = struct_util:create_invites(undefined, undefined, []),
    IqSt = struct_util:create_iq_stanza(?ID1, undefined, undefined, get, InvitesSt),

    XmppIq = iq_parser:proto_to_xmpp(PbIq),
    ?assertEqual(true, is_record(XmppIq, iq)),
    ?assertEqual(IqSt, XmppIq).

