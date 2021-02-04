%%%-------------------------------------------------------------------
%%% File: props_parser_tests.erl
%%% Copyright (C) 2020, Halloapp Inc.
%%%
%%%-------------------------------------------------------------------

-module(props_parser_tests).
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


prop_xmpp_to_proto_test() ->
    setup(),

    PbProp1 = struct_util:create_pb_prop(?PROP1_NAME, ?PROP1_VALUE_BIN),
    PbProp2 = struct_util:create_pb_prop(?PROP2_NAME, ?PROP2_VALUE_BIN),
    PbProps = struct_util:create_pb_props(?HASH1, [PbProp1, PbProp2]),
    PbIq = struct_util:create_pb_iq(?ID1, result, PbProps),

    IqSt = struct_util:create_iq_stanza(?ID1, undefined, undefined, result, PbProps),

    ProtoIq = iq_parser:xmpp_to_proto(IqSt),
    ?assertEqual(true, is_record(ProtoIq, pb_iq)),
    ?assertEqual(PbIq, ProtoIq).


prop_get_proto_to_xmpp_test() ->
    setup(),

    PbProps = struct_util:create_pb_props(<<>>, []),
    PbIq = struct_util:create_pb_iq(?ID1, get, PbProps),

    IqSt = struct_util:create_iq_stanza(?ID1, undefined, undefined, get, PbProps),

    XmppIq = iq_parser:proto_to_xmpp(PbIq),
    ?assertEqual(true, is_record(XmppIq, iq)),
    ?assertEqual(IqSt, XmppIq).

