%%%-------------------------------------------------------------------
%%% File: packets.hrl
%%% Copyright (C) 2020, Halloapp Inc.
%%%
%%%-------------------------------------------------------------------

-include("server.hrl").

-ifndef(PACKETS_H).
-define(PACKETS_H, 1).

-type iq() :: pb_iq().
-type message() :: pb_msg().
-type ack() :: pb_ack().
-type chat_state() :: pb_chat_state().
-type presence() :: pb_presence().


-endif.
