%%%-------------------------------------------------------------------
%%% File: model_messages_tests.erl
%%% Copyright (C) 2020, Halloapp Inc.
%%%
%%%-------------------------------------------------------------------
-module(model_messages_tests).
-author("murali").

-include("xmpp.hrl").
-include_lib("eunit/include/eunit.hrl").

-define(UID1, <<"1000000000376503286">>).
-define(UID2, <<"1000000000489601473">>).
-define(UID3, <<"1000000000575738138">>).
-define(SERVER, <<"s.halloapp.net">>).
-define(MID1, <<"a985962b-33b1">>).
-define(MID2, <<"cea48bd2-c1ab">>).
-define(MID3, <<"dae46a45-95f2">>).
-define(MESSAGE1, term_to_binary(#message{id = ?MID1, to = #jid{user = ?UID1, server = ?SERVER}})).
-define(MESSAGE2, term_to_binary(#message{id = ?MID2, to = #jid{user = ?UID1, server = ?SERVER}})).
-define(MESSAGE3, term_to_binary(#message{id = ?MID3, to = #jid{user = ?UID2, server = ?SERVER}})).



setup() ->
    redis_sup:start_link(),
    clear(),
    model_messages:start_link(),
    ok.


clear() ->
    ok = gen_server:cast(redis_messages_client, flushdb).


keys_test() ->
    setup(),
    ?assertEqual(<<"msg:{1}:qwerty">>, model_messages:message_key(<<"1">>, <<"qwerty">>)),
    ?assertEqual(<<"mq:{1}">>, model_messages:message_queue_key(<<"1">>)),
    ?assertEqual(<<"ord:{1}">>, model_messages:message_order_key(<<"1">>)).


store_message_test() ->
    setup(),
    ?assertEqual({ok, undefined}, model_messages:get_message(?UID1, ?MID1)),
    ?assertEqual(ok, model_messages:store_message(?UID1, ?MID1, ?MESSAGE1)),
    ?assertEqual({ok, ?MESSAGE1}, model_messages:get_message(?UID1, ?MID1)),

    ?assertEqual(ok, model_messages:store_message(?UID1, ?MID2, ?MESSAGE2)),
    ?assertEqual({ok, ?MESSAGE2}, model_messages:get_message(?UID1, ?MID2)),
    ?assertEqual({ok, [?MESSAGE1, ?MESSAGE2]}, model_messages:get_all_user_messages(?UID1)),

    ?assertEqual(ok, model_messages:store_message(?UID2, ?MID3, ?MESSAGE3)),
    ?assertEqual({ok, ?MESSAGE3}, model_messages:get_message(?UID2, ?MID3)).


message_order_test() ->
    setup(),
    ?assertEqual(ok, model_messages:store_message(?UID1, ?MID1, ?MESSAGE1)),
    ?assertEqual(ok, model_messages:store_message(?UID1, ?MID2, ?MESSAGE2)),
    ?assertEqual({ok, [?MESSAGE1, ?MESSAGE2]}, model_messages:get_all_user_messages(?UID1)),
    ?assertEqual(ok, model_messages:remove_all_user_messages(?UID1)),

    ?assertEqual(ok, model_messages:store_message(?UID1, ?MID2, ?MESSAGE2)),
    ?assertEqual(ok, model_messages:store_message(?UID1, ?MID1, ?MESSAGE1)),
    ?assertEqual({ok, [?MESSAGE2, ?MESSAGE1]}, model_messages:get_all_user_messages(?UID1)).


ack_message_test() ->
    setup(),
    ?assertEqual(ok, model_messages:store_message(?UID1, ?MID1, ?MESSAGE1)),
    ?assertEqual({ok, ?MESSAGE1}, model_messages:get_message(?UID1, ?MID1)),

    ?assertEqual(ok, model_messages:ack_message(?UID1, ?MID1)),
    ?assertEqual({ok, undefined}, model_messages:get_message(?UID1, ?MID1)),
    ?assertEqual({ok, []}, model_messages:get_all_user_messages(?UID1)).


ack_out_of_order_test() ->
    ?assertEqual(ok, model_messages:store_message(?UID1, ?MID1, ?MESSAGE1)),
    ?assertEqual(ok, model_messages:store_message(?UID1, ?MID2, ?MESSAGE2)),
    ?assertEqual({ok, [?MESSAGE1, ?MESSAGE2]}, model_messages:get_all_user_messages(?UID1)),
    ?assertEqual(ok, model_messages:ack_message(?UID1, ?MID2)),

    ?assertEqual({ok, [?MESSAGE1]}, model_messages:get_all_user_messages(?UID1)),
    ?assertEqual(ok, model_messages:ack_message(?UID1, ?MID1)),
    ?assertEqual({ok, []}, model_messages:get_all_user_messages(?UID1)).


remove_all_user_messages_test() ->
    setup(),
    ?assertEqual({ok, 0}, model_messages:count_user_messages(?UID1)),
    ?assertEqual(ok, model_messages:store_message(?UID1, ?MID1, ?MESSAGE1)),
    ?assertEqual({ok, ?MESSAGE1}, model_messages:get_message(?UID1, ?MID1)),

    ?assertEqual(ok, model_messages:store_message(?UID1, ?MID2, ?MESSAGE2)),
    ?assertEqual({ok, ?MESSAGE2}, model_messages:get_message(?UID1, ?MID2)),

    ?assertEqual({ok, [?MESSAGE1, ?MESSAGE2]}, model_messages:get_all_user_messages(?UID1)),
    ?assertEqual(ok, model_messages:remove_all_user_messages(?UID1)),
    ?assertEqual({ok, undefined}, model_messages:get_message(?UID1, ?MID1)),
    ?assertEqual({ok, undefined}, model_messages:get_message(?UID1, ?MID2)),
    ?assertEqual({ok, []}, model_messages:get_all_user_messages(?UID1)).


count_user_messages_test() ->
    setup(),
    ?assertEqual({ok, 0}, model_messages:count_user_messages(?UID1)),
    ?assertEqual({ok, 0}, model_messages:count_user_messages(?UID2)),
    ?assertEqual(ok, model_messages:store_message(?UID1, ?MID1, ?MESSAGE1)),
    ?assertEqual({ok, 1}, model_messages:count_user_messages(?UID1)),

    ?assertEqual(ok, model_messages:store_message(?UID1, ?MID2, ?MESSAGE2)),
    ?assertEqual({ok, 2}, model_messages:count_user_messages(?UID1)),

    ?assertEqual(ok, model_messages:ack_message(?UID1, ?MID1)),
    ?assertEqual({ok, 1}, model_messages:count_user_messages(?UID1)),

    ?assertEqual(ok, model_messages:ack_message(?UID1, ?MID2)),
    ?assertEqual({ok, 0}, model_messages:count_user_messages(?UID1)).

