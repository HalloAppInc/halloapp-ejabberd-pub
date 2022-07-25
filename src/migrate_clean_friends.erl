%%%-------------------------------------------------------------------
%%% Redis migrations that remove non-existent friends
%%%
%%% Copyright (C) halloapp inc.
%%%
%%%-------------------------------------------------------------------
-module(migrate_clean_friends).
-author(luke).

-include("logger.hrl").

-export([
    dry_run_cleanup_deleted_friends_migration/0,
    cleanup_deleted_friends_run/2
]).

dry_run_cleanup_deleted_friends_migration() ->
    redis_migrate:start_migration("Remove nonexistent friends", redis_friends,
        {?MODULE, cleanup_deleted_friends_run}, [{execute, sequential}, {dry_run, true}]),
    ok.


cleanup_deleted_friends_run(Key, State) ->
    Result = re:run(Key, "^fr:{([0-9]+)}$", [global, {capture, all, binary}]),
    DryRun = maps:get(dry_run, State, true),
    case Result of
        {match, [[_FullKey, Uid]]} ->
            try
                ?INFO("Checking uid: ~p", [Uid]),
                {ok, FriendList} = model_friends:get_friends(Uid),
                Exists = model_accounts:account_exists(Uid),
                case Exists of
                    false -> % if the account doesnt exist anymore, then just remove the friends key entirely
                        case DryRun of
                            true -> 
                                ?INFO("Uid ~p doesn't exist; would delete all ~p friends", [Uid, length(FriendList)]);
                            false ->
                                model_friends:remove_all_friends(Uid),
                                ?INFO("Uid ~p doesn't exist; deleted all ~p friends", [Uid, length(FriendList)])
                        end;
                    true ->
                        RealFriendSet = sets:from_list(model_accounts:filter_nonexisting_uids(FriendList)),
                        FriendSet = sets:from_list(FriendList),
                        case FriendSet =:= RealFriendSet of 
                            true -> ok;
                            false -> 
                                RemovedFriends = sets:to_list(sets:subtract(FriendSet, RealFriendSet)),
                                case DryRun of 
                                    true -> 
                                        ?INFO("Uid: ~p, would remove ~p/~p nonexistent friends: ~p", 
                                            [Uid, length(RemovedFriends), sets:size(FriendSet), RemovedFriends]);
                                    false ->
                                        lists:foreach(
                                            fun (RemoveUid) ->
                                                model_friends:remove_friend(Uid, RemoveUid)
                                            end,
                                            RemovedFriends),
                                        ?INFO("Uid: ~p, removed ~p/~p nonexistent friends: ~p", 
                                            [Uid, length(RemovedFriends), sets:size(FriendSet), RemovedFriends]) 
                                end
                        end
                end
            catch
                Class : Reason : St ->
                    ?ERROR("failed to cleanup friends of account Uid: ~p, ",
                        [Uid, lager:pr_stacktrace(St, {Class, Reason})])
            end;
        _ -> ok
    end,
    State.

