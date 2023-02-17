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
-include("time.hrl").

-record(account,
{
    uid :: binary(),
    phone :: maybe(binary()),
    name :: maybe(binary()),
    creation_ts_ms :: maybe(integer()),
    last_registration_ts_ms :: maybe(integer()),
    signup_user_agent :: binary(),
    campaign_id :: binary(),
    client_version :: binary(),
    last_activity_ts_ms :: maybe(integer()),
    activity_status :: maybe(activity_status()),
    lang_id :: maybe(binary()),
    zone_offset :: maybe(integer()),
    device :: maybe(binary()),
    os_version :: maybe(binary()),
    last_ipaddress :: maybe(binary()),
    avatar_id :: maybe(binary()),
    username :: maybe(binary())
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
    token :: maybe(binary()),
    voip_token :: maybe(binary()),
    huawei_token :: maybe(binary()),
    timestamp_ms :: integer(),
    post_pref :: maybe(boolean()),
    comment_pref :: maybe(boolean()),
    client_version :: maybe(binary()),
    lang_id :: maybe(binary()),
    zone_offset :: maybe(integer())
}).

-type push_info() :: #push_info{}.

-define(ANDROID_TOKEN_TYPE, <<"android">>).
-define(IOS_TOKEN_TYPE, <<"ios">>).
-define(IOS_DEV_TOKEN_TYPE, <<"ios_dev">>).
-define(IOS_APPCLIP_TOKEN_TYPE, <<"ios_appclip">>).
-define(IOS_VOIP_TOKEN_TYPE, <<"ios_voip">>).
-define(ANDROID_HUAWEI_TOKEN_TYPE, <<"android_huawei">>).

-define(MAX_NAME_SIZE, 25).   %% 25 utf8 characters

%% TODO(josh): remove
-define(MOMENT_TAG_INTERVAL_MIN, 60).
-define(MOMENT_TAG_INTERVAL_SEC, (?MOMENT_TAG_INTERVAL_MIN * ?MINUTES)).

-endif.
