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
-include("xmpp.hrl").
-include("groups.hrl").
-include ("packets.hrl").


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%   gen_mod API                                                                              %%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%


start(Host, _Opts) ->
    ?INFO("start", []),
    gen_iq_handler:add_iq_handler(ejabberd_local, Host, ?NS_GROUPS, ?MODULE, process_local_iq),
    gen_iq_handler:add_iq_handler(ejabberd_local, Host, pb_upload_group_avatar, ?MODULE, process_local_iq),
    ejabberd_hooks:add(group_message, Host, ?MODULE, send_group_message, 50),
    ok.


stop(Host) ->
    ?INFO("stop", []),
    gen_iq_handler:remove_iq_handler(ejabberd_local, Host, ?NS_GROUPS),
    gen_iq_handler:remove_iq_handler(ejabberd_local, Host, pb_upload_group_avatar),
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
send_group_message(#message{id = MsgId, from = #jid{luser = Uid}, type = groupchat,
        sub_els = [#group_chat{gid = Gid} = GroupChatSt]} = Msg) ->
    ?INFO("Gid: ~s, Uid: ~s", [Gid, Uid]),
    MessagePayload = GroupChatSt#group_chat.sub_els,
    case mod_groups:send_chat_message(MsgId, Gid, Uid, MessagePayload) of
        {error, Reason} ->
            ErrorMsg = xmpp:make_error(Msg, util:xmpp_err(Reason)),
            ejabberd_router:route(ErrorMsg);
        {ok, _Ts} ->
            ok
    end,
    ok;

send_group_message(#message{id = MsgId, from = #jid{luser = Uid}, type = groupchat,
        sub_els = [#groupchat_retract_st{gid = Gid} = GroupChatRetractSt]} = Msg) ->
    ?INFO("Gid: ~s, Uid: ~s", [Gid, Uid]),
    case mod_groups:send_retract_message(MsgId, Gid, Uid, GroupChatRetractSt) of
        {error, Reason} ->
            ErrorMsg = xmpp:make_error(Msg, util:xmpp_err(Reason)),
            ejabberd_router:route(ErrorMsg);
        {ok, _Ts} ->
            ok
    end,
    ok.


%%% create_group %%%
process_local_iq(#iq{from = #jid{luser = Uid}, type = set,
        sub_els = [#group_st{action = create, name = Name} = ReqGroupSt]} = IQ) ->
    process_create_group(IQ, Uid, Name, ReqGroupSt);


%%% delete_group %%%
process_local_iq(#iq{from = #jid{luser = Uid}, type = set,
        sub_els = [#group_st{action = delete, gid = Gid} = _ReqGroupSt]} = IQ) ->
    process_delete_group(IQ, Gid, Uid);


%%% modify_members %%%
process_local_iq(#iq{from = #jid{luser = Uid}, type = set,
        sub_els = [#group_st{action = modify_members, gid = Gid} = ReqGroupSt]} = IQ) ->
    process_modify_members(IQ, Gid, Uid, ReqGroupSt);


%%% modify_admins %%%
process_local_iq(#iq{from = #jid{luser = Uid}, type = set,
        sub_els = [#group_st{action = modify_admins, gid = Gid} = ReqGroupSt]} = IQ) ->
    process_modify_admins(IQ, Gid, Uid, ReqGroupSt);


%%% get_group %%%
process_local_iq(#iq{from = #jid{luser = Uid}, type = get,
        sub_els = [#group_st{action = get, gid = Gid} = _ReqGroupSt]} = IQ) ->
    process_get_group(IQ, Gid, Uid);


%%% get_groups %%%
process_local_iq(#iq{from = #jid{luser = Uid}, type = get,
        sub_els = [#groups{action = get}]} = IQ) ->
    process_get_groups(IQ, Uid);


%%% set_name %%%
process_local_iq(#iq{from = #jid{luser = Uid}, type = set,
        sub_els = [#group_st{action = set_name, gid = Gid, name = Name} = _ReqGroupSt]} = IQ) ->
    process_set_name(IQ, Gid, Uid, Name);


%%% delete_avatar
process_local_iq(#iq{from = #jid{luser = Uid}, type = set,
        sub_els = [#pb_upload_group_avatar{gid = Gid, data = undefined}]} = IQ) ->
    process_delete_avatar(IQ, Gid, Uid);


%%% set_avatar
process_local_iq(#iq{from = #jid{luser = Uid}, type = set,
        sub_els = [#pb_upload_group_avatar{gid = Gid, data = Data}]} = IQ) ->
    %% TODO(murali@): update these functions to work with binary data.
    Base64Bytes = base64:encode(Data),
    process_set_avatar(IQ, Gid, Uid, Base64Bytes);


%%% leave_group %%%
process_local_iq(#iq{from = #jid{luser = Uid}, type = set,
        sub_els = [#group_st{action = leave, gid = Gid} = _ReqGroupSt]} = IQ) ->
    process_leave_group(IQ, Gid, Uid).


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%   Internal                                                                                 %%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%


-spec process_create_group(IQ :: iq(), Uid :: uid(),
        Name :: binary(), ReqGroupSt :: group_st()) -> iq().
process_create_group(IQ, Uid, Name, ReqGroupSt) ->
    ?INFO("create_group Uid: ~s Name: |~s| Group: ~p", [Uid, Name, ReqGroupSt]),
    MemberUids = [M#member_st.uid || M <- ReqGroupSt#group_st.members],

    {ok, Group, Results} = mod_groups:create_group(Uid, Name, MemberUids),

    MembersSt = lists:map(
        fun ({MemberUid, add, Result}) ->
            Type = case MemberUid =:= Uid of
                true -> admin;
                false -> member
            end,
            make_member_st(MemberUid, Result, Type)
        end,
        Results),

    GroupStResult = #group_st{
        gid = Group#group.gid,
        name = Group#group.name,
        action = create,
        members = MembersSt
    },
    xmpp:make_iq_result(IQ, GroupStResult).


-spec process_delete_group(IQ :: iq(), Gid :: gid(), Uid :: uid()) -> iq().
process_delete_group(IQ, Gid, Uid) ->
    ?INFO("delete_group Gid: ~s Uid: ~s", [Gid, Uid]),
    case mod_groups:delete_group(Gid, Uid) of
        {error, not_admin} ->
            xmpp:make_error(IQ, util:err(not_admin));
        ok ->
            xmpp:make_iq_result(IQ)
    end.


-spec process_modify_members(IQ :: iq(), Gid :: gid(), Uid :: uid(), ReqGroupSt :: group_st())
            -> iq().
process_modify_members(IQ, Gid, Uid, ReqGroupSt) ->
    MembersSt = ReqGroupSt#group_st.members,
    Changes = [{M#member_st.uid, M#member_st.action} || M <- MembersSt],
    ?INFO("modify_members Gid: ~s Uid: ~s Changes: ~p", [Gid, Uid, Changes]),
    case mod_groups:modify_members(Gid, Uid, Changes) of
        {error, not_admin} ->
            xmpp:make_error(IQ, util:err(not_admin));
        {ok, ModifyResults} ->

            ResultMemberSt = lists:map(
                fun ({Ouid, Action, Result}) ->
                    make_member_st(Ouid, Result, member, Action)
                end,
                ModifyResults),

            GroupStResult = #group_st{
                gid = Gid,
                action = modify_members,
                members = ResultMemberSt
            },
            xmpp:make_iq_result(IQ, GroupStResult)
    end.


-spec process_modify_admins(IQ :: iq(), Gid :: gid(), Uid :: uid(), ReqGroupSt :: group_st())
            -> iq().
process_modify_admins(IQ, Gid, Uid, ReqGroupSt) ->
    MembersSt = ReqGroupSt#group_st.members,
    Changes = [{M#member_st.uid, M#member_st.action} || M <- MembersSt],
    ?INFO("modify_admins Gid: ~s Uid: ~s Changes: ~p", [Gid, Uid, Changes]),

    case mod_groups:modify_admins(Gid, Uid, Changes) of
        {error, not_admin} ->
            xmpp:make_error(IQ, util:err(not_admin));
        {ok, ModifyResults} ->

            ResultMemberSt = lists:map(
                fun ({Ouid, Action, Result}) ->
                    Type = case Action of promote -> admin; demote -> member end,
                    make_member_st(Ouid, Result, Type, Action)
                end,
                ModifyResults),

            GroupStResult = #group_st{
                gid = Gid,
                action = modify_admins,
                members = ResultMemberSt
            },
            xmpp:make_iq_result(IQ, GroupStResult)
    end.


-spec process_get_group(IQ :: iq(), Gid :: gid(), Uid :: uid()) -> iq().
process_get_group(IQ, Gid, Uid) ->
    ?INFO("get_group Gid: ~s Uid: ~s", [Gid, Uid]),
    case mod_groups:get_group(Gid, Uid) of
        {error, not_member} ->
            xmpp:make_error(IQ, util:err(not_member));
        {ok, Group} ->
            GroupSt = make_group_st(Group),
            xmpp:make_iq_result(IQ, GroupSt)
    end.


-spec process_get_groups(IQ :: iq(), Uid :: uid()) -> iq().
process_get_groups(IQ, Uid) ->
    ?INFO("get_groups Uid: ~s", [Uid]),
    GroupInfos = mod_groups:get_groups(Uid),
    GroupsSt = [group_info_to_group_st(GI) || GI <- GroupInfos],
    ResultSt = #groups{
        action = get,
        groups = GroupsSt
    },
    xmpp:make_iq_result(IQ, ResultSt).


-spec process_set_name(IQ :: iq(), Gid :: gid(), Uid :: uid(), Name :: name()) -> iq().
process_set_name(IQ, Gid, Uid, Name) ->
    ?INFO("set_name Gid: ~s Uid: ~s Name: |~p|", [Gid, Uid, Name]),
    case mod_groups:set_name(Gid, Uid, Name) of
        {error, invalid_name} ->
            xmpp:make_error(IQ, util:err(invalid_name));
        {error, not_member} ->
            xmpp:make_error(IQ, util:err(not_member));
        ok ->
            {ok, GroupInfo} = mod_groups:get_group_info(Gid, Uid),
            xmpp:make_iq_result(IQ, group_info_to_group_st(GroupInfo))
    end.


process_delete_avatar(IQ, Gid, Uid) ->
    ?INFO("Gid: ~s Uid: ~s", [Gid, Uid]),
    case mod_groups:delete_avatar(Gid, Uid) of
        {error, Reason} ->
            xmpp:make_error(IQ, util:err(Reason));
        {ok, _GroupName} ->
            xmpp:make_iq_result(IQ)
    end.


process_set_avatar(IQ, Gid, Uid, Base64Data) ->
    ?INFO("set_avatar Gid: ~s Uid: ~s Base64Size: ~p", [Gid, Uid, byte_size(Base64Data)]),
    case set_avatar(Gid, Uid, Base64Data) of
        {error, Reason} ->
            ?WARNING("Gid: ~s Uid ~s setting avatar failed ~p", [Gid, Uid, Reason]),
            xmpp:make_error(IQ, util:err(Reason));
        {ok, AvatarId, GroupName} ->
            ?INFO("Gid: ~s Uid: ~s Successfully set avatar ~s",
                [Gid, Uid, AvatarId]),
            GroupSt = #group_st{
                gid = Gid,
                name = GroupName,
                avatar = AvatarId
            },
            xmpp:make_iq_result(IQ, GroupSt)
    end.


-spec set_avatar(Gid :: gid(), Uid :: uid(), Base64Data :: binary()) ->
        {ok, AvatarId :: binary(), GroupName :: binary()} | {error, atom()}.
set_avatar(Gid, Uid, Base64Data) ->
    case model_groups:check_member(Gid, Uid) of
        false -> {error, not_member};
        true ->
            case mod_user_avatar:check_and_upload_avatar(Base64Data) of
                {error, Reason} -> {error, Reason};
                {ok, AvatarId} ->
                    mod_groups:set_avatar(Gid, Uid, AvatarId)
            end
    end.


-spec process_leave_group(IQ :: iq(), Gid :: gid(), Uid :: uid()) -> iq().
process_leave_group(IQ, Gid, Uid) ->
    ?INFO("leave_group Gid: ~s Uid: ~s ", [Gid, Uid]),
    case mod_groups:leave_group(Gid, Uid) of
        {ok, _Res} ->
            xmpp:make_iq_result(IQ)
    end.


-spec group_info_to_group_st(GroupInfo :: group_info()) -> group_st().
group_info_to_group_st(GroupInfo) ->
    #group_st{
        gid = GroupInfo#group_info.gid,
        name = GroupInfo#group_info.name,
        avatar = GroupInfo#group_info.avatar
    }.


-spec make_group_st(Group :: group()) -> group_st().
make_group_st(Group) ->
    #group_st{
        gid = Group#group.gid,
        name = Group#group.name,
        avatar = Group#group.avatar,
        members = make_members_st(Group#group.members)
    }.


-spec make_members_st(Members :: [group_member()]) -> [member_st()].
make_members_st(Members) ->
    MemberUids = [M#group_member.uid || M <- Members],
    NamesMap = model_accounts:get_names(MemberUids),
    [#member_st{
        uid = M#group_member.uid,
        type = M#group_member.type,
        name = maps:get(M#group_member.uid, NamesMap, undefined)
    } || M <- Members].


make_member_st(MemberUid, Result, Type, Action) ->
    S = make_member_st(MemberUid, Result, Type),
    S#member_st{action = Action}.


make_member_st(MemberUid, Result, Type) ->
    M = #member_st{
        uid = MemberUid,
        type = Type
    },
    M2 = case Result of
        ok ->
            M#member_st{result = ok};
        Result ->
            M#member_st{result = failed, reason = Result}
    end,
    M2.

