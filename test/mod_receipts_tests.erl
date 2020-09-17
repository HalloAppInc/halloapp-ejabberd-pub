%%%-------------------------------------------------------------------
%%% File: model_phone_tests.erl
%%% Copyright (C) 2020, Halloapp Inc.
%%%
%%%-------------------------------------------------------------------
-module(mod_receipts_tests).
-author("nikola").

-include("xmpp.hrl").
-include("offline_message.hrl").

-include_lib("eunit/include/eunit.hrl").

-define(ID1, <<"msgid1">>).
-define(ID2, <<"msgid2">>).

-define(GID1, <<"g1">>).

-define(UID1, <<"1">>).
-define(UID2, <<"2">>).
-define(TS1, <<"15000000000">>).
-define(TS2, <<"16000000000">>).
-define(SERVER, <<"s.halloapp.net">>).


setup() ->
    xmpp:start(undefined, undefined),
    stringprep:start(),
    ejabberd_hooks:start_link(),
    mod_redis:start(undefined, []),
    clear(),
    ok.

clear() ->
    {ok, ok} = gen_server:call(redis_messages_client, flushdb).


make_ack(Id, FromUid, Ts) ->
    #ack{
        id = Id,
        from = jid:make(FromUid, ?SERVER),
        to = jid:make(?SERVER),
        timestamp = Ts
    }.


make_msg(Id, FromUid, ToUid, SubEl) ->
    #message{
        id = Id,
        from = jid:make(FromUid, ?SERVER),
        to = jid:make(ToUid, ?SERVER),
        sub_els = [SubEl]
    }.


make_group_msg(Id, FromUid, ToUid, Gid, Ts) ->
    SubEl = #group_chat{
        gid = Gid,
        timestamp = Ts,
        sender = FromUid,
        xmlns = <<"halloapp:groups">>},
    make_msg(Id, FromUid, ToUid, SubEl).


make_chat_msg(Id, FromUid, ToUid, Ts) ->
    SubEl = #chat{
        xmlns = <<"halloapp:chat:messages">>,
        timestamp = Ts
    },
    make_msg(Id, FromUid, ToUid, SubEl).


make_offline_msg(Msg) ->
    ContentType = model_messages:get_content_type(Msg),
    FromUid = Msg#message.from#jid.user,
    ToUid = Msg#message.to#jid.user,
    MsgBin = fxml:element_to_binary(xmpp:encode(Msg)),
    #offline_message{
        from_uid = FromUid,
        to_uid = ToUid,
        content_type = ContentType,
        message = MsgBin
    }.


make_receipt(Id, FromUid, ToUid, ThreadId, Ts) ->
    #message{
        from = jid:make(FromUid, ?SERVER),
        to = jid:make(ToUid, ?SERVER),
        sub_els = [#receipt_response{
            id = Id,
            thread_id = ThreadId,
            timestamp = Ts
        }]
    }.


mod_receipts_load_test() ->
    setup(),
    Options = mod_receipts:mod_options(?SERVER),
    mod_receipts:depends(?SERVER, Options),
    mod_receipts:start(?SERVER, Options),
    mod_receipts:reload(?SERVER, Options, Options),
    mod_receipts:stop(?SERVER),
    ok.


encode_decode_test() ->
    setup(),
    Msg = <<"<message to='1@s.halloapp.net' from='2@s.halloapp.net' id='msgid1' xmlns='jabber:client'><chat timestamp='15000000000' xmlns='halloapp:chat:messages'/></message>">>,
    El = fxml_stream:parse_element(Msg),
    Packet = xmpp:decode(El),
    El2 = xmpp:encode(Packet),
    Msg2 = fxml:element_to_binary(El2),
    ?assertEqual(Msg, Msg2),
    ok.


send_1on1_delivery_receipt_test() ->
    setup(),
    % msg from UID2 to UID1
    OfflineMsg = make_offline_msg(make_chat_msg(?ID1, ?UID2, ?UID1, ?TS1)),
    % UID1 acks the message
    Ack = make_ack(?ID1, ?UID1, ?TS2),

    meck:new(ejabberd_router),
    meck:expect(ejabberd_router, route,
        fun(Packet) ->
            [#receipt_response{timestamp = Ts}] = Packet#message.sub_els,
            ExpectedReceipt = make_receipt(?ID1, ?UID1, ?UID2, <<>>, Ts),
            ?assertEqual(ExpectedReceipt#message.to, Packet#message.to),
            ?assertEqual(ExpectedReceipt#message.from, Packet#message.from),
            ?assertEqual(ExpectedReceipt#message.sub_els, Packet#message.sub_els),
            ok
        end),

    mod_receipts:user_ack_packet(Ack, OfflineMsg),
    meck:validate(ejabberd_router),
    meck:unload(ejabberd_router),
    ok.


send_group_delivery_receipt_test() ->
    setup(),
    % group msg from UID2 to UID1
    OfflineMsg = make_offline_msg(make_group_msg(?ID1, ?UID2, ?UID1, ?GID1, ?TS1)),
    % UID1 acks the group message
    Ack = make_ack(?ID1, ?UID1, ?TS2),

    meck:new(ejabberd_router),
    meck:expect(ejabberd_router, route,
        fun(Packet) ->
            [#receipt_response{timestamp = Ts}] = Packet#message.sub_els,
            ExpectedReceipt = make_receipt(?ID1, ?UID1, ?UID2, ?GID1, Ts),
            ?assertEqual(ExpectedReceipt#message.to, Packet#message.to),
            ?assertEqual(ExpectedReceipt#message.from, Packet#message.from),
            ?assertEqual(ExpectedReceipt#message.sub_els, Packet#message.sub_els),
            ok
        end),

    mod_receipts:user_ack_packet(Ack, OfflineMsg),
    meck:validate(ejabberd_router),
    meck:unload(ejabberd_router),
    ok.

