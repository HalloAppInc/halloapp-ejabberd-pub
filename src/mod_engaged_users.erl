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
    group_feed_item_published/5,
    feed_item_published/6,
    user_send_im/4,
    user_send_group_im/4,
    compute_counts/0,
    count_engaged_users_1day/1,
    count_engaged_users_7day/1,
    count_engaged_users_28day/1,
    count_engaged_users_30day/1
]).

%% Export all functions for unit tests
-ifdef(TEST).
-export([
    update_last_activity/4
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

group_feed_item_published(_Gid, Uid, _ItemId, ItemType, _MediaCounters) ->
    update_last_activity(Uid, ItemType),
    ok.

feed_item_published(Uid, _ItemId, ItemType, _ItemTag, _FeedAudienceType, _MediaCounters) ->
    update_last_activity(Uid, ItemType),
    ok.


user_send_im(FromUid, _MsgId, _ToUid, _MediaCounters) ->
    update_last_activity(FromUid, send_im),
    ok.


user_send_group_im(_Gid, FromUid, _MsgId, _ToUids) ->
    update_last_activity(FromUid, send_group_im),
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
    Types = model_active_users:engaged_users_types(),
    [stat:gauge("HA/engaged_users", Desc ++ "_" ++ atom_to_list(Type), Fun(Type))
        || {Fun, Desc} <- CountFuns, Type <- Types],
    ok.


%%====================================================================
%% internal functions
%%====================================================================

-spec update_last_activity(Uid :: binary(), Action :: atom()) -> ok.
update_last_activity(Uid, Action) ->
    {ok, ClientVersion} = model_accounts:get_client_version(Uid),
    PlatformType = util_ua:get_client_type(ClientVersion),
    TimestampMs = util:now_ms(),
    update_last_activity(Uid, Action, TimestampMs, PlatformType).

update_last_activity(Uid, Action, TimestampMs, PlatformType) ->
    MainKey = model_active_users:get_engaged_users_key(Uid),
    Keys1 = [MainKey],
    Keys2 = case PlatformType of
        undefined -> Keys1;
        _ -> [model_active_users:get_engaged_users_key(Uid, PlatformType) | Keys1]
    end,
    %% TODO(murali@): we could also have separate counters for each of these actions.
    Keys3 = case Action of
        post -> [model_active_users:get_engaged_users_key(Uid, post) | Keys2];
        _ -> Keys2
    end,
    ok = model_active_users:set_activity(Uid, TimestampMs, Keys3),
    ok.

