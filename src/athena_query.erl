%%%-------------------------------------------------------------------
%%% File: athena_query.erl
%%% copyright (C) 2021, HalloApp, Inc.
%%%
%%% Behavior module for callbacks to fetch athena queries.
%%%
%%%-------------------------------------------------------------------
-module(athena_query).
-author('murali').

-include("athena_query.hrl").

-callback get_queries() -> [athena_query()].

