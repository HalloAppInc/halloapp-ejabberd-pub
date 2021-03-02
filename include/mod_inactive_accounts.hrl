%%%-------------------------------------------------------------------
%%% copyright (C) 2021, Halloapp Inc.
%%%
%%% macros related to inactive accounts management.
%%%-------------------------------------------------------------------
-author('vipin').


%% Designate account inactive if last activity 185 days (approximately 6 months) ago.
-define(NUM_INACTIVITY_DAYS, 185).

%% Daily we are ok with 1%. Since we run once a week, hence ok with 7%.
-define(ACCEPTABLE_FRACTION, 0.07).

