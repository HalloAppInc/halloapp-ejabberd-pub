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
    get_group_info/2,
    get_groups/1,
    remove_user/2,
    set_name/3,
    set_avatar/3,
    delete_avatar/2,
    send_chat_message/4,
    broadcast_packet/4,
    send_retract_message/4,
    send_feed_item/3
]).

-include("logger.hrl").
-include("xmpp.hrl").
-include("groups.hrl").
-include("feed.hrl").

-define(MAX_GROUP_SIZE, 25).
-define(MAX_GROUP_NAME_SIZE, 25).

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
    [{mod_redis, hard}].


mod_options(_Host) ->
    [].

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%   API                                                                                      %%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

-type modify_member_result() :: {uid(), add | remove, ok | no_account | max_group_size}.
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
            Packet = #message{
                id = MsgId,
                type = groupchat,
                sub_els = [GroupMessage]
            },
            From = jid:make(Uid, Server),
            MUids = model_groups:get_member_uids(Gid),	
            ReceiverUids = lists:delete(Uid, MUids),
            stat:count(?STAT_NS, "send_im"),
            stat:count(?STAT_NS, "recv_im", length(ReceiverUids)),
            broadcast_packet(From, Server, ReceiverUids, Packet),
            {ok, Ts}
    end.


-spec send_retract_message(MsgId :: binary(), Gid :: gid(), Uid :: uid(),
        GroupChatRetractSt :: groupchat_retract_st()) -> {ok, Ts} | {error, atom()}
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
            Server = util:get_host(),
            Packet = #message{
                id = MsgId,
                type = groupchat,
                sub_els = [GroupChatRetractSt]
            },
            From = jid:make(Uid, Server),
            MUids = model_groups:get_member_uids(Gid),
            ReceiverUids = lists:delete(Uid, MUids),
            broadcast_packet(From, Server, ReceiverUids, Packet),
            {ok, Ts}
    end.


-spec broadcast_packet(From :: jid(), Server :: binary(), BroadcastUids :: [uid()],
            Packet :: message() | chat_state()) -> ok.
broadcast_packet(From, Server, BroadcastUids, Packet) ->
    BroadcastJids = util:uids_to_jids(BroadcastUids, Server),
    ?INFO("Uid: ~s, receiver uids: ~p", [From#jid.luser, BroadcastJids]),
    ejabberd_router_multicast:route_multicast(From, Server, BroadcastJids, Packet),
    ok.


%% TODO(murali@): temporary code: remove it in 1month.
-spec send_feed_item(Gid :: gid(), Uid :: uid(), GroupFeedSt :: group_feed_st())
            -> {ok, Ts} | {error, atom()}
            when Ts :: non_neg_integer().
send_feed_item(Gid, Uid, GroupFeedSt) ->
    ?INFO("Gid: ~s Uid: ~s", [Gid, Uid]),
    case model_groups:check_member(Gid, Uid) of
        false ->
            %% also possible the group does not exists
            {error, not_member};
        true ->
            %% TODO(murali@): log stats for different group-feed activity.
            Ts = util:now(),
            GroupInfo = model_groups:get_group_info(Gid),
            {ok, SenderName} = model_accounts:get_name(Uid),
            NewGroupFeedSt = make_group_feed_st(GroupInfo, Uid, SenderName, GroupFeedSt, Ts),
            ?INFO("Fan Out MSG: ~p", [GroupFeedSt]),
            Server = util:get_host(),
            Packet = #message{
                id = util:new_msg_id(),
                type = groupchat,
                sub_els = [NewGroupFeedSt]
            },
            From = jid:make(Uid, Server),
            MUids = model_groups:get_member_uids(Gid),
            ReceiverUids = lists:delete(Uid, MUids),
            broadcast_packet(From, Server, ReceiverUids, Packet),
            {ok, NewGroupFeedSt}
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
    model_groups:add_members(Gid, GoodUids, Uid),
    lists:map(
        fun (OUid) ->
            case lists:member(OUid, GoodUids) of
                false ->
                    {OUid, add, no_account};
                true ->
                    {OUid, add, ok}
            end
        end,
        MemberUids).


-spec remove_members_unsafe(Gid :: gid(), MemberUids :: [uid()]) -> modify_member_results().
remove_members_unsafe(Gid, MemberUids) ->
    {ok, _} = model_groups:remove_members(Gid, MemberUids),
    [{Uid, remove, ok} || Uid <- MemberUids].


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
    LName = string:slice(Name, 0, ?MAX_GROUP_NAME_SIZE),
    case LName =:= Name of
        false -> ?WARNING("Truncating group name to |~s| size was: ~p", [LName, byte_size(Name)]);
        true -> ok
    end,
    {ok, LName};
validate_group_name(_Name) ->
    {error, invalid_name}.


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
        MessagePayload :: binary(), Ts :: integer()) -> group_chat().
make_chat_message(GroupInfo, Uid, SenderName, MessagePayload, Ts) ->
    #group_chat{
        xmlns = ?NS_GROUPS,
        gid = GroupInfo#group_info.gid,
        name = GroupInfo#group_info.name,
        avatar = GroupInfo#group_info.avatar,
        sender = Uid,
        sender_name = SenderName,
        timestamp = integer_to_binary(Ts),
        sub_els = MessagePayload
    }.


%% TODO(murali@): temporary code: remove it in 1month.
-spec make_group_feed_st(GroupInfo :: group_info(), Uid :: uid(), SenderName :: binary(),
        GroupFeedSt :: group_feed_st(), Ts :: integer()) -> group_chat().
make_group_feed_st(GroupInfo, Uid, SenderName, GroupFeedSt, Ts) ->
    TsBin = integer_to_binary(Ts),
    Posts = case GroupFeedSt#group_feed_st.posts of
        [] -> [];
        [P] -> [P#group_post_st{publisher_uid = Uid, publisher_name = SenderName, timestamp = TsBin}]
    end,
    Comments = case GroupFeedSt#group_feed_st.comments of
        [] -> [];
        [C] -> [C#group_comment_st{publisher_uid = Uid, publisher_name = SenderName, timestamp = TsBin}]
    end,
    GroupFeedSt#group_feed_st{
        gid = GroupInfo#group_info.gid,
        name = GroupInfo#group_info.name,
        avatar_id = GroupInfo#group_info.avatar,
        posts = Posts,
        comments = Comments
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


-spec send_change_name_event(Gid :: gid(), Uid :: uid()) -> ok.
send_change_name_event(Gid, Uid) ->
    Group = model_groups:get_group(Gid),
    NamesMap = model_accounts:get_names([Uid]),
    broadcast_update(Group, Uid, change_name, [], NamesMap),
    ok.


-spec send_change_avatar_event(Gid :: gid(), Uid :: uid()) -> ok.
send_change_avatar_event(Gid, Uid) ->
    Group = model_groups:get_group(Gid),
    NamesMap = model_accounts:get_names([Uid]),
    broadcast_update(Group, Uid, change_avatar, [], NamesMap),
    ok.


% Broadcast the event to all members of the group
-spec broadcast_update(Group :: group(), Uid :: uid() | undefined, Event :: atom(),
        Results :: modify_member_results(), NamesMap :: names_map()) -> ok.
broadcast_update(Group, Uid, Event, Results, NamesMap) ->
    MembersSt = make_members_st(Event, Results, NamesMap),

    GroupSt = #group_st{
        gid = Group#group.gid,
        name = Group#group.name,
        avatar = Group#group.avatar,
        sender = Uid,
        sender_name = maps:get(Uid, NamesMap, undefined),
        action = Event,
        members = MembersSt
    },

    Members = [M#group_member.uid || M <- Group#group.members],
    %% We also need to notify users who will be affected and broadcast the update to them as well.
    AdditionalUids = [element(1, R) || R <- Results],
    UidsToNotify = sets:from_list(Members ++ AdditionalUids),
    BroadcastUids = sets:to_list(UidsToNotify),
    Server = util:get_host(),
    From = jid:make(Server),
    Packet = #message{
        id = util:new_msg_id(),
        type = groupchat,
        sub_els = [GroupSt]
    },
    broadcast_packet(From, Server, BroadcastUids, Packet),
    ok.


make_members_st(Event, Results, NamesMap) ->
    MembersSt = [make_member_st(R, Event, NamesMap) || R <- Results],
    MembersSt2 = lists:filter(fun (X) -> X =/= undefined end, MembersSt),
    MembersSt2.


make_member_st({Uid, Action, Result}, Event, NamesMap) ->
    Type = case {Event, Action} of
        {create, add} -> member;
        {leave, leave} -> member;
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
            #member_st{
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
    GroupInfo = model_groups:get_group_info(Gid),
    delete_group_avatar_data(Gid, GroupInfo#group_info.avatar).


-spec delete_group_avatar_data(Gid :: gid(), AvatarId :: binary()) -> ok.
delete_group_avatar_data(Gid, AvatarId) ->
    ?INFO("Gid: ~s deleting AvatarId: ~s from S3", [Gid, AvatarId]),
    % this function already logs the error.
    mod_user_avatar:delete_avatar_s3(AvatarId),
    ok.

