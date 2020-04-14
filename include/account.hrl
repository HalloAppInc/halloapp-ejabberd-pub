%%%-------------------------------------------------------------------
%%% @author nikola
%%% @copyright (C) 2020, HalloApp, Inc.
%%% @doc
%%%
%%% @end
%%% Created : 13. Apr 2020 2:52 PM
%%%-------------------------------------------------------------------
-author("nikola").

-record(account,
{
    uid :: binary(),
    phone :: binary(),
    name :: binary(),
    creation_ts_ms :: integer(),
    signup_user_agent :: binary(),
    last_activity_ts_ms :: integer() | undefined
}).

-type account() :: #account{}.
