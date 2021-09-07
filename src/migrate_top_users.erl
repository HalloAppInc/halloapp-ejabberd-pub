%%%-------------------------------------------------------------------
%%% Calculate the top users
%%%
%%% Copyright (C) halloapp inc.
%%%
%%%-------------------------------------------------------------------
-module(migrate_top_users).
-author(nikola).

-include("logger.hrl").
-include("feed.hrl").

-export([
    top_users/2
]).


top_users(Key, State) ->
    Result = re:run(Key, "^acc:{([0-9]+)}$", [global, {capture, all, binary}]),
    case Result of
        {match, [[_FullKey, Uid]]} ->
            {ok, Friends} = model_friends:get_friends(Uid),

            {ok, FeedItems} = model_feed:get_entire_user_feed(Uid),
            NumPosts = length(lists:filter(fun (I) -> element(1, I) == post end, FeedItems)),

            % to get the number of group posts we have to iterate over all groups.
            Gids = model_groups:get_groups(Uid),
            NumGPosts = lists:sum(lists:map(
                fun(Gid) ->
                    {ok, GFeedItems} = model_feed:get_entire_group_feed(Gid),
                    erlang:length(lists:filter(
                        fun(I) ->
                            % TODO: change to #post
                            element(1, I) == post andalso I#post.uid == Uid
                        end, GFeedItems))
                end, Gids)),

            ?INFO("Uid ~s has ~p friends, ~p posts ~p gposts ~p groups",
                [Uid, length(Friends), NumPosts, NumGPosts, length(Gids)]),
            ok;
        _ ->
            ok
    end,
    State.

