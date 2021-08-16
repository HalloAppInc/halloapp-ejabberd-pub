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
    delete_group/2,
    add_members/3,
    remove_members/3,
    modify_members/3,
    leave_group/2,
    promote_admins/3,
    demote_admins/3,
    modify_admins/3,
    get_group/2,
    get_member_identity_keys/2,
    get_group_info/2,
    get_groups/1,
    remove_user/2,
    set_name/3,
    set_description/3,
    set_avatar/3,
    set_background/3,
    delete_avatar/2,
    send_chat_message/4,
    broadcast_packet/3,
    send_retract_message/4,
    get_all_group_members/1,
    get_invite_link/2,
    reset_invite_link/2,
    preview_with_invite_link/2,
    web_preview_invite_link/1,
    join_with_invite_link/2
]).

-include("logger.hrl").
-include("packets.hrl").
-include("groups.hrl").
-include("feed.hrl").
-define(MAX_GROUP_NAME_SIZE, 25).
-define(MAX_GROUP_DESCRIPTION_SIZE, 2000).
-define(MAX_BG_LENGTH, 64).

-define(STAT_NS, "HA/groups").

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%   gen_mod API                                                                              %%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%


start(Host, _Opts) ->
    ?INFO("start", []),
    ejabberd_hooks:add(remove_user, Host, ?MODULE, remove_user, 50),
    ok.


stop(Host) ->
    ?INFO("stop", []),
    ejabberd_hooks:delete(remove_user, Host, ?MODULE, remove_user, 50),
    ok.


reload(_Host, _NewOpts, _OldOpts) ->
    ok.


depends(_Host, _Opts) ->
    [].


mod_options(_Host) ->
    [].

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%   API                                                                                      %%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

-type modify_member_result() :: {uid(), add | remove, ok | no_account | max_group_size | already_member | already_not_member}.
-type modify_member_results() :: [modify_member_result()].
-type modify_admin_result() :: {uid(), promote | demote, ok | no_member}.
-type modify_admin_results() :: [modify_admin_result()].

-type modify_results() :: modify_member_results() | modify_admin_results().


-spec create_group(Uid :: uid(), GroupName :: binary()) -> {ok, group()} | {error, invalid_name}.
create_group(Uid, GroupName) ->
    ?INFO("Uid: ~s GroupName: ~s", [Uid, GroupName]),
    case create_group_internal(Uid, GroupName) of
        {error, Reason} -> {error, Reason};
        {ok, Gid} ->
            Group = model_groups:get_group(Gid),
            {ok, Group}
    end.


-spec create_group(Uid :: uid(), GroupName :: binary(), MemberUids :: [uid()])
            -> {ok, group(), modify_member_results()} | {error, any()}.
create_group(Uid, GroupName, MemberUids) ->
    case create_group_internal(Uid, GroupName) of
        {error, Reason} -> {error, Reason};
        {ok, Gid} ->
            ?INFO("Gid: ~s Uid: ~s initializing with Members ~p", [Gid, Uid, MemberUids]),
            Results = add_members_unsafe(Gid, Uid, MemberUids),

            Group = model_groups:get_group(Gid),

            send_create_group_event(Group, Uid, Results),
            {ok, Group, Results}
    end.


-spec delete_group(Gid :: binary(), Uid :: binary()) -> ok | {error, any()}.
delete_group(Gid, Uid) ->
    ?INFO("Gid: ~s Uid: ~s deleting group", [Gid, Uid]),
    case model_groups:is_admin(Gid, Uid) of
        false -> {error, not_admin};
        true ->
            Group = model_groups:get_group(Gid),
            NamesMap = model_accounts:get_names([Uid]),
            delete_group_avatar_data(Gid, Group#group.avatar),
            ok = model_groups:delete_group(Gid),
            broadcast_update(Group, Uid, delete, [], NamesMap),
            stat:count(?STAT_NS, "delete"),
            stat:count(?STAT_NS, "delete_total_members", length(Group#group.members)),
            ok
    end.


-spec add_members(Gid :: gid(), Uid :: uid(), MemberUids :: [uid()])
            -> {ok, modify_member_results()} | {error, not_admin}.
add_members(Gid, Uid, MemberUids) ->
    modify_members(Gid, Uid, [{Ouid, add} || Ouid <- MemberUids]).


-spec remove_members(Gid :: gid(), Uid :: uid(), MemberUids :: [uid()])
            -> {ok, modify_member_results()} | {error, not_admin}.
remove_members(Gid, Uid, MemberUids) ->
    modify_members(Gid, Uid, [{Ouid, remove} || Ouid <- MemberUids]).


-spec modify_members(Gid :: gid(), Uid :: uid(), Changes :: [{uid(), add | remove}])
            -> {ok, modify_member_results()} | {error, not_admin}.
modify_members(Gid, Uid, Changes) ->
    case model_groups:is_admin(Gid, Uid) of
        false -> {error, not_admin};
        true ->
            {RemoveUids, AddUids} = split_changes(Changes, remove),
            RemoveResults = remove_members_unsafe(Gid, RemoveUids),
            AddResults = add_members_unsafe(Gid, Uid, AddUids),
            Results = RemoveResults ++ AddResults,
            log_stats(modify_members, Results),
            send_modify_members_event(Gid, Uid, Results),
            update_removed_members_set(Gid, Results),
            maybe_delete_empty_group(Gid),
            {ok, Results}
    end.


-spec leave_group(Gid :: gid(), Uid :: uid()) -> {ok, boolean()}.
leave_group(Gid, Uid) ->
    ?INFO("Gid: ~s Uid: ~s", [Gid, Uid]),
    Res = model_groups:remove_member(Gid, Uid),
    case Res of
        {ok, false} ->
            ?INFO("Gid: ~s Uid: ~s not a member already", [Gid, Uid]);
        {ok, true} ->
            ?INFO("Gid: ~s Uid: ~s left", [Gid, Uid]),
            stat:count(?STAT_NS, "leave"),
            send_leave_group_event(Gid, Uid),
            maybe_assign_admin(Gid)
    end,
    maybe_delete_empty_group(Gid),
    Res.


-spec promote_admins(Gid :: gid(), Uid :: uid(), AdminUids :: [uid()])
            -> {ok, modify_admin_results()} | {error, not_admin}.
promote_admins(Gid, Uid, AdminUids) ->
    modify_admins(Gid, Uid, [{Ouid, promote} || Ouid <- AdminUids]).


-spec demote_admins(Gid :: gid(), Uid :: uid(), AdminUids :: [uid()])
            -> {ok, modify_admin_results()} | {error, not_admin}.
demote_admins(Gid, Uid, AdminUids) ->
    modify_admins(Gid, Uid, [{Ouid, demote} || Ouid <- AdminUids]).


-spec modify_admins(Gid :: gid(), Uid :: uid(), Changes :: [{uid(), promote | demote}])
            -> {ok, modify_admin_results()} | {error, not_admin}.
modify_admins(Gid, Uid, Changes) ->
    ?INFO("Gid: ~s Uid: ~s Changes: ~p", [Gid, Uid, Changes]),
    case model_groups:is_admin(Gid, Uid) of
        false -> {error, not_admin};
        true ->
            {DemoteUids, PromoteUids} = split_changes(Changes, demote),
            DemoteResults = demote_admins_unsafe(Gid, DemoteUids),
            PromoteResults = promote_admins_unsafe(Gid, PromoteUids),
            Results = DemoteResults ++ PromoteResults,
            log_stats(modify_admins, Results),
            send_modify_admins_event(Gid, Uid, Results),
            maybe_assign_admin(Gid),
            {ok, Results}
    end.


-spec get_group(Gid :: gid(), Uid :: uid()) -> {ok, group()} | {error, not_member}.
get_group(Gid, Uid) ->
    case model_groups:is_member(Gid, Uid) of
        false -> {error, not_member};
        true ->
            case model_groups:get_group(Gid) of
                undefined ->
                    ?ERROR("could not find the group: ~p uid: ~p", [Gid, Uid]),
                    {error, not_member};
                Group -> {ok, Group}
            end
    end.


-spec get_member_identity_keys(Gid :: gid(), Uid :: uid()) -> {ok, group()} | {error, not_member}.
get_member_identity_keys(Gid, Uid) ->
    case model_groups:is_member(Gid, Uid) of
        false -> {error, not_member};
        true ->
            case model_groups:get_group(Gid) of
                undefined ->
                    ?ERROR("could not find the group: ~p uid: ~p", [Gid, Uid]),
                    {error, not_member};
                Group ->
                    %% Above call has returned members in sorted order by member Uids.
                    get_member_identity_keys_unsafe(Group)
            end
    end.


-spec get_member_identity_keys_unsafe(Group :: group()) -> {ok, group()} | {error, any()}.
get_member_identity_keys_unsafe(Group) ->
    GroupMembers = Group#group.members,
    Uids = [Member#group_member.uid || Member <- GroupMembers],
    IdentityKeysMap = model_whisper_keys:get_identity_keys(Uids),
    GroupMembers2 = lists:map(
        fun(#group_member{uid = Uid2} = Member2) ->
            Member2#group_member{identity_key = maps:get(Uid2, IdentityKeysMap, undefined)}
        end, GroupMembers),
    %% GroupMembers has members in sorted order by member Uids.
    IKList = lists:foldl(
        fun(#group_member{uid = Uid2, identity_key = IdentityKey}, Acc) ->
            case IdentityKey of
                undefined ->
                    ?ERROR("Uid: ~p identity key is invalid", [Uid2]),
                    Acc;
                _ ->
                    IdentityKeyBin = base64:decode(IdentityKey),
                    % Need to parse IdentityKeyBin as per identity_key proto
                    try enif_protobuf:decode(IdentityKeyBin, pb_identity_key) of
                        #pb_identity_key{public_key = IPublicKey} ->
                            [IPublicKey | Acc]
                    catch Class : Reason : St ->
                        ?ERROR("failed to parse identity key: ~p, Uid: ~p",
                            [IdentityKey, Uid2, lager:pr_stacktrace(St, {Class, Reason})])
                    end
            end
        end, [], GroupMembers2),
    XorIKList = case length(IKList) of
        0 -> [];
        Len ->
            Start = [0 || _ <- lists:seq(1, byte_size(lists:last(IKList)))],
            lists:foldl(fun(XX, Acc) ->
                lists:zipwith(fun(X, Y) -> X bxor Y end, Acc, util:to_list(XX))
            end, Start, IKList)
    end,
    AudienceHash = crypto:hash(?SHA256, XorIKList),
    <<TruncAudienceHash:?TRUNC_HASH_LENGTH/binary, _Rem/binary>> = AudienceHash,
    Group2 = Group#group{
        members = GroupMembers2,
        audience_hash = TruncAudienceHash
    },
    {ok, Group2}.
 

-spec get_group_info(Gid :: gid(), Uid :: uid())
            -> {ok, group_info()} | {error, not_member | no_group}.
get_group_info(Gid, Uid) ->
    case model_groups:is_member(Gid, Uid) of
        false -> {error, not_member};
        true ->
            case model_groups:get_group_info(Gid) of
                undefined -> {error, no_group};
                GroupInfo -> {ok, GroupInfo}
            end
    end.


-spec get_groups(Uid :: uid()) -> [group_info()].
get_groups(Uid) ->
    Gids = model_groups:get_groups(Uid),
    lists:filtermap(
        fun (Gid) ->
            case model_groups:get_group_info(Gid) of
                undefined ->
                    ?WARNING("can not find group ~s", [Gid]),
                    false;
                GroupInfo ->
                    {true, GroupInfo}
            end
        end,
        Gids).


-spec remove_user(Uid :: uid(), Server :: binary()) -> ok.
remove_user(Uid, _Server) ->
    ?INFO_MSG("Uid: ~s", [Uid]),
    Gids = model_groups:get_groups(Uid),
    lists:foreach(fun(Gid) -> leave_group(Gid, Uid) end, Gids),
    ok.


-spec set_name(Gid :: gid(), Uid :: uid(), Name :: binary()) -> ok | {error, invalid_name | not_member}.
set_name(Gid, Uid, Name) ->
    ?INFO("Gid: ~s Uid: ~s Name: |~s|", [Gid, Uid, Name]),
    case validate_group_name(Name) of
        {error, _Reason} = E -> E;
        {ok, LName} ->
            case model_groups:check_member(Gid, Uid) of
                false ->
                    %% also possible the group does not exists
                    {error, not_member};
                true ->
                    ok = model_groups:set_name(Gid, LName),
                    ?INFO("Gid: ~s Uid: ~s set name to |~s|", [Gid, Uid, LName]),
                    stat:count(?STAT_NS, "set_name"),
                    send_change_name_event(Gid, Uid),
                    ok
            end
    end.


-spec set_description(Gid :: gid(), Uid :: uid(),
        Description :: binary()) -> ok | {error, invalid_description | not_member}.
set_description(Gid, Uid, Description) ->
    ?INFO("Gid: ~s Uid: ~s Description: |~s|", [Gid, Uid, Description]),
    case validate_group_description(Description) of
        {error, _Reason} = E -> E;
        {ok, LDescription} ->
            case model_groups:check_member(Gid, Uid) of
                false ->
                    %% also possible the group does not exists
                    {error, not_member};
                true ->
                    ok = model_groups:set_description(Gid, LDescription),
                    ?INFO("Gid: ~s Uid: ~s set description to |~s|", [Gid, Uid, LDescription]),
                    stat:count(?STAT_NS, "set_description"),
                    send_change_description_event(Gid, Uid),
                    ok
            end
    end.


-spec set_avatar(Gid :: gid(), Uid :: uid(), AvatarId :: binary()) ->
        {ok, AvatarId :: binary(), GroupName :: binary()} | {error, not_member}.
set_avatar(Gid, Uid, AvatarId) ->
    ?INFO("Gid: ~s Uid: ~s setting avatar to ~s", [Gid, Uid, AvatarId]),
    case model_groups:check_member(Gid, Uid) of
        false ->
            %% also possible the group does not exists
            ?WARNING("Gid: ~s, Uid: ~s is not member", [Gid, Uid]),
            {error, not_member};
        true ->
            GroupInfo = model_groups:get_group_info(Gid),
            ok = delete_group_avatar_data(Gid, GroupInfo#group_info.avatar),
            ok = model_groups:set_avatar(Gid, AvatarId),
            ?INFO("Gid: ~s Uid: ~s set avatar to ~s", [Gid, Uid, AvatarId]),
            stat:count(?STAT_NS, "set_avatar"),
            send_change_avatar_event(Gid, Uid),
            {ok, AvatarId, GroupInfo#group_info.name}
    end.


-spec delete_avatar(Gid :: gid(), Uid :: uid()) ->
        {ok, GroupName :: binary()} | {error, not_member}.
delete_avatar(Gid, Uid) ->
    ?INFO("Gid: ~s Uid: ~s deleting avatar", [Gid, Uid]),
    case model_groups:check_member(Gid, Uid) of
        false ->
            %% also possible the group does not exists
            ?WARNING("Gid: ~s, Uid: ~s is not member", [Gid, Uid]),
            {error, not_member};
        true ->
            GroupInfo = model_groups:get_group_info(Gid),
            ok = delete_group_avatar_data(Gid, GroupInfo#group_info.avatar),
            ok = model_groups:delete_avatar(Gid),
            ?INFO("Gid: ~s Uid: ~s deleted avatar", [Gid, Uid]),
            stat:count(?STAT_NS, "delete_avatar"),
            {ok, GroupInfo#group_info.name}
    end.

-spec set_background(Gid :: gid(), Uid :: uid(), Background :: binary()) ->
    {ok, Background :: binary(), GroupName :: binary()} | {error, not_member} | {error | background_too_large}.
set_background(Gid, Uid, Background) ->
    ?INFO("Gid: ~s Uid: ~s setting background to ~s", [Gid, Uid, Background]),
    IsTooLong = case Background of
        undefined -> false;
        _ -> byte_size(Background) > ?MAX_BG_LENGTH
    end,
    IsMember = model_groups:check_member(Gid, Uid),
    if
        not IsMember -> {error, not_member};
        IsTooLong -> {error, background_too_large};
        true ->
            ok = model_groups:set_background(Gid, Background),
            ?INFO("Gid: ~s Uid: ~s set background to ~s", [Gid, Uid, Background]),
            stat:count(?STAT_NS, "set_background"),
            send_change_background_event(Gid, Uid),
            {ok, Background}
    end.

-spec send_chat_message(MsgId :: binary(), Gid :: gid(), Uid :: uid(), MessagePayload :: binary())
            -> {ok, Ts} | {error, atom()}
            when Ts :: non_neg_integer().
send_chat_message(MsgId, Gid, Uid, MessagePayload) ->
    ?INFO("Gid: ~s Uid: ~s", [Gid, Uid]),
    case model_groups:check_member(Gid, Uid) of
        false ->
            %% also possible the group does not exists
            {error, not_member};
        true ->
            Ts = util:now(),
            GroupInfo = model_groups:get_group_info(Gid),
            {ok, SenderName} = model_accounts:get_name(Uid),
            GroupMessage = make_chat_message(GroupInfo, Uid, SenderName, MessagePayload, Ts),
            ?INFO("Fan Out MSG: ~p", [GroupMessage]),
            Server = util:get_host(),
            Packet = #pb_msg{
                id = MsgId,
                type = groupchat,
                payload = GroupMessage
            },
            MUids = model_groups:get_member_uids(Gid),	
            ReceiverUids = lists:delete(Uid, MUids),
            stat:count(?STAT_NS, "send_im"),
            stat:count(?STAT_NS, "recv_im", length(ReceiverUids)),
            ejabberd_hooks:run(user_send_group_im, Server, [Gid, Uid, MsgId, ReceiverUids]),
            broadcast_packet(Uid, ReceiverUids, Packet),
            {ok, Ts}
    end.


-spec send_retract_message(MsgId :: binary(), Gid :: gid(), Uid :: uid(),
        GroupChatRetractSt :: pb_group_chat_retract()) -> {ok, Ts} | {error, atom()}
        when Ts :: non_neg_integer().
send_retract_message(MsgId, Gid, Uid, GroupChatRetractSt) ->
    ?INFO("Gid: ~s Uid: ~s", [Gid, Uid]),
    case model_groups:check_member(Gid, Uid) of
        false ->
            %% also possible the group does not exists
            {error, not_member};
        true ->
            Ts = util:now(),
            ?INFO("Fan Out MSG: ~p", [GroupChatRetractSt]),
            Packet = #pb_msg{
                id = MsgId,
                type = groupchat,
                payload = GroupChatRetractSt
            },
            MUids = model_groups:get_member_uids(Gid),
            ReceiverUids = lists:delete(Uid, MUids),
            broadcast_packet(Uid, ReceiverUids, Packet),
            {ok, Ts}
    end.


-spec broadcast_packet(FromUid :: uid(), BroadcastUids :: [uid()],
            Packet :: pb_msg() | pb_chat_state()) -> ok.
broadcast_packet(FromUid, BroadcastUids, Packet) ->
    ?INFO("Uid: ~s, receiver uids: ~p", [FromUid, BroadcastUids]),
    ejabberd_router:route_multicast(FromUid, BroadcastUids, Packet),
    ok.

%% Returns a set of all the uids that are in one or more groups with given Uid.
-spec get_all_group_members(Uid :: uid()) -> set(). % set of uids
get_all_group_members(Uid) ->
    Gids = model_groups:get_groups(Uid),
    MembersSetList = lists:map(
        fun (Gid) ->
            sets:from_list(model_groups:get_member_uids(Gid))
        end, Gids),
    S = sets:union(MembersSetList),
    % remove the caller uid
    sets:del_element(Uid, S).


-spec get_invite_link(Gid :: gid(), Uid :: uid()) -> {ok, Link :: binary()} | {error, term()}.
get_invite_link(Gid, Uid) ->
    ?INFO("Gid: ~s Uid: ~s", [Gid, Uid]),
    case model_groups:is_admin(Gid, Uid) of
        false -> {error, not_admin};
        true ->
            {IsNew, Link} = model_groups:get_invite_link(Gid),
            case IsNew =:= true of
                true -> stat:count(?STAT_NS, "create_invite_link");
                false -> ok
            end,
            ?INFO("Gid: ~s Uid: ~s Link: ~s new: ~p", [Gid, Uid, Link, IsNew]),
            maybe_clear_removed_members_set(IsNew, Gid),
            {ok, Link}
    end.


-spec reset_invite_link(Gid :: gid(), Uid :: uid()) -> {ok, Link :: binary()} | {error, term()}.
reset_invite_link(Gid, Uid) ->
    ?INFO("Gid: ~s Uid: ~s", [Gid, Uid]),
    case model_groups:is_admin(Gid, Uid) of
        false -> {error, not_admin};
        true ->
            Link = model_groups:reset_invite_link(Gid),
            ?INFO("Gid: ~s Uid: ~s Link: ~s", [Gid, Uid, Link]),
            maybe_clear_removed_members_set(true, Gid),
            stat:count(?STAT_NS, "reset_invite_link"),
            {ok, Link}
    end.


-spec preview_with_invite_link(Uid :: uid(), Link :: binary()) -> {ok, group()} | {error, term()}.
preview_with_invite_link(Uid, Link) ->
    ?INFO("Uid: ~s Link: ~s", [Uid, Link]),
    case model_groups:get_invite_link_gid(Link) of
        undefined -> {error, invalid_invite};
        Gid ->
            WasRemoved = model_groups:is_removed_member(Gid, Uid),
            if
                WasRemoved ->
                    {error, admin_removed};
                true ->
                    {ok, model_groups:get_group(Gid)}
            end
    end.


-spec web_preview_invite_link(Link :: binary()) ->
    {ok, GroupName :: binary(), Avatar :: binary() | null} | {error, term()}.
web_preview_invite_link(Link) ->
    ?INFO("Link: ~s", [Link]),
    case model_groups:get_invite_link_gid(Link) of
        undefined -> {error, invalid_invite};
        Gid ->
            case model_groups:get_group_info(Gid) of
                undefined ->
                    ?ERROR("Group not found ~p", [Gid]),
                    {error, invalid_invite};
                #group_info{name = Name, avatar = Avatar} ->
                    Avatar2 = case Avatar of
                        undefined -> null;
                        _ -> Avatar
                    end,
                    {ok, Name, Avatar2}
            end
    end.


-spec join_with_invite_link(Uid :: uid(), Link :: binary()) -> {ok, group()} | {error, term()}.
join_with_invite_link(Uid, Link) ->
    ?INFO("Uid: ~s Link: ~s", [Uid, Link]),
    case model_groups:get_invite_link_gid(Link) of
        undefined -> {error, invalid_invite};
        Gid ->
            GroupSize = model_groups:get_group_size(Gid),
            IsSizeExceeded = GroupSize + 1 > ?MAX_GROUP_SIZE,
            IsMember = model_groups:is_member(Gid, Uid),
            WasRemoved = model_groups:is_removed_member(Gid, Uid),
            if
                IsMember -> {error, already_member};
                IsSizeExceeded -> {error, max_group_size};
                WasRemoved -> {error, admin_removed};
                true ->
                    [{Uid, add, Result}] = AddResults = add_members_unsafe_2(Gid, <<"link">>, [Uid]),
                    case Result of
                        ok ->
                            log_stats(join_with_link, AddResults),
                            send_join_group_event(Gid, Uid),
                            {ok, model_groups:get_group(Gid)};
                        Error ->
                            {error, Error}
                    end
            end
    end.


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%   Internal                                                                                 %%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%


create_group_internal(Uid, GroupName) ->
    case validate_group_name(GroupName) of
        {error, Reason} -> {error, Reason};
        {ok, LGroupName} ->
            {ok, Gid} = model_groups:create_group(Uid, LGroupName),
            ?INFO("group created Gid: ~s Uid: ~s GroupName: |~s|", [Gid, Uid, LGroupName]),
            stat:count(?STAT_NS, "create"),
            stat:count(?STAT_NS, "create_by_dev", 1, [{is_dev, dev_users:is_dev_uid(Uid)}]),
            {ok, Gid}
    end.


-spec add_members_unsafe(Gid :: gid(), Uid :: uid(), MemberUids :: [uid()])
            -> modify_member_results().
add_members_unsafe(Gid, Uid, MemberUids) ->
    GroupSize = model_groups:get_group_size(Gid),
    case GroupSize + length(MemberUids) > ?MAX_GROUP_SIZE of
        true ->
            % Group size will be exceeded.
            [{Ouid, add, max_group_size} || Ouid <- MemberUids];
        false ->
            add_members_unsafe_2(Gid, Uid, MemberUids)
    end.


-spec add_members_unsafe_2(Gid :: gid(), Uid :: uid(), MemberUids :: [uid()])
            -> modify_member_results().
add_members_unsafe_2(Gid, Uid, MemberUids) ->
    GoodUids = model_accounts:filter_nonexisting_uids(MemberUids),
    RedisResults = model_groups:add_members(Gid, GoodUids, Uid),
    AddResults = lists:zip(GoodUids, RedisResults),
    Server = util:get_host(),
    % TODO: this is O(N^2), could be improved.
    Results = lists:map(
        fun (OUid) ->

            case lists:keyfind(OUid, 1, AddResults) of
                false ->
                    {OUid, add, no_account};
                {OUid, false} ->
                    {OUid, add, already_member};
                {OUid, true} ->
                    ejabberd_hooks:run(group_member_added, Server, [Gid, OUid, Uid]),
                    {OUid, add, ok}
            end
        end,
        MemberUids),
    Results.


-spec remove_members_unsafe(Gid :: gid(), MemberUids :: [uid()]) -> modify_member_results().
remove_members_unsafe(Gid, MemberUids) ->
    RedisResults = model_groups:remove_members(Gid, MemberUids),
    lists:map(
        fun
            ({Uid, true}) ->
                {Uid, remove, ok};
            ({Uid, false}) ->
                {Uid, remove, already_not_member}
        end,
        lists:zip(MemberUids, RedisResults)).



-spec split_changes(Changes :: [{uid(), atom()}], FirstListAction :: atom()) -> {[uid()], [uid()]}.
split_changes(Changes, FirstListAction) ->
    {L1, L2} = lists:partition(
        fun ({_Uid, Action}) ->
            Action == FirstListAction
        end,
        Changes),
    {[Uid || {Uid, _Action} <- L1], [Uid || {Uid, _Action} <- L2]}.


-spec maybe_delete_empty_group(Gid :: gid()) -> ok.
maybe_delete_empty_group(Gid) ->
    Size = model_groups:get_group_size(Gid),
    if
        Size =:= 0 ->
            ?INFO("Group ~s is now empty. Deleting it.", [Gid]),
            stat:count("HA/groups", "auto_delete_empty"),
            delete_group_avatar_data(Gid),
            model_groups:delete_empty_group(Gid);
        true ->
            ok
    end.


-spec validate_group_name(Name :: binary()) -> {ok, binary()} | {error, invalid_name}.
validate_group_name(<<"">>) ->
    {error, invalid_name};
validate_group_name(Name) when is_binary(Name) ->
    MaxGroupNameSize = min(byte_size(Name), ?MAX_GROUP_NAME_SIZE),
    <<LName:MaxGroupNameSize/binary, _Rest/binary>> = Name,
    case LName =:= Name of
        false -> ?WARNING("Truncating group name to |~s| size was: ~p", [LName, byte_size(Name)]);
        true -> ok
    end,
    {ok, LName};
validate_group_name(_Name) ->
    {error, invalid_name}.


-spec validate_group_description(Description :: binary()) -> {ok, binary()} | {error, invalid_description}.
validate_group_description(Description) when is_binary(Description) ->
    MaxGroupDescSize = min(byte_size(Description), ?MAX_GROUP_DESCRIPTION_SIZE),
    <<LDescription:MaxGroupDescSize/binary, _Rest/binary>> = Description,
    case LDescription =:= Description of
        false -> ?WARNING("Truncating group description to |~s| size was: ~p",
                [LDescription, byte_size(Description)]);
        true -> ok
    end,
    {ok, LDescription};
validate_group_description(Description) when Description =:= undefined ->
    {ok, <<>>};
validate_group_description(_Description) ->
    {error, invalid_description}.


-spec promote_admins_unsafe(Gid :: gid(), Uids :: [uid()])
            -> modify_admin_results().
promote_admins_unsafe(Gid, Uids) ->
    [{Uid, promote, promote_admin_unsafe(Gid, Uid)} || Uid <- Uids].


-spec promote_admin_unsafe(Gid :: gid(), Uid :: uid()) -> ok | not_member.
promote_admin_unsafe(Gid, Uid) ->
    case model_groups:promote_admin(Gid, Uid) of
        {error, not_member} ->
            not_member;
        {ok, _} ->
            ok
    end.


-spec demote_admins_unsafe(Gid :: gid(), Uids :: [uid()])
            -> modify_admin_results().
demote_admins_unsafe(Gid, Uids) ->
    [{Uid, demote, demote_admin_unsafe(Gid, Uid)} || Uid <- Uids].


-spec demote_admin_unsafe(Gid :: gid(), Uid :: uid()) -> ok | not_member.
demote_admin_unsafe(Gid, Uid) ->
    case model_groups:demote_admin(Gid, Uid) of
        {ok, not_member} ->
            not_member;
        {ok, _} ->
            ok
    end.


-spec maybe_assign_admin(Gid :: gid()) -> ok.
maybe_assign_admin(Gid) ->
    Group = model_groups:get_group(Gid),
    case Group of
        undefined -> ok;
        _ ->
            HasAdmins = lists:any(
                fun (M) ->
                    M#group_member.type =:= admin
                end,
                Group#group.members),
            if
                HasAdmins -> ok;
                length(Group#group.members) =:= 0 -> ok;
                true ->
                    % everyone in the group is member, pick first one
                    [Member | _Rest] = Group#group.members,
                    ?INFO("Gid: ~s automatically promoting Uid: ~s to admin",
                        [Gid, Member#group_member.uid]),
                    Res = promote_admins_unsafe(Gid, [Member#group_member.uid]),
                    send_auto_promote_admin_event(Gid, Res),
                    ok
            end
    end.


-spec make_chat_message(GroupInfo :: group_info(), Uid :: uid(), SenderName :: binary(),
        MessagePayload :: binary(), Ts :: integer()) -> pb_group_chat().
make_chat_message(GroupInfo, Uid, SenderName, MessagePayload, Ts) ->
    #pb_group_chat{
        gid = GroupInfo#group_info.gid,
        name = GroupInfo#group_info.name,
        avatar_id = GroupInfo#group_info.avatar,
        sender_uid = Uid,
        sender_name = SenderName,
        timestamp = Ts,
        payload = MessagePayload
    }.


-spec send_create_group_event(Group :: group(), Uid :: uid(),
        ModifyMemberResults :: modify_member_results()) -> ok.
send_create_group_event(Group, Uid, AddMemberResults) ->
    Uids = [M#group_member.uid || M <-Group#group.members],
    NamesMap = model_accounts:get_names(Uids),
    broadcast_update(Group, Uid, create, AddMemberResults, NamesMap),
    ok.


-spec send_modify_members_event(Gid :: gid(), Uid :: uid(),
        MemberResults :: modify_member_results()) -> ok.
send_modify_members_event(Gid, Uid, MemberResults) ->
    Uids = [Uid | [Ouid || {Ouid, _, _} <- MemberResults]],
    Group = model_groups:get_group(Gid),
    NamesMap = model_accounts:get_names(Uids),
    broadcast_update(Group, Uid, modify_members, MemberResults, NamesMap),
    ok.


-spec send_modify_admins_event(Gid :: gid(), Uid :: uid(),
        MemberResults :: modify_member_results()) -> ok.
send_modify_admins_event(Gid, Uid, MemberResults) ->
    Uids = [Uid | [Ouid || {Ouid, _, _} <- MemberResults]],
    Group = model_groups:get_group(Gid),
    NamesMap = model_accounts:get_names(Uids),
    broadcast_update(Group, Uid, modify_admins, MemberResults, NamesMap),
    ok.


-spec send_auto_promote_admin_event(Gid :: gid(), MemberResults :: modify_member_results()) -> ok.
send_auto_promote_admin_event(Gid, MemberResults) ->
    Uids = [Ouid || {Ouid, _, _} <- MemberResults],
    Group = model_groups:get_group(Gid),
    NamesMap = model_accounts:get_names(Uids),
    broadcast_update(Group, undefined, auto_promote_admins, MemberResults, NamesMap),
    ok.


-spec send_leave_group_event(Gid :: gid(), Uid :: uid()) -> ok.
send_leave_group_event(Gid, Uid) ->
    Group = model_groups:get_group(Gid),
    NamesMap = model_accounts:get_names([Uid]),
    broadcast_update(Group, Uid, leave, [{Uid, leave, ok}], NamesMap),
    ok.


-spec send_join_group_event(Gid :: gid(), Uid :: uid()) -> ok.
send_join_group_event(Gid, Uid) ->
    Group = model_groups:get_group(Gid),
    NamesMap = model_accounts:get_names([Uid]),
    broadcast_update(Group, Uid, join, [{Uid, join, ok}], NamesMap),
    ok.


-spec send_change_name_event(Gid :: gid(), Uid :: uid()) -> ok.
send_change_name_event(Gid, Uid) ->
    Group = model_groups:get_group(Gid),
    NamesMap = model_accounts:get_names([Uid]),
    broadcast_update(Group, Uid, change_name, [], NamesMap),
    ok.


-spec send_change_description_event(Gid :: gid(), Uid :: uid()) -> ok.
send_change_description_event(Gid, Uid) ->
    Group = model_groups:get_group(Gid),
    NamesMap = model_accounts:get_names([Uid]),
    broadcast_update(Group, Uid, change_description, [], NamesMap),
    ok.


-spec send_change_avatar_event(Gid :: gid(), Uid :: uid()) -> ok.
send_change_avatar_event(Gid, Uid) ->
    Group = model_groups:get_group(Gid),
    NamesMap = model_accounts:get_names([Uid]),
    broadcast_update(Group, Uid, change_avatar, [], NamesMap),
    ok.

-spec send_change_background_event(Gid :: gid(), Uid :: uid()) -> ok.
send_change_background_event(Gid, Uid) ->
    Group = model_groups:get_group(Gid),
    NamesMap = model_accounts:get_names([Uid]),
    broadcast_update(Group, Uid, set_background, [], NamesMap),
    ok.

% Broadcast the event to all members of the group
-spec broadcast_update(Group :: group(), Uid :: uid() | undefined, Event :: atom(),
        Results :: modify_member_results(), NamesMap :: names_map()) -> ok.
broadcast_update(Group, Uid, Event, Results, NamesMap) ->
    MembersSt = make_members_st(Event, Results, NamesMap),
    %% broadcast description only on change_description events, else- leave it undefined.
    Description = case Event of
        change_description -> Group#group.description;
        _ -> undefined
    end,

    GroupSt = #pb_group_stanza{
        gid = Group#group.gid,
        name = Group#group.name,
        avatar_id = Group#group.avatar,
        background = Group#group.background,
        sender_uid = Uid,
        sender_name = maps:get(Uid, NamesMap, undefined),
        action = Event,
        members = MembersSt,
        description = Description
    },

    Members = [M#group_member.uid || M <- Group#group.members],
    %% We also need to notify users who will be affected and broadcast the update to them as well.
    AdditionalUids = [element(1, R) || R <- Results],
    UidsToNotify = sets:from_list(Members ++ AdditionalUids),
    BroadcastUids = sets:to_list(UidsToNotify),
    Packet = #pb_msg{
        id = util_id:new_msg_id(),
        type = groupchat,
        payload = GroupSt
    },
    broadcast_packet(<<>>, BroadcastUids, Packet),
    ok.


make_members_st(Event, Results, NamesMap) ->
    MembersSt = [make_member_st(R, Event, NamesMap) || R <- Results],
    MembersSt2 = lists:filter(fun (X) -> X =/= undefined end, MembersSt),
    MembersSt2.


make_member_st({Uid, Action, Result}, Event, NamesMap) ->
    Type = case {Event, Action} of
        {create, add} -> member;
        {leave, leave} -> member;
        {join, join} -> member;
        {modify_members, add} -> member;
        {modify_members, remove} -> member;
        {modify_admins, promote} -> admin;
        {modify_admins, demote} -> member;
        {auto_promote_admins, promote} -> admin
    end,
    Name = maps:get(Uid, NamesMap, undefined),
    if
        % When we don't have an Name we don't send the update... Maybe we should...

        Result =/= ok -> undefined;
        Name =:= undefined ->
            ?ERROR("Missing name Uid: ~s, Event: ~p Action: ~p Result ~p",
                [Uid, Event, Action, Result]),
            undefined;
        true ->
            #pb_group_member{
                uid = Uid,
                type = Type,
                name = Name,
                action = Action
            }
    end.


-spec log_stats(API :: atom(), Results :: modify_results()) -> ok.
log_stats(API, Results) ->
    MetricBase = atom_to_list(API),
    lists:foreach(
        fun ({_Ouid, Action, Result}) ->
            Metric = MetricBase ++ "_" ++ atom_to_list(Action),
            case Result of
                ok ->
                    stat:count(?STAT_NS, Metric);
                Reason ->
                    stat:count(?STAT_NS, Metric ++ "_error", 1, [{error, Reason}]),
                    ok
            end
        end,
        Results).


-spec delete_group_avatar_data(Gid :: gid()) -> ok.
delete_group_avatar_data(Gid) ->
    case model_groups:get_group_info(Gid) of
        undefined -> ?WARNING("Gid: ~p already deleted", [Gid]);
        GroupInfo -> delete_group_avatar_data(Gid, GroupInfo#group_info.avatar)
    end.


-spec delete_group_avatar_data(Gid :: gid(), AvatarId :: binary()) -> ok.
delete_group_avatar_data(Gid, AvatarId) ->
    ?INFO("Gid: ~s deleting AvatarId: ~s from S3", [Gid, AvatarId]),
    % this function already logs the error.
    mod_user_avatar:delete_avatar_s3(AvatarId),
    ok.


-spec maybe_clear_removed_members_set(IsNewLink :: boolean(), Gid :: gid()) -> ok.
maybe_clear_removed_members_set(false, _Gid) ->
    % We only want to clear for new links
    ok;
maybe_clear_removed_members_set(true, Gid) ->
    ?INFO("Gid: ~s clearing the removed_members_set for", [Gid]),
    model_groups:clear_removed_members_set(Gid).


-spec update_removed_members_set(Gid :: gid(), Result :: modify_member_results()) -> ok.
update_removed_members_set(Gid, Results) ->
    % only pick the successful removes
    RemoveUids = [Uid || {Uid, remove, ok} <- Results],
    model_groups:add_removed_members(Gid, RemoveUids),
    AddUids = [Uid || {Uid, add, ok} <- Results],
    model_groups:remove_removed_members(Gid, AddUids),
    ok.

