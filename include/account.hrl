%%%-------------------------------------------------------------------
%%% @author nikola
%%% @copyright (C) 2020, HalloApp, Inc.
%%% @doc
%%%
%%% @end
%%% Created : 13. Apr 2020 2:52 PM
%%%-------------------------------------------------------------------
-author("nikola").

-include("ha_types.hrl").

-record(account,
{
    uid :: binary(),
    phone :: binary(),
    name :: binary(),
    creation_ts_ms :: integer(),
    signup_user_agent :: binary(),
    last_activity_ts_ms :: integer() | undefined,
    activity_status :: activity_status() | undefined
}).

-type account() :: #account{}.

-type(activity_status() :: available | away).

%% TODO(murali@): rename this record after transition to redis.
-record(activity,
{
	uid :: binary(),
	last_activity_ts_ms :: integer() | undefined,
	status :: activity_status() | undefined
}).

-type activity() :: #activity{}.

-record(push_info,
{
    uid :: binary(),
    os :: binary(),
    token :: binary(),
    timestamp_ms :: integer(),
    post_pref :: maybe(boolean()),
    comment_pref :: maybe(boolean())
}).

-type push_info() :: #push_info{}.

-define(MAX_NAME_SIZE, 25).
