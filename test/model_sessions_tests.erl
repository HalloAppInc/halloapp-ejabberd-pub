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

-define(SERVER, <<"s.halloapp.net">>).
-define(RESOURCE1, <<"android">>).
-define(RESOURCE2, <<"ios">>).


setup() ->
    tutil:setup(),
    logger:add_handler_filter(default, ?MODULE, {fun(_,_) -> stop end, nostate}),
    redis_sup:start_link(),
    clear(),
    ok.


clear() ->
    tutil:cleardb(redis_sessions).


keys_test() ->
    ?assertEqual(
        <<"ss:{", ?UID1/binary, "}">>,
        model_session:sessions_key(?UID1)),
    ?assertEqual(
        <<"p:{", ?UID1/binary, "}">>,
        model_session:pid_key(?UID1)),
    ok.

set_session_test() ->
    setup(),
    Session1 = make_session(?UID1, ?PID1),
    ?assertEqual(undefined, model_session:set_session(?UID1, Session1)),
    Session2 = make_session(?UID1, ?PID2),
    ?assertEqual(?PID1, model_session:set_session(?UID1, Session2)),
    ok.

get_sessions_test() ->
    setup(),
    ?assertEqual([], model_session:get_sessions(?UID1)),
    Session1 = make_session(?UID1, ?PID1),
    ?assertEqual(undefined, model_session:set_session(?UID1, Session1)),
    ?assertEqual([Session1], model_session:get_sessions(?UID1)),
    ok.

multiple_sessions_test() ->
    setup(),
    Session1 = make_session(?UID1, ?PID1),
    Session2 = make_session(?UID1, ?PID2),
    ?assertEqual(undefined, model_session:set_session(?UID1, Session1)),
    ?assertEqual(?PID1, model_session:set_session(?UID1, Session2)),
    ?assertEqual(lists:sort([Session1, Session2]), lists:sort(model_session:get_sessions(?UID1))),
    ok.

del_sessions_test() ->
    setup(),
    Session1 = make_session(?UID1, ?PID1),
    ?assertEqual([], model_session:get_sessions(?UID1)),
    ?assertEqual(undefined, model_session:set_session(?UID1, Session1)),
    ?assertEqual([Session1], model_session:get_sessions(?UID1)),
    ?assertEqual(ok, model_session:del_session(?UID1, Session1)),
    ?assertEqual([], model_session:get_sessions(?UID1)),
    ok.


del_sessions2_test() ->
    setup(),
    Session1 = make_session(?UID1, ?PID1),
    Session2 = make_session(?UID1, ?PID2),
    ?assertEqual(undefined, model_session:set_session(?UID1, Session1)),
    ?assertEqual(?PID1, model_session:set_session(?UID1, Session2)),
    ?assertEqual(lists:sort([Session1, Session2]), lists:sort(model_session:get_sessions(?UID1))),
    ?assertEqual(ok, model_session:del_session(?UID1, Session1)),
    ?assertEqual([Session2], model_session:get_sessions(?UID1)),
    ?assertEqual(ok, model_session:del_session(?UID1, Session2)),
    ?assertEqual([], model_session:get_sessions(?UID1)),
    ok.

get_pid_test() ->
    setup(),
    Session1 = make_session(?UID1, ?PID1),
    Session2 = make_session(?UID1, ?PID2),
    ?assertEqual(undefined, model_session:get_pid(?UID1)),
    ?assertEqual(undefined, model_session:set_session(?UID1, Session1)),
    ?assertEqual(?PID1, model_session:get_pid(?UID1)),
    ?assertEqual(?PID1, model_session:set_session(?UID1, Session2)),
    ?assertEqual(?PID2, model_session:get_pid(?UID1)),
    ok = model_session:del_session(?UID1, Session1),
    ?assertEqual(?PID2, model_session:get_pid(?UID1)),
    ok = model_session:del_session(?UID1, Session2),
    ?assertEqual(undefined, model_session:get_pid(?UID1)),
    ok.


make_session(Uid, Pid) ->
    #session{
        sid = {erlang:timestamp(), Pid},
        priority = undefined,
        info = [],
        us = {Uid, ?SERVER},
        usr = {Uid, ?SERVER, ?RESOURCE1}
    }.

