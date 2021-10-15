%%%-------------------------------------------------------------------
%%% @author nikola
%%% @copyright (C) 2020, HalloApp, Inc.
%%% @doc
%%%
%%% @end
%%% Created : 13. Apr 2020 2:52 PM
%%%-------------------------------------------------------------------
-author("nikola").

-ifndef(ACCOUNT_HRL).
-define(ACCOUNT_HRL, 1).

-include("ha_types.hrl").

-record(account,
{
    uid :: binary(),
    phone :: binary(),
    name :: binary(),
    creation_ts_ms :: integer(),
    signup_user_agent :: binary(),
    client_version :: binary(),
    last_activity_ts_ms :: integer() | undefined,
    activity_status :: activity_status() | undefined,
    lang_id :: binary() | undefined,
    device :: binary() | undefined,
    os_version :: binary() | undefined
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
    comment_pref :: maybe(boolean()),
    client_version :: binary(),
    lang_id :: binary()
}).

-type push_info() :: #push_info{}.

-define(MAX_NAME_SIZE, 25).   %% 25 utf8 characters

-endif.
