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


-define(PHONE1, <<"+14703381473">>).
-define(PHONE2, <<"+919885577163">>).
-define(SERVER, <<"s.halloapp.net">>).
-define(ID1, <<"id1">>).


create_invite(Phone, Result, Reason) ->
    #invite{
        phone = Phone,
        result = Result,
        reason = Reason
    }.


create_invites(InvitesLeft, TimeUnitRefresh, Invites) ->
    #invites{
        invites_left = InvitesLeft,
        time_until_refresh = TimeUnitRefresh,
        invites = Invites
    }.


create_pb_invite(Phone, Result, Reason) ->
    #pb_invite{
        phone = Phone,
        result = Result,
        reason = Reason
    }.

create_pb_invites_request(PbInvites) ->
    #pb_invites_request{
        invites = PbInvites
    }.

create_pb_invites_response(InvitesLeft, TimeUnitRefresh, PbInvites) ->
    #pb_invites_response{
        invites_left = InvitesLeft,
        time_until_refresh = TimeUnitRefresh,
        invites = PbInvites
    }.

create_iq_stanza(Id, ToJid, FromJid, Type, SubEl) ->
    #iq{
        id = Id,
        to = ToJid,
        from = FromJid,
        type = Type,
        sub_els = [SubEl]
    }.


create_pb_iq(Id, Type, PayloadContent) ->
    #pb_ha_iq{
        id = Id,
        type = Type,
        payload = #pb_iq_payload{
                content = PayloadContent
            }
    }.


setup() ->
    stringprep:start(),
    ok.

%% -------------------------------------------- %%
%% Tests
%% -------------------------------------------- %%


invite_xmpp_to_proto_test() ->
    setup(),

    PbInvite = create_pb_invite(?PHONE1, <<"ok">>, undefined),
    PbInvites = create_pb_invites_response(2, 100, [PbInvite]),
    PbIq = create_pb_iq(?ID1, result, {pb_invites_response, PbInvites}),

    InviteSt = create_invite(?PHONE1, ok, undefined),
    InvitesSt = create_invites(2, 100, [InviteSt]),
    IqSt = create_iq_stanza(?ID1, undefined, undefined, result, InvitesSt),

    ProtoIq = iq_parser:xmpp_to_proto(IqSt),
    ?assertEqual(true, is_record(ProtoIq, pb_ha_iq)),
    ?assertEqual(PbIq, ProtoIq).


invites_xmpp_to_proto_test() ->
    setup(),

    PbInvites = create_pb_invites_response(2, 100, []),
    PbIq = create_pb_iq(?ID1, result, {pb_invites_response, PbInvites}),

    InvitesSt = create_invites(2, 100, []),
    IqSt = create_iq_stanza(?ID1, undefined, undefined, result, InvitesSt),

    ProtoIq = iq_parser:xmpp_to_proto(IqSt),
    ?assertEqual(true, is_record(ProtoIq, pb_ha_iq)),
    ?assertEqual(PbIq, ProtoIq).


invite_error_xmpp_to_proto_test() ->
    setup(),

    PbInvite = create_pb_invite(?PHONE1, <<"failed">>, <<"invalid_number">>),
    PbInvites = create_pb_invites_response(5, 1000, [PbInvite]),
    PbIq = create_pb_iq(?ID1, result, {pb_invites_response, PbInvites}),

    InviteSt = create_invite(?PHONE1, failed, invalid_number),
    InvitesSt = create_invites(5, 1000, [InviteSt]),
    IqSt = create_iq_stanza(?ID1, undefined, undefined, result, InvitesSt),

    ProtoIq = iq_parser:xmpp_to_proto(IqSt),
    ?assertEqual(true, is_record(ProtoIq, pb_ha_iq)),
    ?assertEqual(PbIq, ProtoIq).



invite_set_proto_to_xmpp_test() ->
    setup(),

    PbInvite1 = create_pb_invite(?PHONE1, undefined, undefined),
    PbInvite2 = create_pb_invite(?PHONE2, undefined, undefined),
    PbInvites = create_pb_invites_request([PbInvite1, PbInvite2]),
    PbIq = create_pb_iq(?ID1, set, {pb_invites_request, PbInvites}),

    InviteSt1 = create_invite(?PHONE1, undefined, undefined),
    InviteSt2 = create_invite(?PHONE2, undefined, undefined),
    InvitesSt = create_invites(undefined, undefined, [InviteSt1, InviteSt2]),
    IqSt = create_iq_stanza(?ID1, undefined, undefined, set, InvitesSt),

    XmppIq = iq_parser:proto_to_xmpp(PbIq),
    ?assertEqual(true, is_record(XmppIq, iq)),
    ?assertEqual(IqSt, XmppIq).


invite_get_proto_to_xmpp_test() ->
    setup(),

    PbInvites = create_pb_invites_request([]),
    PbIq = create_pb_iq(?ID1, get, {pb_invites_request, PbInvites}),

    InvitesSt = create_invites(undefined, undefined, []),
    IqSt = create_iq_stanza(?ID1, undefined, undefined, get, InvitesSt),

    XmppIq = iq_parser:proto_to_xmpp(PbIq),
    ?assertEqual(true, is_record(XmppIq, iq)),
    ?assertEqual(IqSt, XmppIq).

