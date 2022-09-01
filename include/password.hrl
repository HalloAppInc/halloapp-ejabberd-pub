%%%-------------------------------------------------------------------
%%% @author nikola
%%% @copyright (C) 2020, HalloApp, Inc.
%%% @doc
%%%
%%% @end
%%% Created : 15. Apr 2020 3:59 PM
%%%-------------------------------------------------------------------
-author("nikola").

-include("ha_types.hrl").

-ifndef(PASSWORD_HRL).
-define(PASSWORD_HRL, 1).


-record(password, {
    uid :: binary(),
    hashed_password :: binary(),
    salt :: binary(),
    ts_ms :: integer()
}).

-record(s_pub, {
    uid :: binary(),
    s_pub :: maybe(binary()),
    ts_ms :: integer()
}).

-type password() :: #password{}.
-type s_pub() :: #s_pub{}.

-endif.
