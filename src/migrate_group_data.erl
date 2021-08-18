%%%-------------------------------------------------------------------
%%% Collect some stats about groups.
%%%
%%% Copyright (C) halloapp inc.
%%%
%%%-------------------------------------------------------------------
-module(migrate_group_data).
-author('murali').

-include("logger.hrl").
-include("feed.hrl").

-export([
    top_groups/2
]).


top_groups(Key, State) ->
    Result = re:run(Key, "^g:{(.*)}$", [global, {capture, all, binary}]),
    case Result of
        {match, [[_FullKey, Gid]]} ->
            GroupSize = model_groups:get_group_size(Gid),
            BucketRange = 5,
            Bucket = GroupSize/BucketRange,
            ?INFO("Gid: ~p, GroupSize: ~p, Bucket: ~p", [Gid, GroupSize, Bucket]),
            ok;
        _ ->
            ok
    end,
    State.

