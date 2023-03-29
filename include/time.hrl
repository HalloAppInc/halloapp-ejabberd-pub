%%%-------------------------------------------------------------------
%%% @author nikola
%%% @copyright (C) 2020, Halloapp Inc.
%%% @doc
%%%
%%% @end
%%% Created : 27. May 2020 4:43 PM
%%%-------------------------------------------------------------------
% -author("nikola").

-ifndef(TIME_HRL).
-define(TIME_HRL, 1).

-define(SECONDS, 1).
-define(SECONDS_MS, 1000).

-define(MINUTES, (60 * ?SECONDS)).
-define(MINUTES_MS, (60 * ?SECONDS_MS)).

-define(HOURS, (60 * ?MINUTES)).
-define(HOURS_MS, (60 * ?MINUTES_MS)).

-define(DAYS, (24 * ?HOURS)).
-define(DAYS_MS, (24 * ?HOURS_MS)).

-define(WEEKS, (7 * ?DAYS)).
-define(WEEKS_MS, (7 * ?DAYS_MS)).

-define(MONTHS, (30 * ?DAYS)).
-define(MONTHS_MS, (30 * ?DAYS_MS)).

-endif.
