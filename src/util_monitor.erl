%%%-------------------------------------------------------------------
%%% @author josh
%%% @copyright (C) 2021, HalloApp, Inc.
%%% @doc
%%%
%%% @end
%%% Created : 29. Jun 2021 10:06 AM
%%%-------------------------------------------------------------------
-module(util_monitor).
-author("josh").

-include("logger.hrl").
-include("monitor.hrl").

-export([
    send_ack/3
]).

send_ack(_From, To, Msg) ->
    To ! Msg.

