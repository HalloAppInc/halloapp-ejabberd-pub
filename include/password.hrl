%%%-------------------------------------------------------------------
%%% @author nikola
%%% @copyright (C) 2020, HalloApp, Inc.
%%% @doc
%%%
%%% @end
%%% Created : 15. Apr 2020 3:59 PM
%%%-------------------------------------------------------------------
-author("nikola").

-record(password, {
    uid :: binary(),
    hashed_password :: binary(),
    salt :: binary(),
    ts_ms :: integer()
}).

-type password() :: #password{}.