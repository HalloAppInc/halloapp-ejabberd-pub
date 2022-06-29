%%%=============================================================================
%%% File: statscalc.hrl
%%% @author thomas
%%% @copyright (C) 2022, Halloapp Inc.
%%% @doc
%%% Miscellaneous statistics routines.
%%% @end
%%%=============================================================================
-ifndef(STATSCALC_HRL).
-define(STATSCALC_HRL, true).

% Computed by plugging in (20 - 2) and a cumulative probability of 0.05
% https://stattrek.com/online-calculator/t-distribution 
% If the t-score of the difference between two samples is larger than this, 
% there is at most a 5% chance that the real difference is zero.
% 20 is the minimum possible combined sample size.
% Choosing the minimum possible sample size leads to the most extreme cutoff for the t-test.
% This way we are guaranteed that no matter what sample size we have, a score below the cutoff is significant.
% (as with a higher sample size we get a less extreme cutoff and so any score below this cutoff is also below the other one)
% The degrees of freedom in a t-test between two populations is just defined as the total sample size minus 2.
% This is a more extreme t-score than needed for larger samples,
% but even with 100x more samples the score only drops to -1.64648 - less than 0.1 difference.
% See https://www.itl.nist.gov/div898/handbook/eda/section3/eda3672.htm for a t-score table
% - you can see that the values become less extreme as sample size increases.
% Also see https://www.scribbr.com/statistics/t-test/ for a general explanation of t-testing.

-define(MINIMUM_T_SCORE, -1.73438).

-endif.
