%%%=============================================================================
 %%% File: statscalc.erl
 %%% @author thomas
 %%% @copyright (C) 2022, Halloapp Inc.
 %%% @doc
 %%% Miscellaneous numeric statistics routines.
 %%% @end
 %%%=============================================================================
 -module(statscalc).
 -author("thomas").

 -include("statscalc.hrl").

 -export([
     is_statistically_worse/2
 ]).

 -ifdef(TEST).
 -export([
     sample_difference_std_dev/4
 ]).
 -endif.


 %% T-testing for a statistical difference in population proportions
 %% See https://online.stat.psu.edu/stat800/lesson/5/5.5
 %% Measuring the difference between proportions in standard deviations accounts for variance in samples.
 %% ?MINIMUM_T_SCORE is a cutoff chosen such that two populations with no difference will only cross it 5% of the time.

 -spec sample_difference_std_dev(Proportion1 :: float(), SampleSize1 :: float(), 
                                 Proportion2 :: float(), SampleSize2 :: float()) -> float().
 sample_difference_std_dev(Proportion1, SampleSize1, Proportion2, SampleSize2) ->
     PooledProportion = (Proportion1 * SampleSize1 + Proportion2 * SampleSize2) / (SampleSize1 + SampleSize2),
     Variance = PooledProportion * (1 - PooledProportion) * (1 / SampleSize1 + 1 / SampleSize2),
     math:sqrt(Variance) + 0.000001. % ensure we don't divide by zero

 -spec is_statistically_worse({Proportion1 :: float(), SampleSize1 :: float()}, 
                                 {Proportion2 :: float(), SampleSize2 :: float()}) -> boolean().
 is_statistically_worse({Proportion1, SampleSize1}, {Proportion2, SampleSize2}) ->
     (Proportion1 - Proportion2) / sample_difference_std_dev(Proportion1, SampleSize1, Proportion2, SampleSize2) < ?MINIMUM_T_SCORE.
