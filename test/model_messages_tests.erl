%%%-------------------------------------------------------------------
%%% File: model_messages_tests.erl
%%% Copyright (C) 2020, Halloapp Inc.
%%%
%%%-------------------------------------------------------------------
-module(model_messages_tests).
-author('murali').

-include("jid.hrl").
-include("offline_message.hrl").
-include("packets.hrl").
-include_lib("eunit/include/eunit.hrl").

-define(UID1, <<"1000000000376503286">>).
-define(UID2, <<"1000000000489601473">>).
-define(UID3, <<"1000000000575738138">>).
-define(UID4, <<"1000000000739856658">>).
-define(GROUP1, <<"gRYMMwrS_H0isftYAJOlLV">>).
-define(SERVER, <<"s.halloapp.net">>).
-define(MID1, <<"a985962b-33b1">>).
-define(TYPE1, group_chat).
-define(MID2, <<"cea48bd2-c1ab">>).
-define(TYPE2, chat).
-define(MID3, <<"dae46a45-95f2">>).
-define(TYPE3, contact_list).
-define(MESSAGE1, <<"msg_1">>). % arbitrary example binary blob
-define(OFFLINE_MESSAGE1, #offline_message{msg_id = ?MID1, to_uid = ?UID1, from_uid = undefined,
        content_type = ?TYPE1, retry_count = 1, message = ?MESSAGE1, order_id = 1, protobuf = false,
        thread_id = ?GROUP1, sent = false}).
-define(MESSAGE2, <<"msg_2">>).
-define(OFFLINE_MESSAGE2, #offline_message{msg_id = ?MID2, to_uid = ?UID1, from_uid = ?UID2,
        content_type = ?TYPE2, retry_count = 1, message = ?MESSAGE2, order_id = 2, protobuf = false,
        sent = false}).
-define(MESSAGE3, <<"msg_3">>).
-define(OFFLINE_MESSAGE3, #offline_message{msg_id = ?MID3, to_uid = ?UID2, from_uid = undefined,
        content_type = ?TYPE3, retry_count = 1, message = ?MESSAGE3, order_id = 1, protobuf = false,
        sent = false}).
-define(MESSAGE4, <<"msg_4">>).
-define(OFFLINE_MESSAGE4, #offline_message{msg_id = ?MID2, to_uid = ?UID1, from_uid = ?UID2,
        content_type = ?TYPE2, retry_count = 1, message = ?MESSAGE4, order_id = 3, protobuf = false,
        sent = false}).
-define(MESSAGE5, <<"msg_5">>).
-define(OFFLINE_MESSAGE5, #offline_message{msg_id = ?MID1, to_uid = ?UID1, from_uid = undefined,
        content_type = ?TYPE1, retry_count = 1, message = ?MESSAGE5, order_id = 4, protobuf = false,
        thread_id = ?GROUP1, sent = false}).
-define(EMPTY_OFFLINE_MESSAGE, undefined).



setup() ->
    tutil:setup(),
    ha_redis:start(),
    tutil:load_protobuf(),
    stringprep:start(),
    clear(),
    ok.


clear() ->
    tutil:cleardb(redis_messages).


keys_test() ->
    setup(),
    ?assertEqual(<<"msg:{1}:qwerty">>, model_messages:message_key(<<"1">>, <<"qwerty">>)),
    ?assertEqual(<<"wmsg:{1}:qwerty">>, model_messages:withhold_message_key(<<"1">>, <<"qwerty">>)),
    ?assertEqual(<<"mq:{1}">>, model_messages:message_queue_key(<<"1">>)),
    ?assertEqual(<<"ord:{1}">>, model_messages:message_order_key(<<"1">>)).


store_message_test() ->
    setup(),
    ?assertEqual({ok, ?EMPTY_OFFLINE_MESSAGE}, model_messages:get_message(?UID1, ?MID1)),
    ?assertEqual(ok, model_messages:store_message(?UID1, undefined, ?MID1, ?TYPE1, ?GROUP1, ?MESSAGE1)),
    ?assertEqual({ok, ?OFFLINE_MESSAGE1}, model_messages:get_message(?UID1, ?MID1)),

    %% make sure the function is idempotent.
    ?assertEqual(ok, model_messages:store_message(?UID1, undefined, ?MID1, ?TYPE1, ?GROUP1, ?MESSAGE1)),
    ?assertEqual({ok, ?OFFLINE_MESSAGE1}, model_messages:get_message(?UID1, ?MID1)),

    ?assertEqual(ok, model_messages:store_message(?UID1, ?UID2, ?MID2, ?TYPE2, undefined, ?MESSAGE2)),
    ?assertEqual({ok, ?OFFLINE_MESSAGE2}, model_messages:get_message(?UID1, ?MID2)),
    ?assertEqual({ok,[?OFFLINE_MESSAGE1, ?OFFLINE_MESSAGE2]},
            model_messages:get_all_user_messages(?UID1)),

    ?assertEqual(ok, model_messages:store_message(?UID2, undefined, ?MID3, ?TYPE3, undefined, ?MESSAGE3)),
    ?assertEqual({ok, ?OFFLINE_MESSAGE3}, model_messages:get_message(?UID2, ?MID3)).


store_message_pb_test() ->
    setup(),
    SeenReceipt = struct_util:create_pb_seen_receipt(?MID1, ?UID2, 123),
    Msg = struct_util:create_pb_message(?MID1, ?UID4, ?UID2, normal, SeenReceipt),
    ?assertEqual({ok, ?EMPTY_OFFLINE_MESSAGE}, model_messages:get_message(?UID4, ?MID1)),

    MsgBin = enif_protobuf:encode(Msg),
    ?assertEqual(ok, model_messages:store_message(?UID4, ?UID2, ?MID1, pb_seen_receipt, undefined, MsgBin, true)),
    {ok, ActualOfflineMessage} = model_messages:get_message(?UID4, ?MID1),

    ExpectedOfflineMessage = #offline_message{
        msg_id = ?MID1,
        to_uid = ?UID4,
        from_uid = ?UID2,
        content_type = pb_seen_receipt,
        retry_count = 1,
        message = enif_protobuf:encode(Msg),
        order_id = 1,
        protobuf = true,
        sent = false
    },
    ?assertEqual(ExpectedOfflineMessage, ActualOfflineMessage).


message_order_test() ->
    setup(),
    ?assertEqual(ok, model_messages:remove_all_user_messages(?UID1)),
    ?assertEqual(ok, model_messages:store_message(?UID1, undefined, ?MID1, ?TYPE1, ?GROUP1, ?MESSAGE1)),
    ?assertEqual(ok, model_messages:store_message(?UID1, ?UID2, ?MID2, ?TYPE2, undefined, ?MESSAGE2)),
    ?assertEqual({ok, [?OFFLINE_MESSAGE1, ?OFFLINE_MESSAGE2]},
            model_messages:get_all_user_messages(?UID1)),
    ?assertEqual(ok, model_messages:remove_all_user_messages(?UID1)),

    ?assertEqual(ok, model_messages:store_message(?UID1, ?UID2, ?MID2, ?TYPE2, undefined, ?MESSAGE4)),
    ?assertEqual(ok, model_messages:store_message(?UID1, undefined, ?MID1, ?TYPE1, ?GROUP1, ?MESSAGE5)),
    ?assertEqual({ok, [?OFFLINE_MESSAGE4, ?OFFLINE_MESSAGE5]},
            model_messages:get_all_user_messages(?UID1)).


% Offline queue limit is 100 for testing environments.
max_num_offline_messages_test() ->
    setup(),
    ?assertEqual(ok, model_messages:remove_all_user_messages(?UID1)),
    ?assertEqual({ok, 0}, model_messages:count_user_messages(?UID1)),
    N = 200,
    util:rev_while(N,
        fun(X) ->
            Xbin = util:to_binary(X),
            MsgId = <<?MID1/binary, "-", Xbin/binary>>,
            ?assertEqual(ok, model_messages:store_message(?UID1, undefined, MsgId, ?TYPE1, ?GROUP1, ?MESSAGE1))
        end),
    ?assertEqual({ok, 200}, model_messages:count_user_messages(?UID1)),

    %% Insert 101th message.
    MsgId2 = <<?MID1/binary, "-201">>,
    %% This should be overflow??
    ?assertEqual({ok, overflow}, model_messages:store_message(?UID1, undefined, MsgId2, ?TYPE1, ?GROUP1, ?MESSAGE1)),
    ?assertEqual({ok, 200}, model_messages:count_user_messages(?UID1)),
    ?assertEqual({ok, true}, model_messages:is_queue_trimmed(?UID1)),

    %% Count should still be 100.
    ?assertEqual({ok, 200}, model_messages:count_user_messages(?UID1)),

    %% Ack the missing message.
    MsgId3 = <<?MID1/binary, <<"-200">>/binary>>,
    ?assertEqual(ok, model_messages:ack_message(?UID1, MsgId3)),
    %% Count should still be 100.
    ?assertEqual({ok, 200}, model_messages:count_user_messages(?UID1)),

    %% Ack message 99.
    MsgId4 = <<?MID1/binary, <<"-199">>/binary>>,
    ?assertEqual(ok, model_messages:ack_message(?UID1, MsgId4)),
    %% Count should now be 99.
    ?assertEqual({ok, 199}, model_messages:count_user_messages(?UID1)),
    ok.


ack_message_test() ->
    setup(),
    ?assertEqual(ok, model_messages:store_message(?UID1, undefined, ?MID1, ?TYPE1, ?GROUP1, ?MESSAGE1)),
    ?assertEqual({ok, ?OFFLINE_MESSAGE1}, model_messages:get_message(?UID1, ?MID1)),

    ?assertEqual(ok, model_messages:ack_message(?UID1, ?MID1)),
    ?assertEqual({ok, ?EMPTY_OFFLINE_MESSAGE}, model_messages:get_message(?UID1, ?MID1)),
    ?assertEqual({ok, []}, model_messages:get_all_user_messages(?UID1)).


starve_message_test() ->
    setup(),
    ?assertEqual({error,<<"ERR no such key">>}, model_messages:withhold_message(?UID1, ?MID1)),

    ?assertEqual(ok, model_messages:store_message(?UID1, undefined, ?MID1, ?TYPE1, ?GROUP1, ?MESSAGE1)),
    ?assertEqual({ok, ?OFFLINE_MESSAGE1}, model_messages:get_message(?UID1, ?MID1)),

    ?assertEqual(ok, model_messages:withhold_message(?UID1, ?MID1)),
    ?assertEqual({ok, ?EMPTY_OFFLINE_MESSAGE}, model_messages:get_message(?UID1, ?MID1)),
    ?assertEqual({ok, []}, model_messages:get_all_user_messages(?UID1)).


ack_out_of_order_test() ->
    setup(),
    ?assertEqual(ok, model_messages:store_message(?UID1, undefined, ?MID1, ?TYPE1, ?GROUP1, ?MESSAGE1)),
    ?assertEqual(ok, model_messages:store_message(?UID1, ?UID2, ?MID2, ?TYPE2, undefined, ?MESSAGE2)),
    ?assertEqual({ok, [?OFFLINE_MESSAGE1, ?OFFLINE_MESSAGE2]},
            model_messages:get_all_user_messages(?UID1)),
    ?assertEqual(ok, model_messages:ack_message(?UID1, ?MID2)),

    ?assertEqual({ok, [?OFFLINE_MESSAGE1]}, model_messages:get_all_user_messages(?UID1)),
    ?assertEqual(ok, model_messages:ack_message(?UID1, ?MID1)),
    ?assertEqual({ok, []}, model_messages:get_all_user_messages(?UID1)).


remove_all_user_messages_test() ->
    setup(),
    ?assertEqual({ok, 0}, model_messages:count_user_messages(?UID1)),
    ?assertEqual(ok, model_messages:store_message(?UID1, undefined, ?MID1, ?TYPE1, ?GROUP1, ?MESSAGE1)),
    ?assertEqual({ok, ?OFFLINE_MESSAGE1}, model_messages:get_message(?UID1, ?MID1)),

    ?assertEqual(ok, model_messages:store_message(?UID1, ?UID2, ?MID2, ?TYPE2, undefined, ?MESSAGE2)),
    ?assertEqual({ok, ?OFFLINE_MESSAGE2}, model_messages:get_message(?UID1, ?MID2)),

    ?assertEqual({ok, [?OFFLINE_MESSAGE1, ?OFFLINE_MESSAGE2]},
            model_messages:get_all_user_messages(?UID1)),
    ?assertEqual(ok, model_messages:remove_all_user_messages(?UID1)),
    ?assertEqual({ok, ?EMPTY_OFFLINE_MESSAGE}, model_messages:get_message(?UID1, ?MID1)),
    ?assertEqual({ok, ?EMPTY_OFFLINE_MESSAGE}, model_messages:get_message(?UID1, ?MID2)),
    ?assertEqual({ok, []}, model_messages:get_all_user_messages(?UID1)).


count_user_messages_test() ->
    setup(),
    ?assertEqual({ok, 0}, model_messages:count_user_messages(?UID1)),
    ?assertEqual({ok, 0}, model_messages:count_user_messages(?UID2)),
    ?assertEqual(ok, model_messages:store_message(?UID1, undefined, ?MID1, ?TYPE1, undefined, ?MESSAGE1)),
    ?assertEqual({ok, 1}, model_messages:count_user_messages(?UID1)),

    ?assertEqual(ok, model_messages:store_message(?UID1, ?UID2, ?MID2, ?TYPE2, undefined, ?MESSAGE2)),
    ?assertEqual({ok, 2}, model_messages:count_user_messages(?UID1)),

    ?assertEqual(ok, model_messages:ack_message(?UID1, ?MID1)),
    ?assertEqual({ok, 1}, model_messages:count_user_messages(?UID1)),

    ?assertEqual(ok, model_messages:ack_message(?UID1, ?MID2)),
    ?assertEqual({ok, 0}, model_messages:count_user_messages(?UID1)).


retry_counts_is_1_test() ->
    setup(),
    ?assertEqual({ok, undefined}, model_messages:get_retry_count(?UID1, ?MID1)),
    ?assertEqual(ok, model_messages:store_message(?UID1, undefined, ?MID1, ?TYPE1, undefined, ?MESSAGE1)),
    ?assertEqual({ok, 1}, model_messages:get_retry_count(?UID1, ?MID1)).


retry_count_test() ->
    setup(),
    ?assertEqual({ok, undefined}, model_messages:get_retry_count(?UID1, ?MID1)),
    ?assertEqual(ok, model_messages:store_message(?UID1, undefined, ?MID1, ?TYPE1, undefined, ?MESSAGE1)),
    ?assertEqual({ok, 2}, model_messages:mark_sent_and_increment_retry_count(?UID1, ?MID1)),
    ?assertEqual({ok, 3}, model_messages:mark_sent_and_increment_retry_count(?UID1, ?MID1)).


increment_retry_counts_test() ->
    setup(),
    ?assertEqual(ok, model_messages:store_message(?UID1, undefined, ?MID1, ?TYPE1, undefined, ?MESSAGE1)),
    ?assertEqual(ok, model_messages:store_message(?UID1, undefined, ?MID2, ?TYPE2, undefined, ?MESSAGE2)),
    ok = model_messages:mark_sent_and_increment_retry_counts(?UID1, [?MID1, ?MID2]),
    ?assertEqual({ok, 2}, model_messages:get_retry_count(?UID1, ?MID1)),
    ?assertEqual({ok, 2}, model_messages:get_retry_count(?UID1, ?MID2)).


push_sent_test() ->
    setup(),
    ?assert(model_messages:record_push_sent(?UID1, ?MID1)),
    ?assertNot(model_messages:record_push_sent(?UID1, ?MID1)).


get_user_messages_test() ->
    setup(),
    ?assertEqual(ok, model_messages:remove_all_user_messages(?UID1)),
    ?assertEqual(ok, model_messages:store_message(?UID1, undefined, ?MID1, ?TYPE1, ?GROUP1, ?MESSAGE1)),
    ?assertEqual(ok, model_messages:store_message(?UID1, ?UID2, ?MID2, ?TYPE2, undefined, ?MESSAGE2)),
    ?assertEqual({ok, false, [?OFFLINE_MESSAGE1]},

            model_messages:get_user_messages(?UID1, 1, 1)),
    ?assertEqual({ok, false, [?OFFLINE_MESSAGE1, ?OFFLINE_MESSAGE2]},
            model_messages:get_user_messages(?UID1, 1, 2)),
    ?assertEqual({ok, true, [?OFFLINE_MESSAGE1, ?OFFLINE_MESSAGE2]},
            model_messages:get_user_messages(?UID1, 1, undefined)),
    ?assertEqual({ok, true, [?OFFLINE_MESSAGE2]},
            model_messages:get_user_messages(?UID1, 2, undefined)),
    ?assertEqual(ok, model_messages:remove_all_user_messages(?UID1)),

    ?assertEqual(ok, model_messages:store_message(?UID1, ?UID2, ?MID2, ?TYPE2, undefined, ?MESSAGE4)),
    ?assertEqual(ok, model_messages:store_message(?UID1, undefined, ?MID1, ?TYPE1, ?GROUP1, ?MESSAGE5)),
    ?assertEqual({ok, true, [?OFFLINE_MESSAGE4, ?OFFLINE_MESSAGE5]},
            model_messages:get_user_messages(?UID1, 1, undefined)),
    ?assertEqual({ok, false, [?OFFLINE_MESSAGE4]},
            model_messages:get_user_messages(?UID1, 3, 1)),
    ?assertEqual({ok, true, [?OFFLINE_MESSAGE4, ?OFFLINE_MESSAGE5]},
            model_messages:get_user_messages(?UID1, 3, undefined)),
    ?assertEqual({ok, true, []},
            model_messages:get_user_messages(?UID1, 5, undefined)).

