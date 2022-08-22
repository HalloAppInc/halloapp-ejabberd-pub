%%%-------------------------------------------------------------------
 %%% @author thomas
 %%% @copyright (C) 2022, HalloApp
 %%% @doc
 %%% Tests for statscalc module.
 %%% @end
 %%%-------------------------------------------------------------------
 -module(statscalc_tests).
 -author("thomas").

 -include("statscalc.hrl").
 -include_lib("eunit/include/eunit.hrl").


 is_statistically_worse_test() ->
     ?assert(statscalc:is_statistically_worse({0, 10}, {1, 10})),
     ?assertNot(statscalc:is_statistically_worse({1, 10}, {0, 10})),

     ?assertNot(statscalc:is_statistically_worse({0.5, 10}, {0.6, 10})),
     ?assertNot(statscalc:is_statistically_worse({0.5, 100}, {0.6, 100})),
     ?assert(statscalc:is_statistically_worse({0.5, 200}, {0.6, 200})).

 sample_difference_std_dev_test() ->
     % should be zero plus a small amount because p_pool * (1-p_pool) is zero in both cases.
     ?assertEqual(0, trunc(statscalc:sample_difference_std_dev(0.0, 100, 0.0, 100))),
     ?assertEqual(0, trunc(statscalc:sample_difference_std_dev(1.0, 100, 1.0, 100))),


     % for pool proportion 0.5 and sample sizes 200 each we should get 
     % (0.5) * (0.5) * (1/200 + 1/200) = 1/400 as our variance, which gives us standard deviation 1/20.
     % we add a small value to make sure we never divide by zero so we check the rounded reciprocal
     ?assertEqual(20, round(1 / statscalc:sample_difference_std_dev(0.0, 200, 1.0, 200))).

