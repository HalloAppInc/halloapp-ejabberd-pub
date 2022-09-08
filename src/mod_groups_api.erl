%%%-------------------------------------------------------------------
%%% @author nikola
%%% @copyright (C) 2020, HalloApp, Inc.
%%% @doc
%%%
%%% @end
%%% Created : 10. Jun 2020 10:00 AM
%%%-------------------------------------------------------------------
-module(mod_groups_api).
-author("nikola").
-behaviour(gen_mod).

%% gen_mod api
-export([start/2, stop/1, mod_options/1, depends/2]).

-export([
    send_group_message/1,
    process_local_iq/1
]).

-include("logger.hrl").
-include("groups.hrl").
-include("packets.hrl").


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%   gen_mod API                                                                              %%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%


start(Host, _Opts) ->
    ?INFO("start", []),
    gen_iq_handler:add_iq_handler(ejabberd_local, Host, pb_group_stanza, ?MODULE, process_local_iq),
    gen_iq_handler:add_iq_handler(ejabberd_local, Host, pb_groups_stanza, ?MODULE, process_local_iq),
    gen_iq_handler:add_iq_handler(ejabberd_local, Host, pb_upload_group_avatar, ?MODULE, process_local_iq),
    gen_iq_handler:add_iq_handler(ejabberd_local, Host, pb_group_invite_link, ?MODULE, process_local_iq),
    ejabberd_hooks:add(group_message, Host, ?MODULE, send_group_message, 50),
    ok.


stop(Host) ->
    ?INFO("stop", []),
    gen_iq_handler:remove_iq_handler(ejabberd_local, Host, pb_group_stanza),
    gen_iq_handler:remove_iq_handler(ejabberd_local, Host, pb_groups_stanza),
    gen_iq_handler:remove_iq_handler(ejabberd_local, Host, pb_upload_group_avatar),
    gen_iq_handler:remove_iq_handler(ejabberd_local, Host, pb_group_invite_link),
    ejabberd_hooks:delete(group_message, Host, ?MODULE, send_group_message, 50),
    ok.


depends(_Host, _Opts) ->
    [{mod_groups, hard}].


mod_options(_Host) ->
    [].


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%   API                                                                                      %%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%%% group_message %%%
send_group_message(#pb_msg{id = MsgId, from_uid = Uid, type = groupchat,
        payload = #pb_group_chat{gid = Gid} = GroupChatSt} = Msg) ->
    ?INFO("Gid: ~s, Uid: ~s", [Gid, Uid]),
    MessagePayload = GroupChatSt#pb_group_chat.payload,
    case mod_groups:send_chat_message(MsgId, Gid, Uid, MessagePayload) of
        {error, Reason} ->
            ErrorMsg = pb:make_error(Msg, util:err(Reason)),
            ejabberd_router:route(ErrorMsg);
        {ok, _Ts} ->
            ok
    end,
    ok;

send_group_message(#pb_msg{id = MsgId, from_uid = Uid, type = groupchat,
        payload = #pb_group_chat_retract{gid = Gid} = GroupChatRetractSt} = Msg) ->
    ?INFO("Gid: ~s, Uid: ~s", [Gid, Uid]),
    case mod_groups:send_retract_message(MsgId, Gid, Uid, GroupChatRetractSt) of
        {error, Reason} ->
            ErrorMsg = pb:make_error(Msg, util:err(Reason)),
            ejabberd_router:route(ErrorMsg);
        {ok, _Ts} ->
            ok
    end,
    ok.


%%% create_group %%%
process_local_iq(#pb_iq{from_uid = Uid, type = set,
        payload = #pb_group_stanza{action = create, name = Name, expiry_info = Expiry} = ReqGroupSt} = IQ) ->
    process_create_group(IQ, Uid, Name, Expiry, ReqGroupSt);


%%% delete_group %%%
process_local_iq(#pb_iq{from_uid = Uid, type = set,
        payload = #pb_group_stanza{action = delete, gid = Gid} = _ReqGroupSt} = IQ) ->
    process_delete_group(IQ, Gid, Uid);


%%% modify_members %%%
process_local_iq(#pb_iq{from_uid = Uid, type = set,
        payload = #pb_group_stanza{action = modify_members, gid = Gid} = ReqGroupSt} = IQ) ->
    process_modify_members(IQ, Gid, Uid, ReqGroupSt);


%%% share_history %%%
process_local_iq(#pb_iq{from_uid = Uid, type = set,
        payload = #pb_group_stanza{action = share_history, gid = Gid} = ReqGroupSt} = IQ) ->
    process_share_history(IQ, Gid, Uid, ReqGroupSt);


%%% modify_admins %%%
process_local_iq(#pb_iq{from_uid = Uid, type = set,
        payload = #pb_group_stanza{action = modify_admins, gid = Gid} = ReqGroupSt} = IQ) ->
    process_modify_admins(IQ, Gid, Uid, ReqGroupSt);


%%% get_group %%%
process_local_iq(#pb_iq{from_uid = Uid, type = get,
        payload = #pb_group_stanza{action = get, gid = Gid} = _ReqGroupSt} = IQ) ->
    process_get_group(IQ, Gid, Uid);


%%% get_member_identity_keys %%%
process_local_iq(#pb_iq{from_uid = Uid, type = get,
        payload = #pb_group_stanza{action = get_member_identity_keys, gid = Gid} = _ReqGroupSt} = IQ) ->
    process_get_member_identity_keys(IQ, Gid, Uid);


%%% get_groups %%%
process_local_iq(#pb_iq{from_uid = Uid, type = get,
        payload = #pb_groups_stanza{action = get}} = IQ) ->
    process_get_groups(IQ, Uid);


%%% set_name %%%
process_local_iq(#pb_iq{from_uid = Uid, type = set,
        payload = #pb_group_stanza{action = set_name, gid = Gid, name = Name} = _ReqGroupSt} = IQ) ->
    process_set_name(IQ, Gid, Uid, Name);


%%% set_expiry %%%
process_local_iq(#pb_iq{from_uid = Uid, type = set,
        payload = #pb_group_stanza{action = change_expiry, gid = Gid, expiry_info = Expiry} = _ReqGroupSt} = IQ) ->
    process_set_expiry(IQ, Gid, Uid, Expiry);


%%% set_description %%%
process_local_iq(#pb_iq{from_uid = Uid, type = set,
        payload = #pb_group_stanza{action = change_description,
        gid = Gid, description = Description} = _ReqGroupSt} = IQ) ->
    process_set_description(IQ, Gid, Uid, Description);


%%% delete_avatar
process_local_iq(#pb_iq{from_uid = Uid, type = set,
        payload = #pb_upload_group_avatar{gid = Gid, data = undefined}} = IQ) ->
    process_delete_avatar(IQ, Gid, Uid);


%%% set_avatar
process_local_iq(#pb_iq{from_uid = Uid, type = set,
        payload = #pb_upload_group_avatar{gid = Gid, data = Data, full_data = FullData}} = IQ) ->
    %% TODO(murali@): remove this case after 12-08-2021.
    FinalFullData = case FullData of
        undefined -> Data;
        _ -> FullData
    end,
    process_set_avatar(IQ, Gid, Uid, Data, FinalFullData);

%%% set_background
process_local_iq(#pb_iq{from_uid = Uid, type = set,
        payload = #pb_group_stanza{action = set_background, gid = Gid, background = Background}} = IQ) ->
    process_set_background(IQ, Gid, Uid, Background);

%%% leave_group %%%
process_local_iq(#pb_iq{from_uid = Uid, type = set,
        payload = #pb_group_stanza{action = leave, gid = Gid}} = IQ) ->
    process_leave_group(IQ, Gid, Uid);


%%% get_invite_link %%%
process_local_iq(#pb_iq{from_uid = Uid, type = get,
        payload = #pb_group_invite_link{action = get, gid = Gid}} = IQ) ->
    process_get_invite_link(IQ, Gid, Uid);


%%% reset_invite_link %%%
process_local_iq(#pb_iq{from_uid = Uid, type = set,
        payload = #pb_group_invite_link{action = reset, gid = Gid}} = IQ) ->
    process_reset_invite_link(IQ, Gid, Uid);


%%% preview_with_invite_link %%%
process_local_iq(#pb_iq{from_uid = Uid, type = get,
    payload = #pb_group_invite_link{action = preview, link = Link}} = IQ) ->
    process_preview_with_invite_link(IQ, Uid, Link);


%%% join_with_invite_link %%%
process_local_iq(#pb_iq{from_uid = Uid, type = set,
        payload = #pb_group_invite_link{action = join, link = Link}} = IQ) ->
    process_join_with_invite_link(IQ, Uid, Link).


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%   Internal                                                                                 %%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%


-spec process_create_group(IQ :: iq(), Uid :: uid(),
        Name :: binary(), Expiry :: pb_expiry_info(), ReqGroupSt :: pb_group_stanza()) -> iq().
process_create_group(IQ, Uid, Name, Expiry, ReqGroupSt) ->
    ?INFO("create_group Uid: ~s Name: |~s| Expiry: ~s Group: ~p", [Uid, Name, Expiry, ReqGroupSt]),
    MemberUids = [M#pb_group_member.uid || M <- ReqGroupSt#pb_group_stanza.members],
    GroupType = ReqGroupSt#pb_group_stanza.group_type,

    {ok, Group, Results} = mod_groups:create_group(Uid, Name, GroupType, Expiry, MemberUids),

    MembersSt = lists:map(
        fun ({MemberUid, add, Result}) ->
            Type = case MemberUid =:= Uid of
                true -> admin;
                false -> member
            end,
            make_member_st(MemberUid, Result, Type)
        end,
        Results),

    GroupStResult = #pb_group_stanza{
        gid = Group#group.gid,
        name = Group#group.name,
        expiry_info = make_pb_expiry_info(Group#group.expiry_info),
        group_type = Group#group.group_type,
        action = create,
        members = MembersSt
    },
    pb:make_iq_result(IQ, GroupStResult).


-spec process_delete_group(IQ :: iq(), Gid :: gid(), Uid :: uid()) -> iq().
process_delete_group(IQ, Gid, Uid) ->
    ?INFO("delete_group Gid: ~s Uid: ~s", [Gid, Uid]),
    case mod_groups:delete_group(Gid, Uid) of
        {error, not_admin} ->
            pb:make_error(IQ, util:err(not_admin));
        ok ->
            pb:make_iq_result(IQ)
    end.


-spec process_modify_members(IQ :: iq(), Gid :: gid(), Uid :: uid(), ReqGroupSt :: pb_group_stanza())
            -> iq().
process_modify_members(IQ, Gid, Uid, ReqGroupSt) ->
    MembersSt = ReqGroupSt#pb_group_stanza.members,
    Changes = [{M#pb_group_member.uid, M#pb_group_member.action} || M <- MembersSt],
    PBHistoryResend = ReqGroupSt#pb_group_stanza.history_resend,
    ?INFO("modify_members Gid: ~s Uid: ~s Changes: ~p", [Gid, Uid, Changes]),
    case mod_groups:modify_members(Gid, Uid, Changes, PBHistoryResend) of
        {error, Reason} ->
            pb:make_error(IQ, util:err(Reason));
        {ok, ModifyResults} ->
            ResultMemberSt = lists:map(
                fun ({Ouid, Action, Result}) ->
                    make_member_st(Ouid, Result, member, Action)
                end,
                ModifyResults),

            GroupStResult = #pb_group_stanza{
                gid = Gid,
                action = modify_members,
                members = ResultMemberSt
            },
            pb:make_iq_result(IQ, GroupStResult)
    end.


-spec process_share_history(IQ :: iq(), Gid :: gid(), Uid :: uid(), ReqGroupSt :: pb_group_stanza())
            -> iq().
process_share_history(IQ, Gid, Uid, ReqGroupSt) ->
    MembersSt = ReqGroupSt#pb_group_stanza.members,
    UidsToShare = [ M#pb_group_member.uid || M <- MembersSt],
    PBHistoryResend = ReqGroupSt#pb_group_stanza.history_resend,
    ?INFO("share_history Gid: ~s Uid: ~s UidsToShare: ~p", [Gid, Uid, UidsToShare]),
    case mod_groups:share_history(Gid, Uid, UidsToShare, PBHistoryResend) of
        {error, Reason} ->
            pb:make_error(IQ, util:err(Reason));
        {ok, ShareHistoryResults} ->
            ResultMemberSt = lists:map(
                fun ({Ouid, Action, Result}) ->
                    make_member_st(Ouid, Result, member, Action)
                end,
                ShareHistoryResults),

            GroupStResult = #pb_group_stanza{
                gid = Gid,
                action = share_history,
                members = ResultMemberSt
            },
            pb:make_iq_result(IQ, GroupStResult)
    end.


-spec process_modify_admins(IQ :: iq(), Gid :: gid(), Uid :: uid(), ReqGroupSt :: pb_group_stanza())
            -> iq().
process_modify_admins(IQ, Gid, Uid, ReqGroupSt) ->
    MembersSt = ReqGroupSt#pb_group_stanza.members,
    Changes = [{M#pb_group_member.uid, M#pb_group_member.action} || M <- MembersSt],
    ?INFO("modify_admins Gid: ~s Uid: ~s Changes: ~p", [Gid, Uid, Changes]),

    case mod_groups:modify_admins(Gid, Uid, Changes) of
        {error, not_admin} ->
            pb:make_error(IQ, util:err(not_admin));
        {ok, ModifyResults} ->

            ResultMemberSt = lists:map(
                fun ({Ouid, Action, Result}) ->
                    Type = case Action of promote -> admin; demote -> member end,
                    make_member_st(Ouid, Result, Type, Action)
                end,
                ModifyResults),

            GroupStResult = #pb_group_stanza{
                gid = Gid,
                action = modify_admins,
                members = ResultMemberSt,
                avatar_id = undefined,
                sender_name = undefined
            },
            pb:make_iq_result(IQ, GroupStResult)
    end.


-spec process_get_group(IQ :: iq(), Gid :: gid(), Uid :: uid()) -> iq().
process_get_group(IQ, Gid, Uid) ->
    ?INFO("get_group Gid: ~s Uid: ~s", [Gid, Uid]),
    case mod_groups:get_group(Gid, Uid) of
        {error, not_member} ->
            pb:make_error(IQ, util:err(not_member));
        {ok, Group} ->
            GroupSt = make_group_st(Group, get),
            pb:make_iq_result(IQ, GroupSt)
    end.


-spec process_get_member_identity_keys(IQ :: iq(), Gid :: gid(), Uid :: uid()) -> iq().
process_get_member_identity_keys(IQ, Gid, Uid) ->
    ?INFO("get_member_identity_keys Gid: ~s Uid: ~s", [Gid, Uid]),
    case mod_groups:get_member_identity_keys(Gid, Uid) of
        {error, not_member} ->
            pb:make_error(IQ, util:err(not_member));
        {ok, Group} ->
            GroupSt = make_group_st(Group, get_member_identity_keys),
            pb:make_iq_result(IQ, GroupSt)
    end.


-spec process_get_groups(IQ :: iq(), Uid :: uid()) -> iq().
process_get_groups(IQ, Uid) ->
    ?INFO("get_groups Uid: ~s", [Uid]),
    GroupInfos = mod_groups:get_groups(Uid),
    GroupsSt = [group_info_to_group_st(GI) || GI <- GroupInfos],
    ResultSt = #pb_groups_stanza{
        action = get,
        group_stanzas = GroupsSt
    },
    pb:make_iq_result(IQ, ResultSt).


-spec process_set_name(IQ :: iq(), Gid :: gid(), Uid :: uid(), Name :: binary()) -> iq().
process_set_name(IQ, Gid, Uid, Name) ->
    ?INFO("set_name Gid: ~s Uid: ~s Name: |~p|", [Gid, Uid, Name]),
    case mod_groups:set_name(Gid, Uid, Name) of
        {error, invalid_name} ->
            pb:make_error(IQ, util:err(invalid_name));
        {error, not_member} ->
            pb:make_error(IQ, util:err(not_member));
        ok ->
            {ok, GroupInfo} = mod_groups:get_group_info(Gid, Uid),
            pb:make_iq_result(IQ, group_info_to_group_st(GroupInfo))
    end.


-spec process_set_expiry(IQ :: iq(), Gid :: gid(), Uid :: uid(), Expiry :: pb_expiry_info()) -> iq().
process_set_expiry(IQ, Gid, Uid, Expiry) ->
    ?INFO("set_expiry Gid: ~s Uid: ~s Expiry: |~p|", [Gid, Uid, Expiry]),
    case mod_groups:set_expiry(Gid, Uid, Expiry) of
        {error, Reason} ->
            pb:make_error(IQ, util:err(Reason));
        ok ->
            {ok, GroupInfo} = mod_groups:get_group_info(Gid, Uid),
            pb:make_iq_result(IQ, group_info_to_group_st_with_expiry(GroupInfo))
    end.


-spec process_set_description(IQ :: iq(), Gid :: gid(), Uid :: uid(), Description :: binary()) -> iq().
process_set_description(IQ, Gid, Uid, Description) ->
    ?INFO("set_description Gid: ~s Uid: ~s Description: |~p|", [Gid, Uid, Description]),
    case mod_groups:set_description(Gid, Uid, Description) of
        {error, invalid_description} ->
            pb:make_error(IQ, util:err(invalid_description));
        {error, not_member} ->
            pb:make_error(IQ, util:err(not_member));
        ok ->
            {ok, GroupInfo} = mod_groups:get_group_info(Gid, Uid),
            pb:make_iq_result(IQ, group_info_to_group_st(GroupInfo))
    end.


process_delete_avatar(IQ, Gid, Uid) ->
    ?INFO("Gid: ~s Uid: ~s", [Gid, Uid]),
    case mod_groups:delete_avatar(Gid, Uid) of
        {error, Reason} ->
            pb:make_error(IQ, util:err(Reason));
        {ok, GroupName} ->
            GroupSt = #pb_group_stanza{
                gid = Gid,
                name = GroupName,
                avatar_id = <<>>
            },
            pb:make_iq_result(IQ, GroupSt)
    end.


process_set_avatar(IQ, Gid, Uid, Data, FullData) ->
    ?INFO("set_avatar Gid: ~s Uid: ~s SmallSize: ~p, FullSize: ~p",
        [Gid, Uid, byte_size(Data), byte_size(FullData)]),
    case set_avatar(Gid, Uid, Data, FullData) of
        {error, Reason} ->
            ?WARNING("Gid: ~s Uid ~s setting avatar failed ~p", [Gid, Uid, Reason]),
            pb:make_error(IQ, util:err(Reason));
        {ok, AvatarId, GroupName} ->
            ?INFO("Gid: ~s Uid: ~s Successfully set avatar ~s",
                [Gid, Uid, AvatarId]),
            GroupSt = #pb_group_stanza{
                gid = Gid,
                name = GroupName,
                avatar_id = AvatarId
            },
            pb:make_iq_result(IQ, GroupSt)
    end.


-spec set_avatar(Gid :: gid(), Uid :: uid(), Data :: binary(), FullData :: binary()) ->
        {ok, AvatarId :: binary(), GroupName :: binary()} | {error, atom()}.
set_avatar(Gid, Uid, Data, FullData) ->
    case model_groups:check_member(Gid, Uid) of
        false -> {error, not_member};
        true ->
            case mod_user_avatar:check_and_upload_avatar(Data, FullData) of
                {error, Reason} -> {error, Reason};
                {ok, AvatarId} ->
                    mod_groups:set_avatar(Gid, Uid, AvatarId)
            end
    end.

process_set_background(IQ, Gid, Uid, Background) ->
    ByteSize = case Background of
        undefined -> 0;
        _ -> byte_size(Background)
    end,
    ?INFO("set_background Gid: ~s Uid: ~s Size: ~p", [Gid, Uid, ByteSize]),
    case mod_groups:set_background(Gid, Uid, Background) of
        {error, Reason} ->
            ?WARNING("Gid: ~s Uid ~s setting background failed ~p", [Gid, Uid, Reason]),
            pb:make_error(IQ, util:err(Reason));
        {ok, Background} ->
            ?INFO("Gid: ~s Uid: ~s Successfully set background ~s",
                [Gid, Uid, Background]),
            GroupSt = #pb_group_stanza{
                gid = Gid,
                background = Background
            },
            pb:make_iq_result(IQ, GroupSt)
    end.


-spec process_leave_group(IQ :: iq(), Gid :: gid(), Uid :: uid()) -> iq().
process_leave_group(IQ, Gid, Uid) ->
    ?INFO("leave_group Gid: ~s Uid: ~s ", [Gid, Uid]),
    case mod_groups:leave_group(Gid, Uid) of
        {ok, _Res} ->
            pb:make_iq_result(IQ)
    end.


-spec process_get_invite_link(IQ :: iq(), Gid :: gid(), Uid :: uid()) -> iq().
process_get_invite_link(IQ, Gid, Uid) ->
    ?INFO("Gid: ~s Uid: ~s ", [Gid, Uid]),
    case mod_groups:get_invite_link(Gid, Uid) of
        {error, Reason} ->
            ?WARNING("Gid: ~s Uid ~s failed ~p", [Gid, Uid, Reason]),
            pb:make_error(IQ, util:err(Reason));
        {ok, Link} ->
            ?INFO("Gid: ~s Uid: ~s success Link: ~s",
                [Gid, Uid, Link]),
            ha_events:log_user_event(Uid, group_invite_recorded),
            PB = #pb_group_invite_link{
                action = get,
                gid = Gid,
                link = Link
            },
            pb:make_iq_result(IQ, PB)
    end.


-spec process_reset_invite_link(IQ :: iq(), Gid :: gid(), Uid :: uid()) -> iq().
process_reset_invite_link(IQ, Gid, Uid) ->
    ?INFO("Gid: ~s Uid: ~s ", [Gid, Uid]),
    case mod_groups:reset_invite_link(Gid, Uid) of
        {error, Reason} ->
            ?WARNING("Gid: ~s Uid ~s failed ~p", [Gid, Uid, Reason]),
            pb:make_error(IQ, util:err(Reason));
        {ok, Link} ->
            ?INFO("Gid: ~s Uid: ~s success Link: ~s",
                [Gid, Uid, Link]),
            ha_events:log_user_event(Uid, group_invite_recorded),
            PB = #pb_group_invite_link{
                action = reset,
                gid = Gid,
                link = Link
            },
            pb:make_iq_result(IQ, PB)
    end.


-spec process_preview_with_invite_link(IQ :: iq(), Uid :: uid(), Link :: binary()) -> iq().
process_preview_with_invite_link(IQ, Uid, Link) ->
    ?INFO("Uid: ~s Link: ~s", [Uid, Link]),
    case mod_groups:preview_with_invite_link(Uid, Link) of
        {error, Reason} ->
            ?WARNING("Uid: ~s Link: ~s failed ~p", [Uid, Link, Reason]),
            pb:make_error(IQ, util:err(Reason));
        {ok, Group} ->
            ?INFO("Uid: ~s success Link: ~s",
                [Uid, Link]),
            PB = #pb_group_invite_link{
                action = preview,
                gid = Group#group.gid,
                link = Link,
                group = make_group_st(Group, preview)
            },
            pb:make_iq_result(IQ, PB)
    end.


-spec process_join_with_invite_link(IQ :: iq(), Uid :: uid(), FullLink :: binary()) -> iq().
process_join_with_invite_link(IQ, Uid, Link) ->
    ?INFO("Uid: ~s Link: ~s", [Uid, Link]),
    case mod_groups:join_with_invite_link(Uid, Link) of
        {error, Reason} ->
            ?WARNING("Uid: ~s Link: ~s failed ~p", [Uid, Link, Reason]),
            pb:make_error(IQ, util:err(Reason));
        {ok, Group} ->
            Gid = Group#group.gid,
            ?INFO("Uid: ~s success Link: ~s, Gid: ~s",
                [Uid, Link, Gid]),
            ha_events:log_user_event(Uid, group_invite_accepted),
            PB = #pb_group_invite_link{
                action = join,
                gid = Gid,
                link = Link,
                group = make_group_st(Group, join)
            },
            pb:make_iq_result(IQ, PB)
    end.


-spec group_info_to_group_st(GroupInfo :: group_info()) -> pb_group_stanza().
group_info_to_group_st(GroupInfo) ->
    #pb_group_stanza{
        gid = GroupInfo#group_info.gid,
        name = GroupInfo#group_info.name,
        description = GroupInfo#group_info.description,
        avatar_id = GroupInfo#group_info.avatar,
        background = GroupInfo#group_info.background,
        group_type = GroupInfo#group_info.group_type
    }.


-spec group_info_to_group_st_with_expiry(GroupInfo :: group_info()) -> pb_group_stanza().
group_info_to_group_st_with_expiry(GroupInfo) ->
    #pb_group_stanza{
        gid = GroupInfo#group_info.gid,
        name = GroupInfo#group_info.name,
        description = GroupInfo#group_info.description,
        avatar_id = GroupInfo#group_info.avatar,
        background = GroupInfo#group_info.background,
        expiry_info = make_pb_expiry_info(GroupInfo#group_info.expiry_info),
        group_type = GroupInfo#group_info.group_type
    }.


-spec make_group_st(Group :: group(), Action :: atom()) -> pb_group_stanza().
make_group_st(Group, Action) ->
    Description = case Action of
        _ when Action =:= get; Action =:= preview; Action =:= join ->
            Group#group.description;
        _ -> undefined
    end,
    #pb_group_stanza{
        action = Action,
        gid = Group#group.gid,
        name = Group#group.name,
        description = Description,
        avatar_id = Group#group.avatar,
        background = Group#group.background,
        expiry_info = make_pb_expiry_info(Group#group.expiry_info),
        group_type = Group#group.group_type,
        members = make_members_st(Group#group.members),
        audience_hash = Group#group.audience_hash
    }.


-spec make_members_st(Members :: [group_member()]) -> [pb_group_member()].
make_members_st(Members) ->
    MemberUids = [M#group_member.uid || M <- Members],
    NamesMap = model_accounts:get_names(MemberUids),
    [#pb_group_member{
        uid = M#group_member.uid,
        type = M#group_member.type,
        name = maps:get(M#group_member.uid, NamesMap, undefined),
        identity_key = M#group_member.identity_key
    } || M <- Members].


make_member_st(MemberUid, Result, Type, Action) ->
    S = make_member_st(MemberUid, Result, Type),
    S#pb_group_member{action = Action}.


make_member_st(MemberUid, Result, Type) ->
    M = #pb_group_member{
        uid = MemberUid,
        type = Type
    },
    M2 = case Result of
        ok ->
            M#pb_group_member{result = <<"ok">>, reason = undefined};
        Result when is_atom(Result) ->
            M#pb_group_member{result = <<"failed">>, reason = util:to_binary(Result)}
    end,
    M2.


make_pb_expiry_info(ExpiryInfo) ->
    #pb_expiry_info{
        expiry_type = ExpiryInfo#expiry_info.expiry_type,
        expires_in_seconds = ExpiryInfo#expiry_info.expires_in_seconds,
        expiry_timestamp = ExpiryInfo#expiry_info.expiry_timestamp
    }.

