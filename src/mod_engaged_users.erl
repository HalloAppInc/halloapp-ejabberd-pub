%%%-------------------------------------------------------------------
%%% File: mod_engaged_users.erl
%%% copyright (C) 2021, HalloApp, Inc.
%%%
%%%
%%%-------------------------------------------------------------------
-module(mod_engaged_users).
-author('murali').

-include("active_users.hrl").
-include("logger.hrl").
-include("time.hrl").

-behaviour(gen_mod).
-author('murali').

-define(NS_FEED, <<"halloapp:feed">>).

%% gen_mod API.
-export([start/2, stop/1, reload/3, mod_options/1, depends/2]).

%% Hooks and API.
-export([
    group_feed_item_published/4,
    feed_item_published/4,
    user_send_im/3,
    user_send_group_im/4,
    compute_counts/0,
    update_last_activity/1,
    count_engaged_users_1day/1,
    count_engaged_users_7day/1,
    count_engaged_users_28day/1,
    count_engaged_users_30day/1
]).

%% Export all functions for unit tests
-ifdef(TEST).
-export([
    update_last_activity/3
]).
-endif.


start(Host, _Opts) ->
    ejabberd_hooks:add(group_feed_item_published, Host, ?MODULE, group_feed_item_published, 50),
    ejabberd_hooks:add(feed_item_published, Host, ?MODULE, feed_item_published, 50),
    ejabberd_hooks:add(user_send_im, Host, ?MODULE, user_send_im, 50),
    ejabberd_hooks:add(user_send_group_im, Host, ?MODULE, user_send_group_im, 50),
    ok.

stop(Host) ->
    ejabberd_hooks:delete(group_feed_item_published, Host, ?MODULE, group_feed_item_published, 50),
    ejabberd_hooks:delete(feed_item_published, Host, ?MODULE, feed_item_published, 50),
    ejabberd_hooks:delete(user_send_im, Host, ?MODULE, user_send_im, 50),
    ejabberd_hooks:delete(user_send_group_im, Host, ?MODULE, user_send_group_im, 50),
    ok.

reload(_Host, _NewOpts, _OldOpts) ->
    ok.

depends(_Host, _Opts) ->
    [].

mod_options(_Host) ->
    [].


%%====================================================================
%% hooks
%%====================================================================

%% TODO(murali@): we could also have separate counters for each of these activities.
%% For now: we consider all these activities and keep track of count of engaged users.
group_feed_item_published(_Gid, Uid, _ItemId, _ItemType) ->
    update_last_activity(Uid),
    ok.

feed_item_published(Uid, _ItemId, _ItemTypem, _FeedAudienceType) ->
    update_last_activity(Uid),
    ok.


user_send_im(FromUid, _MsgId, _ToUid) ->
    update_last_activity(FromUid),
    ok.


user_send_group_im(_Gid, FromUid, _MsgId, _ToUids) ->
    update_last_activity(FromUid),
    ok.


%%====================================================================
%% API
%%====================================================================

-spec count_engaged_users_1day(Type :: activity_type()) -> non_neg_integer().
count_engaged_users_1day(Type) ->
    count_engaged_users(1 * ?DAYS_MS, Type).


-spec count_engaged_users_7day(Type :: activity_type()) -> non_neg_integer().
count_engaged_users_7day(Type) ->
    count_engaged_users(7 * ?DAYS_MS, Type).


-spec count_engaged_users_28day(Type :: activity_type()) -> non_neg_integer().
count_engaged_users_28day(Type) ->
    count_engaged_users(28 * ?DAYS_MS, Type).


-spec count_engaged_users_30day(Type :: activity_type()) -> non_neg_integer().
count_engaged_users_30day(Type) ->
    count_engaged_users(30 * ?DAYS_MS, Type).


-spec count_engaged_users(IntervalMs :: non_neg_integer(),
        Type :: activity_type()) -> non_neg_integer().
count_engaged_users(IntervalMs, Type) ->
    Now = util:now_ms(),
    model_active_users:count_engaged_users_between(Type, Now - IntervalMs, Now + (1 * ?MINUTES_MS)).


-spec compute_counts() -> ok.
compute_counts() ->
    CountFuns = [
        {fun count_engaged_users_1day/1, "1day"},
        {fun count_engaged_users_7day/1, "7day"},
        {fun count_engaged_users_28day/1, "28day"},
        {fun count_engaged_users_30day/1, "30day"}
    ],
    DeviceTypes = [all, android, ios],
    [stat:gauge("HA/engaged_users", Desc ++ "_" ++ atom_to_list(Device), Fun(Device))
        || {Fun, Desc} <- CountFuns, Device <- DeviceTypes],
    ok.


%%====================================================================
%% internal functions
%%====================================================================

-spec update_last_activity(Uid :: binary()) -> ok.
update_last_activity(Uid) ->
    {ok, ClientVersion} = model_accounts:get_client_version(Uid),
    PlatformType = util_ua:get_client_type(ClientVersion),
    TimestampMs = util:now_ms(),
    update_last_activity(Uid, TimestampMs, PlatformType).

update_last_activity(Uid, TimestampMs, PlatformType) ->
    MainKey = model_active_users:get_engaged_users_key(Uid),
    Keys = case PlatformType of
        undefined -> [MainKey];
        _ -> [MainKey, model_active_users:get_engaged_users_key(Uid, PlatformType)]
    end,
    ok = model_active_users:set_activity(Uid, TimestampMs, Keys),
    ok.

