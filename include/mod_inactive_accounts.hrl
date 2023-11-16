%%%-------------------------------------------------------------------
%%% copyright (C) 2021, Halloapp Inc.
%%%
%%% macros related to inactive accounts management.
%%%-------------------------------------------------------------------
-author('vipin').

-ifndef(MOD_INACTIVE_ACCOUNTS_HRL).
-define(MOD_INACTIVE_ACCOUNTS_HRL, 1).

%% Designate account inactive if last activity 185 days (approximately 5 months) ago.
-define(NUM_INACTIVITY_DAYS, 150).

%% We are ok with deletion of 1% of inactive accounts every week.
-define(ACCEPTABLE_FRACTION, 0.018).

%% Max number of inactive accounts to act on per redis shard.
-define(MAX_NUM_INACTIVE_PER_SHARD, 1000).

-define(MAX_TO_DELETE_ACCOUNTS, 3000).

-endif.
