%%%-------------------------------------------------------------------
%%% Redis migrations that remove non-existent friends
%%%
%%% Copyright (C) halloapp inc.
%%%
%%%-------------------------------------------------------------------
-module(migrate_del_community).
-author(luke).

-include("logger.hrl").

-define(FRIEND_RECOMMENDATION_KEY, <<"rec:">>). % recommendation key
-define(FIELD_COMMUNITY, <<"cm">>). % community field in accounts

-export([
    del_recommendation_keys_run/2,
    del_communities_run/2
]).

del_communities_run(Key, State) ->
    Result = re:run(Key, "^acc:{([0-9]+)}$", [global, {capture, all, binary}]),
    DryRun = maps:get(dry_run, State, true),
    case Result of
        {match, [[FullKey, Uid]]} ->
            try
                Command = ["HDEL", FullKey, ?FIELD_COMMUNITY],
                case DryRun of 
                    true -> 
                        ?INFO("Uid: ~p, would run ~p to remove community label if it exists", 
                            [Uid, Command]);
                    false ->
                        q(ecredis_accounts, Command),
                        ?INFO("Uid: ~p, ran ~p to remove community label if it existed", 
                            [Uid, Command])
                end
            catch
                Class : Reason : St ->
                    ?ERROR("failed to cleanup community label of account Uid: ~p, ",
                        [Uid, lager:pr_stacktrace(St, {Class, Reason})])
            end;
        _ -> ok
    end,
    State.


del_recommendation_keys_run(Key, State) ->
       Result = re:run(Key, "^rec:{([0-9]+)}$", [global, {capture, all, binary}]),
    DryRun = maps:get(dry_run, State, true),
    case Result of
        {match, [[FullKey, Uid]]} ->
            try
                Command = ["DEL", FullKey],
                case DryRun of
                    true ->
                        ?INFO("Would run ~p to remove recommendations for ~p", [Command, Uid]);
                    false ->
                        q(ecredis_friends, Command),
                        ?INFO("Ran ~p to remove recommendations for ~p", [Command, Uid])
                end
            catch
                Class : Reason : St ->
                    ?ERROR("failed to remove recommendation key ~p of account Uid: ~p, ",
                        [FullKey, Uid, lager:pr_stacktrace(St, {Class, Reason})])
            end;
        _ -> ok
    end,
    State.




q(Client, Command) -> util_redis:q(Client, Command).
