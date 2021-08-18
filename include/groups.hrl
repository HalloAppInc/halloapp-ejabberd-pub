%%%-------------------------------------------------------------------
%%% @author nikola
%%% @copyright (C) 2020, Halloapp Inc.
%%% @doc
%%%
%%% @end
%%% Created : 05. Jun 2020 5:25 PM
%%%-------------------------------------------------------------------
-author("nikola").

-include("ha_types.hrl").

-ifndef(GROUPS_HRL).
-define(GROUPS_HRL, 1).
-define(TRUNC_HASH_LENGTH, 6).


-define(NS_GROUPS, <<"halloapp:groups">>).
-define(NS_GROUPS_FEED, <<"halloapp:group:feed">>).

-record(group_member, {
    uid :: uid(),
    type :: member | admin,
    joined_ts_ms :: non_neg_integer(),
    identity_key :: binary()
}).

-type group_member() :: #group_member{}.

-record(group, {
    gid :: gid(),
    name :: binary(),
    description :: binary(),
    avatar :: binary(),
    background :: binary(),
    creation_ts_ms :: integer(),
    members :: [group_member()],
    audience_hash :: binary()
}).

-type group() :: #group{}.

-record(group_info, {
    gid :: gid(),
    name :: binary(),
    description :: binary(),
    avatar :: binary(),
    background :: binary(),
    audience_hash :: binary()
}).

-type group_info() :: #group_info{}.

-define(MAX_GROUP_SIZE, 50).
-define(SHA256, sha256).

-endif.

