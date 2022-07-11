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
    create_group/4,
    delete_group/2,
    add_members/3,
    remove_members/3,
    share_history/3,
    share_history/4,
    modify_members/3,
    modify_members/4,
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
    set_expiry/3,
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
    join_with_invite_link/2,
    check_audience_hash/5
]).

-include("logger.hrl").
-include("packets.hrl").
-include("groups.hrl").
-include("feed.hrl").
-define(MAX_GROUP_NAME_SIZE, 25).   %% 25 utf8 characters
-define(MAX_GROUP_DESCRIPTION_SIZE, 500).   %% 500 utf8 characters
-define(MAX_BG_LENGTH, 64).
-define(DEFAULT_GROUP_EXPIRY, 30 * ?DAYS).

-define(MAX_PREMIUM_GROUP_SIZE, 100).

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

-type share_history_result() :: {uid, share_history, ok | no_account | not_member}.
-type share_history_results() :: [share_history_result()].

-type modify_member_result() :: {uid(), add | remove,
        ok | no_account | max_group_size | max_group_count | already_member | already_not_member}.
-type modify_member_results() :: [modify_member_result()].
-type modify_admin_result() :: {uid(), promote | demote, ok | no_member}.
-type modify_admin_results() :: [modify_admin_result()].

-type modify_results() :: modify_member_results() | modify_admin_results().

-spec create_group(Uid :: uid(), GroupName :: binary()) ->
        {ok, group()} | {error, invalid_name} | {error, max_group_count}.
create_group(Uid, GroupName) ->
    create_group(Uid, GroupName, #pb_expiry_info{expiry_type = expires_in_seconds, expires_in_seconds = ?DEFAULT_GROUP_EXPIRY}).

-spec create_group(Uid :: uid(), GroupName :: binary(), GroupExpiry :: expiry_info()) ->
        {ok, group()} | {error, invalid_name} | {error, max_group_count}.
create_group(Uid, GroupName, GroupExpiry) ->
    ?INFO("Uid: ~s GroupName: ~s, GroupExpiry", [Uid, GroupName, GroupExpiry]),
    case create_group_internal(Uid, GroupName, GroupExpiry) of
        {error, Reason} -> {error, Reason};
        {ok, Gid} ->
            Group = model_groups:get_group(Gid),
            {ok, Group}
    end.


-spec create_group(Uid :: uid(), GroupName :: binary(), GroupExpiry :: expiry_info(), MemberUids :: [uid()])
            -> {ok, group(), modify_member_results()} | {error, any()}.
create_group(Uid, GroupName, GroupExpiry, MemberUids) ->
    case create_group_internal(Uid, GroupName, GroupExpiry) of
        {error, Reason} -> {error, Reason};
        {ok, Gid} ->
            ?INFO("Gid: ~s Uid: ~s initializing with Members ~p GroupExpiry: ~p",
                [Gid, Uid, MemberUids, GroupExpiry]),
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


-spec share_history(Gid :: gid(), Uid :: uid(), MemberUids :: [uid()])
            -> {ok, share_history_results()} | {error, not_admin}.
share_history(Gid, Uid, UidsToShare) ->
    share_history(Gid, Uid, UidsToShare, undefined).


-spec remove_members(Gid :: gid(), Uid :: uid(), MemberUids :: [uid()])
            -> {ok, modify_member_results()} | {error, not_admin}.
remove_members(Gid, Uid, MemberUids) ->
    modify_members(Gid, Uid, [{Ouid, remove} || Ouid <- MemberUids]).


-spec modify_members(Gid :: gid(), Uid :: uid(), Changes :: [{uid(), add | remove}])
            -> {ok, modify_member_results()} | {error, not_admin}.
modify_members(Gid, Uid, Changes) ->
    modify_members(Gid, Uid, Changes, undefined).


-spec modify_members(Gid :: gid(), Uid :: uid(), Changes :: [{uid(), add | remove}],
    PBHistoryResend :: pb_history_resend()) -> {ok, modify_member_results()} | {error, not_admin}.
modify_members(Gid, Uid, Changes, PBHistoryResend) ->
    case model_groups:is_admin(Gid, Uid) of
        false -> {error, not_admin};
        true ->
            GroupInfo = model_groups:get_group_info(Gid),
            IQAudienceHash = case PBHistoryResend of
                undefined -> undefined;
                _ -> PBHistoryResend#pb_history_resend.audience_hash
            end,
            IsHashMatch = check_audience_hash(IQAudienceHash, GroupInfo#group_info.audience_hash,
                Gid, Uid, modify_members_with_history),
            case IsHashMatch of
                false -> {error, audience_hash_mismatch};
                true ->
                    {RemoveUids, AddUids} = split_changes(Changes, remove),
                    RemoveResults = remove_members_unsafe(Gid, RemoveUids),
                    AddResults = add_members_unsafe(Gid, Uid, AddUids),
                    Results = RemoveResults ++ AddResults,
                    log_stats(modify_members, Results),
                    broadcast_event_with_history(Gid, Uid, Results, modify_members, PBHistoryResend),
                    update_removed_members_set(Gid, Results),
                    maybe_delete_empty_group(Gid),
                    {ok, Results}
            end
    end.


-spec share_history(Gid :: gid(), Uid :: uid(), UidsToShare :: [uid()],
    PBHistoryResend :: pb_history_resend()) -> {ok, share_history_results()} | {error, not_admin}.
share_history(Gid, Uid, UidsToShare, PBHistoryResend) ->
    case model_groups:is_admin(Gid, Uid) of
        false -> {error, not_admin};
        true ->
            GroupInfo = model_groups:get_group_info(Gid),
            IQAudienceHash = case PBHistoryResend of
                undefined -> undefined;
                _ -> PBHistoryResend#pb_history_resend.audience_hash
            end,
            IsHashMatch = check_audience_hash(IQAudienceHash, GroupInfo#group_info.audience_hash,
                Gid, Uid, share_history),
            case IsHashMatch of
                false -> {error, audience_hash_mismatch};
                true ->
                    ShareHistoryResults = share_history_unsafe(Gid, Uid, UidsToShare),
                    Results = ShareHistoryResults,
                    log_stats(share_history, ShareHistoryResults),
                    broadcast_event_with_history(Gid, Uid, Results, share_history, PBHistoryResend),
                    {ok, Results}
            end
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
    MemberUids = [Member#group_member.uid || Member <- GroupMembers],
    IdentityKeysMap = model_whisper_keys:get_identity_keys(MemberUids),
    GroupMembers2 = lists:map(
        fun(#group_member{uid = Uid2} = Member2) ->
            Member2#group_member{identity_key = base64:decode(maps:get(Uid2, IdentityKeysMap, <<>>))}
        end, GroupMembers),
    %% GroupMembers has members in sorted order by member Uids.
    IKList = lists:foldl(
        fun(#group_member{uid = Uid2, identity_key = IdentityKeyBin}, Acc) ->
            case IdentityKeyBin of
                <<>> ->
                    ?ERROR("Uid: ~p identity key is invalid", [Uid2]),
                    Acc;
                _ ->
                    % Need to parse IdentityKeyBin as per identity_key proto
                    try enif_protobuf:decode(IdentityKeyBin, pb_identity_key) of
                        #pb_identity_key{public_key = IPublicKey} ->
                            [IPublicKey | Acc]
                    catch Class : Reason : St ->
                        ?ERROR("failed to parse identity key: ~p, Uid: ~p",
                            [IdentityKeyBin, Uid2, lager:pr_stacktrace(St, {Class, Reason})]),
                        Acc
                    end
            end
        end, [], GroupMembers2),
    XorIKList = case length(IKList) of
        0 -> [];
        _Len ->
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


-spec check_audience_hash(
      IQAudienceHash :: binary(), GroupAudienceHash :: binary(),
      Gid :: gid(), Uid :: uid(), Action :: atom()) -> boolean().
%% TODO: add tests.
check_audience_hash(undefined, _GroupAudienceHash, _Gid, _Uid, _Action) -> true;
check_audience_hash(<<>>, _GroupAudienceHash, _Gid, _Uid, _Action) -> true;
check_audience_hash(IQAudienceHash, GroupAudienceHash, Gid, Uid, Action) ->
    %% TODO(vipin): Report of match/mismatch via stats.
    try
        NewHash = compute_and_set_audience_hash(GroupAudienceHash, Gid, Uid),
        RetVal = NewHash =:= IQAudienceHash,
        PrintMsg = "Audience Hash Check 1, IQ: ~p, Group: ~p, Gid: ~p, Uid: ~p, Action: ~p, "
                   "Match: ~p",
        PrintArg1 = [base64url:encode(IQAudienceHash), base64url:encode(NewHash), Gid, Uid,
                    Action, RetVal],
        case RetVal of
            false ->
                ?WARNING(PrintMsg, PrintArg1);
            _ ->
                ?INFO(PrintMsg, PrintArg1)
        end,
        case {RetVal, GroupAudienceHash} of
            {true, _} -> RetVal;
            {false, undefined} -> RetVal;
            {false, _} ->
                NewHash2 = compute_and_set_audience_hash(undefined, Gid, Uid),
                RetVal2 = NewHash2 =:= IQAudienceHash,
                PrintMsg2 = "Audience Hash Check 2, IQ: ~p, Group: ~p, Gid: ~p, Uid: ~p, "
                    "Action: ~p, Match: ~p",
                PrintArg2 = [base64url:encode(IQAudienceHash), base64url:encode(NewHash2),
                    Gid, Uid, Action, RetVal2],
                case RetVal2 of
                    false ->
                        ?WARNING(PrintMsg2, PrintArg2);
                    _ ->
                        ?INFO(PrintMsg2, PrintArg2)
                end,
                RetVal2
        end
    catch
        error : _ -> false
    end.


-spec compute_and_set_audience_hash(CurrentHash :: binary(), Gid :: gid(), Uid :: uid()) -> binary() | no_return().
compute_and_set_audience_hash(CurrentHash, Gid, Uid) ->
    case CurrentHash of
        undefined ->
            case get_member_identity_keys(Gid, Uid) of
                {ok, Group} ->
                    ComputedHash = Group#group.audience_hash,
                    ok = model_groups:set_audience_hash(Gid, ComputedHash),
                    ComputedHash;
                {error, Reason} = Error ->
                    ?ERROR("Failed to compute hash, Gid: ~p, Uid: ~p, Error: ~p", [Gid, Uid, Error]),
                    error(Reason)
            end;
        _ -> CurrentHash
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
    ?INFO("Uid: ~s", [Uid]),
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


-spec set_expiry(Gid :: gid(), Uid :: uid(), GroupExpiry :: expiry_info()) -> ok | {error, not_admin}.
set_expiry(Gid, Uid, GroupExpiry) ->
    ?INFO("Gid: ~s Uid: ~s GroupExpiry: |~s|", [Gid, Uid, GroupExpiry]),
    case model_groups:is_admin(Gid, Uid) of
        false -> {error, not_admin};
        true ->
            case validate_expiry_info(GroupExpiry) of
                {error, Reason} -> {error, Reason};
                {ok, {ExpiryType, ExpiryTimestamp}} ->
                    ok = model_groups:set_expiry(Gid, ExpiryType, ExpiryTimestamp),
                    ?INFO("Gid: ~s Uid: ~s set_expiry to |~s|", [Gid, Uid, GroupExpiry]),
                    stat:count(?STAT_NS, "set_expiry", 1, [{"expiry_type", util:to_list(ExpiryType)}]),
                    case ExpiryType of
                        expires_in_seconds ->
                            stat:count(?STAT_NS, "set_expiry_ts", 1, [{"expiry_ts", util:to_list(ExpiryTimestamp)}]);
                        _ -> ok
                    end,
                    send_change_expiry_event(Gid, Uid),
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
            send_change_avatar_event(Gid, Uid),
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
            MaxGroupSize = get_max_group_size(Gid),
            IsSizeExceeded = GroupSize + 1 > MaxGroupSize,
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


create_group_internal(Uid, GroupName, GroupExpiry) ->
    case is_user_group_count_exceeded(Uid) of
        true ->
            {error, max_group_count};
        false ->
            case validate_group_name(GroupName) of
                {error, Reason} -> {error, Reason};
                {ok, LGroupName} ->
                    case validate_expiry_info(GroupExpiry) of
                        {error, Reason} -> {error, Reason};
                        {ok, {ExpiryType, ExpiryTimestamp}} ->
                            {ok, Gid} = model_groups:create_group(Uid, LGroupName, ExpiryType, ExpiryTimestamp),
                            ?INFO("group created Gid: ~s Uid: ~s GroupName: |~s|, GroupExpiry: ~s",
                                [Gid, Uid, LGroupName, GroupExpiry]),
                            stat:count(?STAT_NS, "create"),
                            stat:count(?STAT_NS, "create_by_dev", 1, [{is_dev, dev_users:is_dev_uid(Uid)}]),
                            stat:count(?STAT_NS, "set_expiry", 1, [{"expiry_type", util:to_list(ExpiryType)}]),
                            case ExpiryType of
                                expires_in_seconds ->
                                    stat:count(?STAT_NS, "set_expiry_ts", 1, [{"expiry_ts", util:to_list(ExpiryTimestamp)}]);
                                _ -> ok
                            end,
                            {ok, Gid}
                    end
            end
    end.


-spec validate_expiry_info(GroupExpiry :: expiry_info()) -> {expiry_type(), integer()} | {error, atom()}.
validate_expiry_info(undefined) -> {ok, {expires_in_seconds, ?DEFAULT_GROUP_EXPIRY}};
validate_expiry_info(GroupExpiry) ->
    ExpiryType = GroupExpiry#pb_expiry_info.expiry_type,
    case ExpiryType of
        expires_in_seconds -> 
            Ts = GroupExpiry#pb_expiry_info.expires_in_seconds,
            case Ts =:= ?DAYS orelse Ts =:= ?DEFAULT_GROUP_EXPIRY of
                true -> {ok, {ExpiryType, Ts}};
                false -> {error, invalid_sec}
            end;
        never -> {ok, {ExpiryType, -1}};
        custom_date -> {ok, {ExpiryType, GroupExpiry#pb_expiry_info.expiry_timestamp}}
    end.


-spec share_history_unsafe(Gid :: gid(), Uid :: uid(), UidsToShare :: [uid()])
            -> share_history_results().
share_history_unsafe(Gid, _Uid, UidsToShare) ->
    GoodUidSet = sets:from_list(model_accounts:filter_nonexisting_uids(UidsToShare)),
    MUids = model_groups:get_member_uids(Gid),
    MemberUidSet = sets:from_list(MUids),
    Results = lists:map(
        fun (OUid) ->
            case sets:is_element(OUid, GoodUidSet) of
                true ->
                    case sets:is_element(OUid, MemberUidSet) of
                        true -> {OUid, add, ok};
                        false -> {OUid, add, not_member}
                    end;
                false ->
                    {OUid, add, no_account}
            end
        end,
        UidsToShare),
    Results.


-spec add_members_unsafe(Gid :: gid(), Uid :: uid(), MemberUids :: [uid()])
            -> modify_member_results().
add_members_unsafe(Gid, Uid, MemberUids) ->
    GroupSize = model_groups:get_group_size(Gid),
    MaxGroupSize = get_max_group_size(Gid),
    case GroupSize + length(MemberUids) > MaxGroupSize of
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
    {ValidMemberUids, InvalidMemberUids} = split_max_groups_count(GoodUids),
    RedisResults = model_groups:add_members(Gid, ValidMemberUids, Uid),
    AddResults = lists:zip(ValidMemberUids, RedisResults),
    Server = util:get_host(),
    % TODO: this is O(N^2), could be improved.
    Results = lists:map(
        fun (OUid) ->

            case lists:keyfind(OUid, 1, AddResults) of
                false ->
                    case lists:member(OUid, InvalidMemberUids) of
                        true ->
                            {OUid, add, max_group_count};
                        false ->
                            {OUid, add, no_account}
                    end;
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


-spec split_max_groups_count(MemberUids :: [uid()]) -> {[uid()], [uid()]}.
split_max_groups_count(MemberUids) ->
    CountResults = maps:to_list(is_user_group_counts_exceeded(MemberUids)),
    {L1, L2} = lists:partition(fun({_Uid, ExceedsGroupCount}) -> not ExceedsGroupCount end, CountResults),
    {[Uid || {Uid, _ExceedsGroupCount} <- L1], [Uid || {Uid, _ExceedsGroupCount} <- L2]}.


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


-spec validate_group_description(Description :: binary()) -> {ok, binary()} | {error, invalid_description}.
validate_group_description(Description) when is_binary(Description) ->
    LDescription = string:slice(Description, 0, ?MAX_GROUP_DESCRIPTION_SIZE),
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


-spec broadcast_event_with_history(Gid :: gid(), Uid :: uid(),
        MemberResults :: modify_member_results(), Event :: atom(),
        PBHistoryResend :: pb_history_resend()) -> ok.
broadcast_event_with_history(Gid, Uid, MemberResults, Event, PBHistoryResend) ->
    NewlyAddedMembers = lists:foldl(
        fun ({Ouid, add, ok}, Acc) -> [Ouid | Acc];
            (_, Acc) -> Acc
        end, [], MemberResults),
    Uids = [Uid | [Ouid || {Ouid, _, _} <- MemberResults]],
    Group = model_groups:get_group(Gid),
    GroupMembers = Group#group.members,
    MemberUids = [Member#group_member.uid || Member <- GroupMembers],
    NamesMap = model_accounts:get_names(Uids ++ MemberUids),
    HistoryResendMap = case PBHistoryResend of
        undefined -> #{};
        _ ->
            StateBundles = PBHistoryResend#pb_history_resend.sender_state_bundles,
            StateBundlesMap = case StateBundles of
                undefined -> #{};
                _ -> lists:foldl(
                         fun(StateBundle, Acc) ->
                             Uid2 = StateBundle#pb_sender_state_bundle.uid,
                             SenderState = StateBundle#pb_sender_state_bundle.sender_state,
                             Acc#{Uid2 => SenderState}
                         end, #{}, StateBundles)
            end,
            lists:foldl(
                fun(Uid3, Acc) ->
                    Acc#{Uid3 => PBHistoryResend#pb_history_resend{
                        sender_state_bundles = [],
                        sender_state = maps:get(Uid3, StateBundlesMap, undefined)
                    }}
                end, #{}, MemberUids)
    end,
    broadcast_update(Group, Uid, Event, MemberResults, NamesMap, HistoryResendMap),
    %% In addition to sending the group-event,
    %% We now send the group information to newly added members for clients to sync their group-state.
    broadcast_group_info(Group, NamesMap, NewlyAddedMembers),
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


-spec send_change_expiry_event(Gid :: gid(), Uid :: uid()) -> ok.
send_change_expiry_event(Gid, Uid) ->
    Group = model_groups:get_group(Gid),
    NamesMap = model_accounts:get_names([Uid]),
    broadcast_update(Group, Uid, change_expiry, [], NamesMap),
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
    broadcast_update(Group, Uid, Event, Results, NamesMap, #{}).


broadcast_update(Group, Uid, Event, Results, NamesMap, HistoryResendMap) ->
    MembersSt = make_members_st(Event, Results, NamesMap),
    %% broadcast description only on change_description events, else- leave it undefined.
    Description = case Event of
        change_description -> Group#group.description;
        _ -> undefined
    end,

    Members = [M#group_member.uid || M <- Group#group.members],
    %% We also need to notify users who will be affected and broadcast the update to them as well.
    AdditionalUids = [element(1, R) || R <- Results],
    UidsToNotify = sets:from_list(Members ++ AdditionalUids),
    BroadcastUids = sets:to_list(UidsToNotify),

    Id = util_id:new_msg_id(),
    %% Fetch appropriate history-resend packet and then broadcast the update.
    lists:foldl(
        fun(ToUid, Acc) ->
            GroupSt = #pb_group_stanza {
                gid = Group#group.gid,
                name = Group#group.name,
                avatar_id = Group#group.avatar,
                background = Group#group.background,
                sender_uid = Uid,
                sender_name = maps:get(Uid, NamesMap, undefined),
                action = Event,
                members = MembersSt,
                description = Description,
                expiry_info = make_pb_expiry_info(Group#group.expiry_info),
                history_resend = maps:get(ToUid, HistoryResendMap, undefined)
            },
            AccBin = integer_to_binary(Acc),
            NewId = <<Id/binary, "-", AccBin/binary>>,
            Packet = #pb_msg{
                id = NewId,
                type = groupchat,
                payload = GroupSt,
                from_uid = Uid,
                to_uid = ToUid
            },
            ejabberd_router:route(Packet),
            Acc + 1
        end, 0, BroadcastUids),
    ok.


%% Broadcast group information to a set of Uids.
broadcast_group_info(_Group, _NamesMap, []) -> ok;
broadcast_group_info(Group, NamesMap, NewlyAddedMembers) ->
    BroadcastUids = sets:to_list(sets:from_list(NewlyAddedMembers)),
    MembersStanza = lists:map(
        fun(M) ->
            #pb_group_member{
                uid = M#group_member.uid,
                type = M#group_member.type,
                name = maps:get(M#group_member.uid, NamesMap, undefined),
                identity_key = M#group_member.identity_key
            }
        end, Group#group.members),

    Id = util_id:new_msg_id(),
    lists:foldl(
        fun(ToUid, Acc) ->
            GroupSt = #pb_group_stanza {
                gid = Group#group.gid,
                name = Group#group.name,
                avatar_id = Group#group.avatar,
                background = Group#group.background,
                expiry_info = make_pb_expiry_info(Group#group.expiry_info),
                action = get,
                members = MembersStanza,
                description = Group#group.description
            },
            AccBin = integer_to_binary(Acc),
            NewId = <<Id/binary, "-", AccBin/binary>>,
            Packet = #pb_msg{
                id = NewId,
                type = groupchat,
                payload = GroupSt,
                to_uid = ToUid
            },
            ejabberd_router:route(Packet),
            Acc + 1
        end, 0, BroadcastUids),
    ok.


make_pb_expiry_info(ExpiryInfo) ->
    #pb_expiry_info{
        expiry_type = ExpiryInfo#expiry_info.expiry_type,
        expires_in_seconds = ExpiryInfo#expiry_info.expires_in_seconds,
        expiry_timestamp = ExpiryInfo#expiry_info.expiry_timestamp
    }.


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
        {auto_promote_admins, promote} -> admin;
        {share_history, add} -> member
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


-spec is_user_group_count_exceeded(Uid :: uid()) -> boolean().
is_user_group_count_exceeded(Uid) ->
    maps:get(Uid, is_user_group_counts_exceeded([Uid])).


-spec is_user_group_counts_exceeded(Uid :: uid()) -> [boolean()].
is_user_group_counts_exceeded(Uids) ->
    UserGroupCounts = model_groups:get_group_counts(Uids),
    maps:map(fun(_Uid, GroupCount) -> GroupCount + 1 > ?MAX_GROUP_COUNT end, UserGroupCounts).


-spec get_max_group_size(Gid :: gid()) -> integer().
%% Increase travel group limit to 100.
get_max_group_size(<<"gymN8HgS1F5ueq3WRZEz2K">>) -> ?MAX_PREMIUM_GROUP_SIZE;
get_max_group_size(_Gid) -> ?MAX_GROUP_SIZE.

