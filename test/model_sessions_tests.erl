%%%-------------------------------------------------------------------
%%% File: model_sessions_tests.erl
%%% Copyright (C) 2020, Halloapp Inc.
%%%
%%%-------------------------------------------------------------------
-module(model_sessions_tests).
-author("nikola").

-include_lib("eunit/include/eunit.hrl").

-include("account_test_data.hrl").
-include("ejabberd_sm.hrl").

-define(PID1, list_to_pid("<0.1.0>")).
-define(PID2, list_to_pid("<0.2.0>")).

-define(STATIC_KEY1, <<"static_key1">>).

-define(SERVER, <<"s.halloapp.net">>).
-define(RESOURCE1, <<"android">>).
-define(RESOURCE2, <<"ios">>).


setup() ->
    tutil:setup(),
    logger:add_handler_filter(default, ?MODULE, {fun(_,_) -> stop end, nostate}),
    ha_redis:start(),
    clear(),
    ok.


clear() ->
    tutil:cleardb(redis_sessions).


keys_test() ->
    ?assertEqual(
        <<"ss:{", ?UID1/binary, "}">>,
        model_session:sessions_key(?UID1)),
    ok.

set_session_test() ->
    setup(),
    Session1 = make_session(?UID1, ?PID1, active),
    ?assertEqual(ok, model_session:set_session(?UID1, Session1)),
    Session2 = make_session(?UID1, ?PID2, active),
    ?assertEqual(ok, model_session:set_session(?UID1, Session2)),
    ok.

get_sessions_test() ->
    setup(),
    ?assertEqual([], model_session:get_sessions(?UID1)),
    Session1 = make_session(?UID1, ?PID1, active),
    ?assertEqual(ok, model_session:set_session(?UID1, Session1)),
    ?assertEqual([Session1], model_session:get_sessions(?UID1)),
    ok.

multiple_sessions_test() ->
    setup(),
    Session1 = make_session(?UID1, ?PID1, active),
    Session2 = make_session(?UID1, ?PID2, passive),
    ?assertEqual(ok, model_session:set_session(?UID1, Session1)),
    ?assertEqual(ok, model_session:set_session(?UID1, Session2)),
    ?assertEqual(lists:sort([Session1, Session2]), lists:sort(model_session:get_sessions(?UID1))),
    ok.

get_session_test() ->
    setup(),
    Session1 = make_session(?UID1, ?PID1, active),
    Session2 = make_session(?UID1, ?PID2, passive),
    ?assertEqual(ok, model_session:set_session(?UID1, Session1)),
    ?assertEqual(ok, model_session:set_session(?UID1, Session2)),
    ?assertEqual({ok, Session1}, model_session:get_session(?UID1, Session1#session.sid)),
    ?assertEqual({ok, Session2}, model_session:get_session(?UID1, Session2#session.sid)),
    ?assertEqual({error, missing}, model_session:get_session(?UID1, {erlang:timestamp(), ?PID1})),
    ok.

del_sessions_test() ->
    setup(),
    Session1 = make_session(?UID1, ?PID1, active),
    ?assertEqual([], model_session:get_sessions(?UID1)),
    ?assertEqual(ok, model_session:set_session(?UID1, Session1)),
    ?assertEqual([Session1], model_session:get_sessions(?UID1)),
    ?assertEqual(ok, model_session:del_session(?UID1, Session1)),
    ?assertEqual([], model_session:get_sessions(?UID1)),
    ok.


del_sessions2_test() ->
    setup(),
    Session1 = make_session(?UID1, ?PID1, active),
    Session2 = make_session(?UID1, ?PID2, active),
    ?assertEqual(ok, model_session:set_session(?UID1, Session1)),
    ?assertEqual(ok, model_session:set_session(?UID1, Session2)),
    ?assertEqual(lists:sort([Session1, Session2]), lists:sort(model_session:get_sessions(?UID1))),
    ?assertEqual(ok, model_session:del_session(?UID1, Session1)),
    ?assertEqual([Session2], model_session:get_sessions(?UID1)),
    ?assertEqual(ok, model_session:del_session(?UID1, Session2)),
    ?assertEqual([], model_session:get_sessions(?UID1)),
    ok.

static_key_session_test() ->
    setup(),
    Session1 = make_session(?PID1),
    Session2 = make_session(?PID2),
    ?assertEqual(ok, model_session:set_static_key_session(?STATIC_KEY1, Session1)),
    ?assertEqual(ok, model_session:set_static_key_session(?STATIC_KEY1, Session2)),
    ?assertEqual(lists:sort([Session1, Session2]),
        lists:sort(model_session:get_static_key_sessions(?STATIC_KEY1))),
    ?assertEqual(ok, model_session:del_static_key_session(?STATIC_KEY1, Session1)),
    ?assertEqual([Session2], model_session:get_static_key_sessions(?STATIC_KEY1)),
    ?assertEqual(ok, model_session:del_static_key_session(?STATIC_KEY1, Session2)),
    ?assertEqual([], model_session:get_static_key_sessions(?STATIC_KEY1)),
    ok.

make_session(Uid, Pid, Mode) ->
    #session{
        sid = {erlang:timestamp(), Pid},
        priority = undefined,
        info = [],
        us = {Uid, ?SERVER},
        usr = {Uid, ?SERVER, ?RESOURCE1},
        mode = Mode
    }.

make_session(Pid) ->
    #session{
        sid = {erlang:timestamp(), Pid}
    }.

