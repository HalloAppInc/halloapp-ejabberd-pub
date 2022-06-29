%%%-------------------------------------------------------------------
%%% File: model_gw_score_tests.erl
%%% Copyright (C) 2020, Halloapp Inc.
%%%
%%%-------------------------------------------------------------------
-module(model_gw_score_tests).
-author("luke").

-include_lib("eunit/include/eunit.hrl").
-include("sms.hrl").

-define(METRIC1, gw1_US).
-define(METRIC2, gw1).

-define(SCORE1, 75).
-define(SCORE2, 50).
-define(SCORE3, 33).
-define(SCORE0, 0).
-define(COUNT1, 300).
-define(COUNT2, 500).


store_get_score_test() ->
    setup(),
    ?assertEqual({ok, undefined}, model_gw_score:get_recent_score(?METRIC1)),
    ?assertEqual({ok, undefined}, model_gw_score:get_aggregate_score(?METRIC1)),
    ?assertEqual({ok, undefined}, model_gw_score:get_recent_score(?METRIC2)),
    ?assertEqual({ok, undefined}, model_gw_score:get_aggregate_score(?METRIC2)),
    
    model_gw_score:store_score(?METRIC1, ?SCORE1, ?SCORE2),
    ?assertEqual({ok, ?SCORE1}, model_gw_score:get_recent_score(?METRIC1)),
    ?assertEqual({ok, ?SCORE2}, model_gw_score:get_aggregate_score(?METRIC1)),
    model_gw_score:store_score(?METRIC1, ?SCORE1, ?SCORE2, ?COUNT1),
    ?assertEqual({ok, ?SCORE1}, model_gw_score:get_recent_score(?METRIC1, test)),
    ?assertEqual({ok, ?SCORE2}, model_gw_score:get_aggregate_score(?METRIC1, test)),
    ?assertEqual({ok, ?COUNT1}, model_gw_score:get_aggregate_count(?METRIC1)),
    model_gw_score:store_score(?METRIC2, undefined, undefined),
    ?assertEqual({ok, undefined}, model_gw_score:get_recent_score(?METRIC2)),
    ?assertEqual({ok, undefined}, model_gw_score:get_aggregate_score(?METRIC2)),
    model_gw_score:store_score(?METRIC2, undefined, undefined, undefined),
    ?assertEqual({ok, undefined}, model_gw_score:get_recent_score(?METRIC2, test)),
    ?assertEqual({ok, undefined}, model_gw_score:get_aggregate_score(?METRIC2, test)),
    ?assertEqual({ok, undefined}, model_gw_score:get_aggregate_count(?METRIC2)),
    ok.

get_timestamp_score_test() ->
    TS1 = model_gw_score:store_score(?METRIC1, ?SCORE1, ?SCORE2),

    ?assertEqual({ok, ?SCORE1}, model_gw_score:get_recent_score(?METRIC1)),
    ?assertEqual({ok, ?SCORE2}, model_gw_score:get_aggregate_score(?METRIC1)),

    timer:sleep(timer:seconds(?SMS_REG_TIMESTAMP_INCREMENT)),
    TS2 = model_gw_score:store_score(?METRIC1, ?SCORE0, ?SCORE3),

    ?assertEqual({ok, ?SCORE0}, model_gw_score:get_recent_score(?METRIC1)),
    ?assertEqual({ok, ?SCORE3}, model_gw_score:get_aggregate_score(?METRIC1)),

    % ?debugFmt("Trying score:{~p}:~p", [?METRIC1, TS1]),
    ?assertEqual({ok, ?SCORE1, ?SCORE2}, model_gw_score:get_old_scores(?METRIC1, TS1)),
    ?assertEqual({ok, ?SCORE0, ?SCORE3}, model_gw_score:get_old_scores(?METRIC1, TS2)),

    ok.


%%===========================================================================
%% Internal Functions
%%===========================================================================

setup() ->
    tutil:setup(),
    ha_redis:start(),
    clear(),
    ok.


clear() ->
    tutil:cleardb(redis_phone).



