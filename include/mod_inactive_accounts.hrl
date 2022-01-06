%%%-------------------------------------------------------------------
%%% copyright (C) 2021, Halloapp Inc.
%%%
%%% macros related to inactive accounts management.
%%%-------------------------------------------------------------------
-author('vipin').

-ifndef(MOD_INACTIVE_ACCOUNTS_HRL).
-define(MOD_INACTIVE_ACCOUNTS_HRL, 1).

%% Designate account inactive if last activity 245 days (approximately 8 months) ago.
-define(NUM_INACTIVITY_DAYS, 245).

%% We are ok with deletion of 1% of inactive accounts every week.
-define(ACCEPTABLE_FRACTION, 0.018).

-endif.
