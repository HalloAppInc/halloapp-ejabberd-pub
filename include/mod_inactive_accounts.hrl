%%%-------------------------------------------------------------------
%%% copyright (C) 2021, Halloapp Inc.
%%%
%%% macros related to inactive accounts management.
%%%-------------------------------------------------------------------
-author('vipin').


%% Designate account inactive if last activity 185 days (approximately 6 months) ago.
-define(NUM_INACTIVITY_DAYS, 185).

%% We are ok with deletion of 1% of inactive accounts every week.
-define(ACCEPTABLE_FRACTION, 0.015).

