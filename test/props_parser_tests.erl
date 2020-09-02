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


-define(PROP1_NAME, <<"groups">>).
-define(PROP1_VALUE, true).
-define(PROP1_VALUE_BIN, <<"true">>).

-define(PROP2_NAME, <<"max_group_size">>).
-define(PROP2_VALUE, 25).
-define(PROP2_VALUE_BIN, <<"25">>).

-define(ID1, <<"id1">>).


create_prop(Name, Value) ->
    #prop{
        name = Name,
        value = Value
    }.


create_pb_prop(Name, Value) ->
    #pb_prop{
        name = Name,
        value = Value
    }.


create_props(Hash, Props) ->
    #props{
        hash = Hash,
        props = Props
    }.


create_pb_props(Hash, Props) ->
    #pb_props{
        hash = Hash,
        props = Props
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


prop_xmpp_to_proto_test() ->
    setup(),

    PbProp1 = create_pb_prop(?PROP1_NAME, ?PROP1_VALUE_BIN),
    PbProp2 = create_pb_prop(?PROP2_NAME, ?PROP2_VALUE_BIN),
    PbProps = create_pb_props(<<"123">>, [PbProp1, PbProp2]),
    PbIq = create_pb_iq(?ID1, result, {props, PbProps}),

    PropSt1 = create_prop(?PROP1_NAME, ?PROP1_VALUE),
    PropSt2 = create_prop(?PROP2_NAME, ?PROP2_VALUE),
    PropsSt = create_props(<<"MTIz">>, [PropSt1, PropSt2]),
    IqSt = create_iq_stanza(?ID1, undefined, undefined, result, PropsSt),

    ProtoIq = iq_parser:xmpp_to_proto(IqSt),
    ?assertEqual(true, is_record(ProtoIq, pb_ha_iq)),
    ?assertEqual(PbIq, ProtoIq).


prop_get_proto_to_xmpp_test() ->
    setup(),

    PbProps = create_pb_props(<<>>, []),
    PbIq = create_pb_iq(?ID1, get, {props, PbProps}),

    PropsSt = create_props(<<>>, []),
    IqSt = create_iq_stanza(?ID1, undefined, undefined, get, PropsSt),

    XmppIq = iq_parser:proto_to_xmpp(PbIq),
    ?assertEqual(true, is_record(XmppIq, iq)),
    ?assertEqual(IqSt, XmppIq).

