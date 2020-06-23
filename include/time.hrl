%%%-------------------------------------------------------------------
%%% @author nikola
%%% @copyright (C) 2020, Halloapp Inc.
%%% @doc
%%%
%%% @end
%%% Created : 27. May 2020 4:43 PM
%%%-------------------------------------------------------------------
-author("nikola").

-define(SECONDS, 1).
-define(SECONDS_MS, 1000).

-define(MINUTES, 60).
-define(MINUTES_MS, (60 * 1000)).

-define(HOURS, (60 * 60)).
-define(HOURS_MS, (60 * 60 * 1000)).

-define(DAYS, (24 * ?HOURS)).
-define(DAYS_MS, (24 * ?HOURS_MS)).

-define(WEEKS, (7 * ?DAYS)).
-define(WEEKS_MS, (7 * ?DAYS_MS)).
