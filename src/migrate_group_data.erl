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
-include("groups.hrl").

-export([
    top_groups/2,
    check_group_names_run/2,
    check_group_description_run/2
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


check_group_names_run(Key, State) ->
    Result = re:run(Key, "^g:{(.*)}$", [global, {capture, all, binary}]),
    DryRun = maps:get(dry_run, State, false),
    case Result of
        {match, [[_FullKey, Gid]]} ->
            case model_groups:get_group_info(Gid) of
                undefined -> ?INFO("Gid: ~p, GroupInfo is undefined: ~p", [Gid]);
                #group_info{name = Name} ->
                    case unicode:characters_to_nfc_list(Name) of
                        {error, _, _} ->
                            FinalName = util:repair_utf8(Name),
                            ?INFO("Gid: ~p, Invalid GroupName: ~p, FinalName: ~p", [Gid, Name, FinalName]),
                            case DryRun of
                                false -> ok = model_groups:set_name(Gid, FinalName);
                                true -> ok
                            end;
                        _ -> ok
                    end
            end;
        _ ->
            ok
    end,
    State.


check_group_description_run(Key, State) ->
    Result = re:run(Key, "^g:{(.*)}$", [global, {capture, all, binary}]),
    case Result of
        {match, [[_FullKey, Gid]]} ->
            case model_groups:get_group_info(Gid) of
                undefined -> ?INFO("Gid: ~p, GroupInfo is undefined: ~p", [Gid]);
                #group_info{description = undefined} -> ok;
                #group_info{description = Desc} ->
                    case unicode:characters_to_nfc_list(Desc) of
                        {error, _, _} -> ?INFO("Gid: ~p, Invalid Desc: ~p", [Gid, Desc]);
                        _ -> ok
                    end
            end;
        _ ->
            ok
    end,
    State.

