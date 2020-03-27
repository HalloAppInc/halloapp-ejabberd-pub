%%%-------------------------------------------------------------------
%%% @author nikola
%%% @copyright (C) 2020, Halloapp Inc.
%%% @doc
%%%
%%% @end
%%% Created : 25. Mar 2020 1:57 PM
%%%-------------------------------------------------------------------
-module(mod_redis).
-author("nikola").
-behaviour(gen_mod).

%% Required by ?INFO_MSG macros
-include("logger.hrl").

%% gen_mod API callbacks
-export([start/2, stop/1, depends/2, mod_options/1]).

start(_Host, _Opts) ->
  ?INFO_MSG("start ~w", [?MODULE]),
  redis_sup:start_link(),
  ok.

stop(_Host) ->
  ?INFO_MSG("stop ~w", [?MODULE]),
  ok.

depends(_Host, _Opts) ->
  [].

mod_options(_Host) ->
  [].
