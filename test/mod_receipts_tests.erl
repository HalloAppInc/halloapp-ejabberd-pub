%%%-------------------------------------------------------------------
%%% File: model_phone_tests.erl
%%% Copyright (C) 2020, Halloapp Inc.
%%%
%%%-------------------------------------------------------------------
-module(mod_receipts_tests).
-author("nikola").

-include("packets.hrl").
-include("offline_message.hrl").
-define(TYPE2, <<"chat">>).

-include_lib("eunit/include/eunit.hrl").

-define(ID1, <<"msgid1">>).
-define(ID2, <<"msgid2">>).

-define(GID1, <<"g1">>).

-define(UID1, <<"1">>).
-define(UID2, <<"2">>).
-define(TS1, <<"15000000000">>).
-define(TS2, <<"16000000000">>).
-define(SERVER, <<"s.halloapp.net">>).

-define(TYPE1, chat).
-define(MESSAGE1, <<"msg_1">>). % arbitrary example binary blob
-define(THREAD_ID, <<"thread">>).

-define(OFFLINE_MESSAGE1, 
    #offline_message{
        msg_id = ?ID1, 
        to_uid = ?UID1, 
        from_uid = ?UID2, 
        content_type = ?TYPE1, 
        retry_count = 1, 
        message = ?MESSAGE1, 
        order_id = 1, 
        protobuf = false, 
        thread_id = ?THREAD_ID, 
        sent = false}).

-define(ACK1, #pb_ack{id = ?ID2, from_uid=?UID1}).


setup() ->
    tutil:setup(),
    stringprep:start(),
    ejabberd_hooks:start_link(),
    ha_redis:start(),
    clear(),
    ok.

clear() ->
    tutil:cleardb(redis_messages).

mod_receipts_load_test() ->
    setup(),
    Options = mod_receipts:mod_options(?SERVER),
    mod_receipts:depends(?SERVER, Options),
    mod_receipts:start(?SERVER, Options),
    mod_receipts:reload(?SERVER, Options, Options),
    mod_receipts:stop(?SERVER),
    ok.


send_1on1_delivery_receipt_test() ->
    setup(),
    % msg from UID2 to UID1
    OfflineMsg = ?OFFLINE_MESSAGE1,
    % UID1 acks the message
    Ack = ?ACK1,

    meck:new(ejabberd_router),
    meck:expect(ejabberd_router, route,
        fun(Packet) ->
            ?assertEqual(Packet#pb_msg.to_uid, ?UID2),
            ?assertEqual(Packet#pb_msg.from_uid, ?UID1),
            ?assertEqual(Packet#pb_msg.payload#pb_delivery_receipt.thread_id, ?THREAD_ID),
            ?assertEqual(Packet#pb_msg.payload#pb_delivery_receipt.id, ?ID2),
            ok
        end),

    mod_receipts:user_ack_packet(Ack, OfflineMsg),
    ?assertEqual(1, meck:num_calls(ejabberd_router, route, '_')),
    meck:validate(ejabberd_router),
    meck:unload(ejabberd_router),
    ok.
