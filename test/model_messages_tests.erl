%%%-------------------------------------------------------------------
%%% File: model_messages_tests.erl
%%% Copyright (C) 2020, Halloapp Inc.
%%%
%%%-------------------------------------------------------------------
-module(model_messages_tests).
-author('murali').

-include("xmpp.hrl").
-include("offline_message.hrl").
-include_lib("eunit/include/eunit.hrl").

-define(UID1, <<"1000000000376503286">>).
-define(UID2, <<"1000000000489601473">>).
-define(UID3, <<"1000000000575738138">>).
-define(SERVER, <<"s.halloapp.net">>).
-define(MID1, <<"a985962b-33b1">>).
-define(TYPE1, <<>>).
-define(MID2, <<"cea48bd2-c1ab">>).
-define(TYPE2, <<"chat">>).
-define(MID3, <<"dae46a45-95f2">>).
-define(TYPE3, <<"contact_list">>).
-define(MESSAGE1, term_to_binary(#message{id = ?MID1, to = #jid{user = ?UID1, server = ?SERVER}})).
-define(OFFLINE_MESSAGE1, #offline_message{msg_id = ?MID1, to_uid = ?UID1, from_uid = undefined,
        content_type = ?TYPE1, retry_count = 1, message = ?MESSAGE1, order_id = 1}).
-define(MESSAGE2, term_to_binary(#message{id = ?MID2, to = #jid{user = ?UID1, server = ?SERVER},
        from = #jid{user = ?UID2, server = ?SERVER}})).
-define(OFFLINE_MESSAGE2, #offline_message{msg_id = ?MID2, to_uid = ?UID1, from_uid = ?UID2,
        content_type = ?TYPE2, retry_count = 1, message = ?MESSAGE2, order_id = 2}).
-define(MESSAGE3, term_to_binary(#message{id = ?MID3, to = #jid{user = ?UID2, server = ?SERVER}})).
-define(OFFLINE_MESSAGE3, #offline_message{msg_id = ?MID3, to_uid = ?UID2, from_uid = undefined,
        content_type = ?TYPE3, retry_count = 1, message = ?MESSAGE3, order_id = 1}).
-define(MESSAGE4, term_to_binary(#message{id = ?MID2, to = #jid{user = ?UID1, server = ?SERVER},
        from = #jid{user = ?UID2, server = ?SERVER}})).
-define(OFFLINE_MESSAGE4, #offline_message{msg_id = ?MID2, to_uid = ?UID1, from_uid = ?UID2,
        content_type = ?TYPE2, retry_count = 1, message = ?MESSAGE4, order_id = 3}).
-define(MESSAGE5, term_to_binary(#message{id = ?MID1, to = #jid{user = ?UID1, server = ?SERVER}})).
-define(OFFLINE_MESSAGE5, #offline_message{msg_id = ?MID1, to_uid = ?UID1, from_uid = undefined,
        content_type = ?TYPE1, retry_count = 1, message = ?MESSAGE5, order_id = 4}).
-define(EMPTY_OFFLINE_MESSAGE, undefined).



setup() ->
    tutil:setup(),
    redis_sup:start_link(),
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
    ?assertEqual(ok, model_messages:store_message(?UID1, undefined, ?MID1, ?TYPE1, ?MESSAGE1)),
    ?assertEqual({ok, ?OFFLINE_MESSAGE1}, model_messages:get_message(?UID1, ?MID1)),

    ?assertEqual(ok, model_messages:store_message(?UID1, ?UID2, ?MID2, ?TYPE2, ?MESSAGE2)),
    ?assertEqual({ok, ?OFFLINE_MESSAGE2}, model_messages:get_message(?UID1, ?MID2)),
    ?assertEqual({ok,[?OFFLINE_MESSAGE1, ?OFFLINE_MESSAGE2]},
            model_messages:get_all_user_messages(?UID1)),

    ?assertEqual(ok, model_messages:store_message(?UID2, undefined, ?MID3, ?TYPE3, ?MESSAGE3)),
    ?assertEqual({ok, ?OFFLINE_MESSAGE3}, model_messages:get_message(?UID2, ?MID3)).


message_order_test() ->
    setup(),
    ?assertEqual(ok, model_messages:remove_all_user_messages(?UID1)),
    ?assertEqual(ok, model_messages:store_message(?UID1, undefined, ?MID1, ?TYPE1, ?MESSAGE1)),
    ?assertEqual(ok, model_messages:store_message(?UID1, ?UID2, ?MID2, ?TYPE2, ?MESSAGE2)),
    ?assertEqual({ok, [?OFFLINE_MESSAGE1, ?OFFLINE_MESSAGE2]},
            model_messages:get_all_user_messages(?UID1)),
    ?assertEqual(ok, model_messages:remove_all_user_messages(?UID1)),

    ?assertEqual(ok, model_messages:store_message(?UID1, ?UID2, ?MID2, ?TYPE2, ?MESSAGE4)),
    ?assertEqual(ok, model_messages:store_message(?UID1, undefined, ?MID1, ?TYPE1, ?MESSAGE5)),
    ?assertEqual({ok, [?OFFLINE_MESSAGE4, ?OFFLINE_MESSAGE5]},
            model_messages:get_all_user_messages(?UID1)).


ack_message_test() ->
    setup(),
    ?assertEqual(ok, model_messages:store_message(?UID1, undefined, ?MID1, ?TYPE1, ?MESSAGE1)),
    ?assertEqual({ok, ?OFFLINE_MESSAGE1}, model_messages:get_message(?UID1, ?MID1)),

    ?assertEqual(ok, model_messages:ack_message(?UID1, ?MID1)),
    ?assertEqual({ok, ?EMPTY_OFFLINE_MESSAGE}, model_messages:get_message(?UID1, ?MID1)),
    ?assertEqual({ok, []}, model_messages:get_all_user_messages(?UID1)).


starve_message_test() ->
    setup(),
    ?assertEqual({error,<<"ERR no such key">>}, model_messages:withhold_message(?UID1, ?MID1)),

    ?assertEqual(ok, model_messages:store_message(?UID1, undefined, ?MID1, ?TYPE1, ?MESSAGE1)),
    ?assertEqual({ok, ?OFFLINE_MESSAGE1}, model_messages:get_message(?UID1, ?MID1)),

    ?assertEqual(ok, model_messages:withhold_message(?UID1, ?MID1)),
    ?assertEqual({ok, ?EMPTY_OFFLINE_MESSAGE}, model_messages:get_message(?UID1, ?MID1)),
    ?assertEqual({ok, []}, model_messages:get_all_user_messages(?UID1)).


ack_out_of_order_test() ->
    setup(),
    ?assertEqual(ok, model_messages:store_message(?UID1, undefined, ?MID1, ?TYPE1, ?MESSAGE1)),
    ?assertEqual(ok, model_messages:store_message(?UID1, ?UID2, ?MID2, ?TYPE2, ?MESSAGE2)),
    ?assertEqual({ok, [?OFFLINE_MESSAGE1, ?OFFLINE_MESSAGE2]},
            model_messages:get_all_user_messages(?UID1)),
    ?assertEqual(ok, model_messages:ack_message(?UID1, ?MID2)),

    ?assertEqual({ok, [?OFFLINE_MESSAGE1]}, model_messages:get_all_user_messages(?UID1)),
    ?assertEqual(ok, model_messages:ack_message(?UID1, ?MID1)),
    ?assertEqual({ok, []}, model_messages:get_all_user_messages(?UID1)).


remove_all_user_messages_test() ->
    setup(),
    ?assertEqual({ok, 0}, model_messages:count_user_messages(?UID1)),
    ?assertEqual(ok, model_messages:store_message(?UID1, undefined, ?MID1, ?TYPE1, ?MESSAGE1)),
    ?assertEqual({ok, ?OFFLINE_MESSAGE1}, model_messages:get_message(?UID1, ?MID1)),

    ?assertEqual(ok, model_messages:store_message(?UID1, ?UID2, ?MID2, ?TYPE2, ?MESSAGE2)),
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
    ?assertEqual(ok, model_messages:store_message(?UID1, undefined, ?MID1, ?TYPE1, ?MESSAGE1)),
    ?assertEqual({ok, 1}, model_messages:count_user_messages(?UID1)),

    ?assertEqual(ok, model_messages:store_message(?UID1, ?UID2, ?MID2, ?TYPE2, ?MESSAGE2)),
    ?assertEqual({ok, 2}, model_messages:count_user_messages(?UID1)),

    ?assertEqual(ok, model_messages:ack_message(?UID1, ?MID1)),
    ?assertEqual({ok, 1}, model_messages:count_user_messages(?UID1)),

    ?assertEqual(ok, model_messages:ack_message(?UID1, ?MID2)),
    ?assertEqual({ok, 0}, model_messages:count_user_messages(?UID1)).


retry_counts_is_1_test() ->
    setup(),
    ?assertEqual({ok, undefined}, model_messages:get_retry_count(?UID1, ?MID1)),
    ?assertEqual(ok, model_messages:store_message(?UID1, undefined, ?MID1, ?TYPE1, ?MESSAGE1)),
    ?assertEqual({ok, 1}, model_messages:get_retry_count(?UID1, ?MID1)).


retry_count_test() ->
    setup(),
    ?assertEqual({ok, undefined}, model_messages:get_retry_count(?UID1, ?MID1)),
    ?assertEqual(ok, model_messages:store_message(?UID1, undefined, ?MID1, ?TYPE1, ?MESSAGE1)),
    ?assertEqual({ok, 2}, model_messages:increment_retry_count(?UID1, ?MID1)),
    ?assertEqual({ok, 3}, model_messages:increment_retry_count(?UID1, ?MID1)).


increment_retry_counts_test() ->
    setup(),
    ?assertEqual(ok, model_messages:store_message(?UID1, undefined, ?MID1, ?TYPE1, ?MESSAGE1)),
    ?assertEqual(ok, model_messages:store_message(?UID1, undefined, ?MID2, ?TYPE2, ?MESSAGE2)),
    ok = model_messages:increment_retry_counts(?UID1, [?MID1, ?MID2]),
    ?assertEqual({ok, 2}, model_messages:get_retry_count(?UID1, ?MID1)),
    ?assertEqual({ok, 2}, model_messages:get_retry_count(?UID1, ?MID2)).


push_sent_test() ->
    setup(),
    ?assert(model_messages:record_push_sent(?UID1, ?MID1)),
    ?assertNot(model_messages:record_push_sent(?UID1, ?MID1)).


