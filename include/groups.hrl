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

-define(NS_GROUPS, <<"halloapp:groups">>).

-record(group_member, {
    uid :: uid(),
    type :: member | admin
}).

-type group_member() :: #group_member{}.

-record(group, {
    gid :: gid(),
    name :: binary(),
    avatar :: binary(),
    creation_ts_ms :: integer(),
    members :: [group_member()]
}).

-type group() :: #group{}.

-record(group_info, {
    gid :: gid(),
    name :: binary(),
    avatar :: binary()
}).

-type group_info() :: #group_info{}.

