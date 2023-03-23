%%%-------------------------------------------------------------------
%%% copyright (C) 2020, Halloapp Inc.
%%%
%%% macros related to client_version
%%%-------------------------------------------------------------------
-author('murali').

-include("time.hrl").

-ifndef(CLIENT_VERSION_HRL).
-define(CLIENT_VERSION_HRL, 1).


-define(VERSION_VALIDITY, 60 * ?DAYS).
-define(KATCHUP_VERSION_VALIDITY, 40 * ?DAYS).

-define(NUM_VERSION_SLOTS, 256).

-endif.
