%%%-------------------------------------------------------------------
%%% File: model_cluster_tests.erl
%%% Copyright (C) 2021, Halloapp Inc.
%%%
%%%-------------------------------------------------------------------
-module(model_cluster_tests).
-author("nikola").

-include_lib("eunit/include/eunit.hrl").

-define(NODE1, 'node1').
-define(NODE2, 'node2').


setup() ->
    tutil:setup(),
    ha_redis:start(),
    clear(),
    ok.


clear() ->
    tutil:cleardb(redis_sessions).


keys_test() ->
    ?assertEqual(
        <<"cluster_nodes:">>,
        model_cluster:cluster_key()),
    ok.

get_nodes_test() ->
    setup(),
    ?assertEqual([], model_cluster:get_nodes()),
    ?assertEqual(true, model_cluster:add_node(?NODE1)),
    ?assertEqual([?NODE1], model_cluster:get_nodes()),
    ?assertEqual(true, model_cluster:add_node(?NODE2)),
    ?assertEqual([?NODE1, ?NODE2], lists:sort(model_cluster:get_nodes())),
    ok.

add_remove_test() ->
    setup(),
    ?assertEqual([], model_cluster:get_nodes()),
    ?assertEqual(true, model_cluster:add_node(?NODE1)),
    % second add returns false
    ?assertEqual(false, model_cluster:add_node(?NODE1)),
    ?assertEqual([?NODE1], model_cluster:get_nodes()),

    ?assertEqual(true, model_cluster:add_node(?NODE2)),
    ?assertEqual([?NODE1, ?NODE2], lists:sort(model_cluster:get_nodes())),

    ?assertEqual(true, model_cluster:remove_node(?NODE1)),
    ?assertEqual([?NODE2], model_cluster:get_nodes()),

    ?assertEqual(true, model_cluster:remove_node(?NODE2)),
    ?assertEqual(false, model_cluster:remove_node(?NODE2)),
    ?assertEqual([], model_cluster:get_nodes()),

    ok.

