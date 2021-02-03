%%%-------------------------------------------------------------------
%%% @author nikola
%%% @copyright (C) 2020, HalloApp, Inc.
%%% @doc
%%%
%%% @end
%%% Created : 23. Oct 2020 1:44 PM
%%%-------------------------------------------------------------------
-module(mod_ha_stats_tests).
-author("nikola").

-include_lib("eunit/include/eunit.hrl").
-define(UID1, <<"1">>).
-define(UID2, <<"2">>).
-define(SERVER, <<"server">>).

%%====================================================================
%% Tests
%%====================================================================


new_user_stat_test() ->
    {timeout, 15,
        fun() ->
            meck:new(prometheus_histogram, [merge_expects, passthrough]),
            setup(),
            mod_ha_stats:register_user(?UID1, ?SERVER, <<"">>),
            mod_ha_stats:feed_share_old_items(?UID2, ?UID1, 3, 10),
            mod_ha_stats:feed_share_old_items(?UID2, ?UID1, 1, 5),
            mod_ha_stats:log_new_user(?UID1),
            timer:sleep(10),
            {_, NumPosts} = prometheus_histogram:value(ha_new_user_initial_feed_posts),
            {_, NumComments} = prometheus_histogram:value(ha_new_user_initial_feed_comments),
            ?assertEqual(4, NumPosts),
            ?assertEqual(15, NumComments),
            ?assert(meck:validate(prometheus_histogram)),
            meck:unload(prometheus_histogram),
            ok
        end}.

new_user_stat_log_after_share_test() ->
    {timeout, 15,
        fun() ->
            meck:new(prometheus_histogram, [merge_expects, passthrough]),
            prometheus_histogram:reset(ha_new_user_initial_feed_posts),
            prometheus_histogram:reset(ha_new_user_initial_feed_comments),
            %setup(),
            mod_ha_stats:register_user(?UID1, ?SERVER, <<"">>),
            mod_ha_stats:feed_share_old_items(?UID2, ?UID1, 3, 10),
            mod_ha_stats:log_new_user(?UID1),
            % This data will not be counted since it happened after the log_new_user
            mod_ha_stats:feed_share_old_items(?UID2, ?UID1, 1, 5),
            timer:sleep(10),
            {_, NumPosts} = prometheus_histogram:value(ha_new_user_initial_feed_posts),
            {_, NumComments} = prometheus_histogram:value(ha_new_user_initial_feed_comments),
            ?assertEqual(3, NumPosts),
            ?assertEqual(10, NumComments),
            ?assert(meck:validate(prometheus_histogram)),
            meck:unload(prometheus_histogram),
            ok
        end}.

setup() ->
    application:ensure_started(prometheus),
    {ok, _Pid} = mod_ha_stats:start_link(),
    ok.

