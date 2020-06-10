%%%-------------------------------------------------------------------
%%% @author nikola
%%% @copyright (C) 2020, HalloApp, Inc.
%%% @doc
%%% Group chat functionality for HalloApp.
%%% Currently the code executes directly on the client C2S process. This means
%%% a group can be modified at the same time from multiple places. This could lead
%%% to number of race conditions, but was the simplest way to implement it.
%%% Possible Race conditions:
%%%   1. Maximum group size could be exceeded if 2 requests to add members get processed
%%% at the same time.
%%%   2. If leave_group and promote_admin requests execute at the same time, user might think he
%%% left the group but instead he is still in the group.
%%% @end
%%% Created : 10. Jun 2020 10:00 AM
%%%-------------------------------------------------------------------
-module(mod_groups).
-author("nikola").
-behaviour(gen_mod).

%% gen_mod api
-export([start/2, stop/1, reload/3, mod_options/1, depends/2]).

-export([
    create_group/2,
    create_group/3,
    add_members/3,
    remove_members/3,
    leave_group/2,
    promote_admins/3,
    demote_admins/3,
    get_group/2,
    get_groups/1,
    set_name/3,
    set_avatar/3,
    send_message/3
]).

-include("logger.hrl").
-include("xmpp.hrl").
-include("groups.hrl").

-define(MAX_GROUP_SIZE, 25).
-define(MAX_GROUP_NAME_SIZE, 25).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%   gen_mod API                                                                              %%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%


start(_Host, _Opts) ->
    ?INFO_MSG("start", []),
    ok.


stop(_Host) ->
    ?INFO_MSG("stop", []),
    ok.


reload(_Host, _NewOpts, _OldOpts) ->
    ok.


depends(_Host, _Opts) ->
    [{mod_redis, hard}].


mod_options(_Host) ->
    [].

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%   API                                                                                      %%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

-type add_member_result() :: {uid(), ok | no_account | max_groups_size}.
-type add_member_results() :: [add_member_result()].
-type modify_admin_result() :: {uid(), ok | no_member}.
-type modify_admin_results() :: [modify_admin_result()].


-spec create_group(Uid :: uid(), GroupName :: binary()) -> {ok, group()} | {error, invalid_name}.
create_group(Uid, GroupName) ->
    ?INFO_MSG("Uid: ~s GroupName: ~s", [Uid, GroupName]),
    case create_group_internal(Uid, GroupName) of
        {error, Reason} -> {error, Reason};
        {ok, Gid} ->
            Group = model_groups:get_group(Gid),
            {ok, Group}
    end.


-spec create_group(Uid :: uid(), GroupName :: binary(), MemberUids :: [uid()])
            -> {ok, group(), add_member_results()} | {error, any()}.
create_group(Uid, GroupName, MemberUids) ->
    case create_group_internal(Uid, GroupName) of
        {error, Reason} -> {error, Reason};
        {ok, Gid} ->
            ?INFO_MSG("Gid: ~s Uid: ~s initializing with Members ~p", [Gid, Uid, MemberUids]),
            Results = add_members_unsafe(Gid, Uid, MemberUids),

            Group = model_groups:get_group(Gid),
            {ok, Group, [{Uid, ok} | Results]}
    end.


-spec add_members(Gid :: gid(), Uid :: uid(), MemberUids :: [uid()])
            -> {ok, add_member_results()} | {error, not_admin}.
add_members(Gid, Uid, MemberUids) ->
    ?INFO_MSG("Gid: ~s Uid: ~s Members: ~p", [Gid, Uid, MemberUids]),
    case model_groups:is_admin(Gid, Uid) of
        false -> {error, not_admin};
        true ->
            Results = add_members_unsafe(Gid, Uid, MemberUids),
            {ok, Results}
    end.


%TODO: Maybe change the result to match add_members even thought there are no failure cases
-spec remove_members(Gid :: gid(), Uid :: uid(), MemberUids :: [uid()]) -> ok | {error, not_admin}.
remove_members(Gid, Uid, MemberUids) ->
    ?INFO_MSG("Gid: ~s Uid: ~s Members: ~p", [Gid, Uid, MemberUids]),
    case model_groups:is_admin(Gid, Uid) of
        false -> {error, not_admin};
        true ->
            {ok, _} = model_groups:remove_members(Gid, MemberUids),
            ok
    end.


-spec leave_group(Gid :: gid(), Uid :: uid()) -> {ok, boolean()}.
leave_group(Gid, Uid) ->
    ?INFO_MSG("Gid: ~s Uid: ~s", [Gid, Uid]),
    Res = model_groups:remove_member(Gid, Uid),
    case Res of
        {ok, false} ->
            ?INFO_MSG("Gid: ~s Uid: ~s not a member already", [Gid, Uid]);
        {ok, true} ->
            ?INFO_MSG("Gid: ~s Uid: ~s left", [Gid, Uid])
    end,
    Res.


-spec promote_admins(Gid :: gid(), Uid :: uid(), AdminUids :: [uid()])
            -> {ok, modify_admin_results()} | {error, not_admin}.
promote_admins(Gid, Uid, AdminUids) ->
    ?INFO_MSG("Gid: ~s Uid: ~s Admins: ~p", [Gid, Uid, AdminUids]),
    case model_groups:is_admin(Gid, Uid) of
        false -> {error, not_admin};
        true ->
            Results = [{OUid, promote_admin_unsafe(Gid, OUid)} || OUid <- AdminUids],
            {ok, Results}
    end.


-spec demote_admins(Gid :: gid(), Uid :: uid(), AdminUids :: [uid()])
            -> {ok, modify_admin_results()} | {error, not_admin}.
demote_admins(Gid, Uid, AdminUids) ->
    ?INFO_MSG("Gid: ~s Uid: ~s Admins: ~p", [Gid, Uid, AdminUids]),
    case model_groups:is_admin(Gid, Uid) of
        false -> {error, not_admin};
        true ->
            Results = [{OUid, demote_admin_unsafe(Gid, OUid)} || OUid <- AdminUids],
            {ok, Results}
    end.


-spec get_group(Gid :: gid(), Uid :: uid()) -> {ok, group()} | {error, not_member | no_group}.
get_group(Gid, Uid) ->
    case model_groups:is_member(Gid, Uid) of
        false -> {error, not_member};
        true ->
            case model_groups:get_group(Gid) of
                undefined -> {error, no_group};
                Group -> {ok, Group}
            end
    end.


% TODO: we need to return groups with no members here.
-spec get_groups(Uid :: uid()) -> [group()].
get_groups(Uid) ->
    model_groups:get_groups(Uid).


-spec set_name(Gid :: gid(), Uid :: uid(), Name :: binary()) -> ok | {error, any()}.
set_name(Gid, Uid, Name) ->
    ?INFO_MSG("Gid: ~s Uid: ~s Name: |~s|", [Gid, Uid, Name]),
    case validate_group_name(Name) of
        {error, _Reason} = E -> E;
        {ok, LName} ->
            case model_groups:check_member(Gid, Uid) of
                false ->
                    %% also possible the group does not exists
                    {error, not_member};
                true ->
                    ok = model_groups:set_name(Gid, LName),
                    ?INFO_MSG("Gid: ~s Uid: ~s set name to |~s|", [Gid, Uid, LName]),
                    ok
            end
    end.


-spec set_avatar(Gid :: gid(), Uid :: uid(), AvatarId :: binary()) -> ok | {error, any()}.
set_avatar(Gid, Uid, AvatarId) ->
    ?INFO_MSG("Gid: ~s Uid: ~s setting avatar to ~s", [Gid, Uid, AvatarId]),
    case model_groups:check_member(Gid, Uid) of
        false ->
            %% also possible the group does not exists
            {error, not_member};
        true ->
            ok = model_groups:set_avatar(Gid, AvatarId),
            ?INFO_MSG("Gid: ~s Uid: ~s set avatar to ~s", [Gid, Uid, AvatarId]),
            ok
    end.


-spec send_message(Gid :: gid(), Uid :: uid(), MessageIn :: binary())
            -> {ok, Ts} | {error, atom()}
            when Ts :: non_neg_integer().
send_message(Gid, Uid, MessageIn) ->
    ?INFO_MSG("Gid: ~s Uid: ~s", [Gid, Uid]),
    case model_groups:check_member(Gid, Uid) of
        false ->
            %% also possible the group does not exists
            {error, not_member};
        true ->
            %% TODO: use util:uid_to_jids and ejabberd_router_multicast:route_multicast
            Ts = util:now_ms(),
            GroupMessage = make_message(Gid, Uid, MessageIn, Ts),
            MUids = model_groups:get_member_uids(Gid),
            Server = util:get_host(),
            lists:foreach(
                fun (OUid) ->
                    MessageOut = #message{
                        from = jid:make(Server),
                        to = jid:make(OUid, Server),
                        sub_els = [GroupMessage]},
                    ejabberd_router:route(MessageOut)
                end,
                MUids),
            {ok, Ts}
    end.


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%   Internal                                                                                 %%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%


create_group_internal(Uid, GroupName) ->
    case validate_group_name(GroupName) of
        {error, Reason} -> {error, Reason};
        {ok, LGroupName} ->
            % TODO: switch arguments around in the model
            {ok, Gid} = model_groups:create_group(LGroupName, Uid),
            ?INFO_MSG("group created Gid: ~s Uid: ~s GroupName: |~s|", [Gid, Uid, LGroupName]),
            {ok, Gid}
    end.


-spec add_members_unsafe(Gid :: gid(), Uid :: uid(), MemberUids :: [uid()])
            -> [{uid(), ok | no_account | max_groups_size}].
add_members_unsafe(Gid, Uid, MemberUids) ->
    GroupSize = model_groups:get_group_size(Gid),
    case GroupSize + length(MemberUids) > ?MAX_GROUP_SIZE of
        true ->
            % Group size will be exceeded.
            [{Ouid, max_group_size} || Ouid <- MemberUids];
        false ->
            add_members_unsafe_2(Gid, Uid, MemberUids)
    end.


add_members_unsafe_2(Gid, Uid, MemberUids) ->
    GoodUids = check_accounts_exists(MemberUids),
    model_groups:add_members(Gid, GoodUids, Uid),
    lists:map(
        fun (OUid) ->
            case lists:member(OUid, GoodUids) of
                false ->
                    {OUid, no_account};
                true ->
                    {OUid, ok}
            end
        end,
        MemberUids).


-spec validate_group_name(Name :: binary()) -> {ok, binary()} | {error, invalid_name}.
validate_group_name(<<"">>) ->
    {error, invalid_name};
validate_group_name(Name) when is_binary(Name) ->
    LName = string:slice(Name, 0, ?MAX_GROUP_NAME_SIZE),
    case LName =:= Name of
        false -> ?WARNING_MSG("Truncating group name to |~s| size was: ~p", [LName, length(Name)]);
        true -> ok
    end,
    {ok, LName};
validate_group_name(_Name) ->
    {error, invalid_name}.


-spec promote_admin_unsafe(Gid :: gid(), Uid :: uid()) -> {uid(), ok | not_member}.
promote_admin_unsafe(Gid, Uid) ->
    case model_groups:promote_admin(Gid, Uid) of
        {error, Reason} ->
            Reason;
        {ok, _} ->
            ok
    end.


-spec demote_admin_unsafe(Gid :: gid(), Uid :: uid()) -> {uid(), ok | not_member}.
demote_admin_unsafe(Gid, Uid) ->
    case model_groups:demote_admin(Gid, Uid) of
        {ok, not_member} ->
            not_member;
        {ok, _} ->
            ok
    end.


% TODO: maybe this function should be in model_accounts
-spec check_accounts_exists(Uids :: [uid()]) -> [uid()].
check_accounts_exists(Uids) ->
    lists:foldr(
        fun (Uid, Acc) ->
            case model_accounts:account_exists(Uid) of
                true -> [Uid | Acc];
                false -> Acc
            end
        end,
        [],
        Uids).


make_message(Gid, Uid, MessageIn, Ts) ->
    % TODO: implement
    undefined.
%%    #group_message{
%%
%%    }


