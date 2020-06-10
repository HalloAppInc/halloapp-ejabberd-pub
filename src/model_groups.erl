%%%------------------------------------------------------------------------------------
%%% File: model_phone.erl
%%% Copyright (C) 2020, HalloApp, Inc.
%%%
%%% API to the RedisGroups cluster.
%%%
%%%------------------------------------------------------------------------------------
-module(model_groups).
-author("nikola").
-behavior(gen_mod).

-include("logger.hrl").
-include("redis_keys.hrl").
-include("ha_types.hrl").
-include("groups.hrl").

%% Export all functions for unit tests
-ifdef(TEST).
-compile(export_all).
-endif.

%% gen_mod callbacks
-export([start/2, stop/1, depends/2, mod_options/1]).


%% API
-export([
    create_group/2,
    group_exists/1,
    get_member_uids/1,
    get_group_size/1,
    get_group/1,
    get_group_info/1,
    get_groups/1,
    add_member/3,
    add_members/3,
    remove_member/2,
    remove_members/2,
    promote_admin/2,
    promote_admins/2,
    demote_admin/2,
    demote_admins/2,
    is_member/2,
    is_admin/2,
    set_name/2,
    set_avatar/2
]).


%%====================================================================
%% gen_mod callbacks
%%====================================================================

start(_Host, _Opts) ->
    ok.

stop(_Host) ->
    ok.

depends(_Host, _Opts) ->
    [{mod_redis, hard}].

mod_options(_Host) ->
    [].

%%====================================================================
%% API
%%====================================================================

-define(FIELD_NAME, <<"na">>).
-define(FIELD_AVATAR_ID, <<"av">>).
-define(FIELD_CREATION_TIME, <<"ct">>).
-define(FIELD_CREATED_BY, <<"crb">>).


-spec create_group(Name :: binary(), Uid :: uid()) -> {ok, Gid :: gid()}.
create_group(Name, Uid) ->
    create_group(Name, Uid, util:now_ms()).


-spec create_group(Name :: binary(), Uid :: uid(), Ts :: integer()) -> {ok, Gid :: gid()}.
create_group(Name, Uid, Ts) ->
    Gid = util:generate_gid(),
    MemberValue = encode_member_value(admin, util:now_ms(), Uid),
    [{ok, _}, {ok, _}] = qp([
        ["HSET",
            group_key(Gid),
            ?FIELD_NAME, Name,
            ?FIELD_CREATION_TIME, integer_to_binary(Ts),
            ?FIELD_CREATED_BY, Uid],
        ["HSET", members_key(Gid), Uid, MemberValue]]),
    {ok, _} = q(["SADD", user_groups_key(Uid), Gid]),
    {ok, Gid}.


-spec group_exists(Gid :: gid()) -> boolean().
group_exists(Gid) ->
    {ok, Res} = q(["EXISTS", group_key(Gid)]),
    binary_to_integer(Res) == 1.


-spec get_member_uids(Gid :: gid()) -> [uid()].
get_member_uids(Gid) ->
    {ok, Members} = q(["HKEYS", members_key(Gid)]),
    Members.


-spec get_group_size(Gid :: gid()) -> non_neg_integer().
get_group_size(Gid) ->
    {ok, Res} = q(["HLEN", members_key(Gid)]),
    binary_to_integer(Res).


-spec get_group(Gid :: gid()) -> group() | undefined.
get_group(Gid) ->
    [{ok, GroupData}, {ok, MembersData}] = qp([
        ["HGETALL", group_key(Gid)],
        ["HGETALL", members_key(Gid)]
    ]),
    case GroupData of
        [] -> undefined;
        _ ->
            GroupMap = util:list_to_map(GroupData),
            MembersMap = util:list_to_map(MembersData),
            Members = decode_members(Gid, MembersMap),
            #group{
                gid = Gid,
                name = maps:get(?FIELD_NAME, GroupMap, undefined),
                avatar = maps:get(?FIELD_AVATAR_ID, GroupMap, undefined),
                creation_ts_ms = util_redis:decode_ts(
                    maps:get(?FIELD_CREATION_TIME, GroupMap, undefined)),
                members = lists:sort(fun member_compare/2, Members)
            }
    end.


-spec get_group_info(Gid :: gid()) -> group_info() | undefined.
get_group_info(Gid) ->
    {ok, GroupData} = q(["HGETALL", group_key(Gid)]),
    case GroupData of
        [] -> undefined;
        _ ->
            GroupMap = util:list_to_map(GroupData),
            #group_info{
                gid = Gid,
                name = maps:get(?FIELD_NAME, GroupMap, undefined),
                avatar = maps:get(?FIELD_AVATAR_ID, GroupMap, undefined),
                creation_ts_ms = util_redis:decode_ts(
                    maps:get(?FIELD_CREATION_TIME, GroupMap, undefined))
            }
    end.


-spec get_groups(Uid :: uid()) -> [gid()].
get_groups(Uid) ->
    {ok, Gids} = q(["SMEMBERS", user_groups_key(Uid)]),
    Gids.


-spec add_member(Gid :: gid(), Uid :: uid(), AdminUid :: uid()) -> {ok, boolean()}.
add_member(Gid, Uid, AdminUid) ->
    [Res] = add_members(Gid, [Uid], AdminUid),
    {ok, Res}.


-spec add_members(Gid :: gid(), Uids :: [uid()], AdminUid :: uid()) -> [boolean()].
add_members(_Gid, [], _AdminUid) ->
    [];
add_members(Gid, Uids, AdminUid) ->
    K = members_key(Gid),
    NowMs = util:now_ms(),
    Commands = lists:map(
        fun (Uid) ->
            Val = encode_member_value(member, NowMs, AdminUid),
            ["HSETNX", K, Uid, Val]
        end,
        Uids),
    RedisResults = qp(Commands),
    lists:foreach(
        fun (Uid) ->
            {ok, _Res} = q(["SADD", user_groups_key(Uid), Gid])
        end,
        Uids),
    lists:map(
        fun ({ok, Res}) ->
            binary_to_integer(Res) == 1
        end,
        RedisResults).


-spec remove_member(Gid :: gid(), Uid :: uid()) -> {ok, boolean()}.
remove_member(Gid, Uid) ->
    {ok, Num} = remove_members(Gid, [Uid]),
    {ok, Num =:= 1}.


-spec remove_members(Gid :: gid(), Uids :: [uid()]) -> {ok, integer()}.
remove_members(_Gid, []) ->
    {ok, 0};
remove_members(Gid, Uids) ->
    {ok, Res} = q(["HDEL", members_key(Gid) | Uids]),
    lists:foreach(
        fun (Uid) ->
            {ok, _Res2} = q(["SREM", user_groups_key(Uid), Gid])
        end,
        Uids),
    {ok, binary_to_integer(Res)}.


-spec promote_admin(Gid :: gid(), Uid :: uid()) -> {ok, boolean()} | {error, not_member}.
promote_admin(Gid, Uid) ->
    {ok, MemberValue} = q(["HGET", members_key(Gid), Uid]),
    case MemberValue of
        undefined -> {error, not_member};
        _ -> promote_admin(Gid, Uid, MemberValue)
    end.


promote_admin(Gid, Uid, MemberValue) ->
    {MemberType, Ts, AddedBy} = decode_member_value(MemberValue),
    case MemberType of
        admin ->
            {ok, false};
        member ->
            NewMemberValue = encode_member_value(admin, Ts, AddedBy),
            {ok, _Res} = q(["HSET", members_key(Gid), Uid, NewMemberValue]),
            {ok, true}
    end.


-spec promote_admins(Gid :: gid(), Uids :: [uid()]) -> [{ok, boolean()} | {error, not_member}].
promote_admins(Gid, Uids) ->
    [promote_admin(Gid, Uid) || Uid <- Uids].


-spec demote_admin(Gid :: gid(), Uid :: uid()) -> {ok, boolean()}.
demote_admin(Gid, Uid) ->
    {ok, MemberValue} = q(["HGET", members_key(Gid), Uid]),
    case MemberValue of
        undefined -> {ok, not_member};
        _ -> demote_admin(Gid, Uid, MemberValue)
    end.


demote_admin(Gid, Uid, MemberValue) ->
    {MemberType, Ts, AddedBy} = decode_member_value(MemberValue),
    case MemberType of
        member ->
            {ok, not_admin};
        admin ->
            NewMemberValue = encode_member_value(member, Ts, AddedBy),
            {ok, _Res} = q(["HSET", members_key(Gid), Uid, NewMemberValue]),
            {ok, true}
    end.


-spec demote_admins(Gid :: gid(), Uids :: [uid()]) -> [{ok, boolean()}].
demote_admins(Gid, Uids) ->
    [demote_admin(Gid, Uid) || Uid <- Uids].


-spec is_member(Gid :: gid(), Uid :: uid()) -> boolean().
is_member(Gid, Uid) ->
    {ok, Res} = q(["HEXISTS", members_key(Gid), Uid]),
    binary_to_integer(Res) == 1.


-spec is_admin(Gid :: gid(), Uid :: uid()) -> boolean().
is_admin(Gid, Uid) ->
    {ok, Value} = q(["HGET", members_key(Gid), Uid]),
    case decode_member_value(Value) of
        undefined -> false;
        {admin, _, _} -> true;
        _ -> false
    end.

-spec check_member(Gid :: gid(), Uid :: uid()) -> boolean().
check_member(Gid, Uid) ->
    [{ok, GroupExistsBin}, {ok, IsMemberBin}] = qp([
        ["EXISTS", group_key(Gid)],
        ["HEXISTS", members_key(Gid), Uid]]),
    GroupExists = binary_to_integer(GroupExistsBin) == 1,
    IsMember = binary_to_integer(IsMemberBin) == 1,
    GroupExists and IsMember.


-spec set_name(Gid :: gid(), Name :: binary()) -> ok.
set_name(Gid, Name) ->
    {ok, _Res} = q(["HSET", group_key(Gid), ?FIELD_NAME, Name]),
    ok.


-spec set_avatar(Gid :: gid(), AvatarId :: binary()) -> ok.
set_avatar(Gid, AvatarId) ->
    {ok, _Res} = q(["HSET", group_key(Gid), ?FIELD_AVATAR_ID, AvatarId]),
    ok.


encode_member_value(MemberType, Ts, AddedBy) ->
    T = encode_member_type(MemberType),
    TsBin = integer_to_binary(Ts),
    <<T/binary, <<",">>/binary, TsBin/binary, <<",">>/binary, AddedBy/binary>>.


decode_member_value(undefined) ->
    undefined;
decode_member_value(MemberValue) ->
    [TypeBin, TsBin, AddedBy] = binary:split(MemberValue, <<",">>, [global]),
    {decode_member_type(TypeBin), binary_to_integer(TsBin), AddedBy}.


encode_member_type(member) ->
    <<"m">>;
encode_member_type(admin) ->
    <<"a">>;
encode_member_type(Any) ->
    erlang:error({bad_member_type, Any}).


decode_member_type(<<"m">>) ->
    member;
decode_member_type(<<"a">>) ->
    admin;
decode_member_type(Any) ->
    erlang:error({bad_member_type, Any}).


-spec decode_members(Gid :: gid(), MembersMap :: map()) -> [group_member()].
decode_members(Gid, MembersMap)
        when is_map(MembersMap) ->
    maps:fold(
        fun (Uid, MemberValue, Acc) ->
            case decode_member(Uid, MemberValue) of
                {ok, Member} ->
                    [Member | Acc];
                {error, Reason} ->
                    ?ERROR_MSG("decode failed ~p Gid: ~s Uid: ~s Value: ~s",
                        [Reason, Gid, Uid, MemberValue]),
                    Acc
            end
        end,
        [],
        MembersMap).


-spec decode_member(Uid :: uid(), MemberValue :: binary()) -> {ok, group_member()} | {error, decode_fail}.
decode_member(Uid, MemberValue) ->
    try
        true = is_binary(Uid),
        {MemberType, _Ts, _AddedBy} = decode_member_value(MemberValue),
        Member = #group_member{
            uid = Uid,
            type = MemberType
        },
        {ok, Member}
    catch
        Class:Reason:Stacktrace ->
            ?ERROR_MSG("Stacktrace:~s",
                [lager:pr_stacktrace(Stacktrace, {Class, Reason})]),
            {error, Reason}
    end.


-spec member_compare(M1 :: group_member(), M2 :: group_member()) -> boolean().
member_compare(M1, M2) ->
    M1#group_member.uid < M2#group_member.uid.


-spec group_key(Gid :: gid()) -> binary().
group_key(Gid) ->
    <<?GROUP_KEY/binary, <<"{">>/binary, Gid/binary, <<"}">>/binary>>.


-spec members_key(Gid :: gid()) -> binary().
members_key(Gid) ->
    <<?GROUP_MEMBERS_KEY/binary, <<"{">>/binary, Gid/binary, <<"}">>/binary>>.


-spec user_groups_key(Uid :: uid()) -> binary().
user_groups_key(Uid) ->
    <<?USER_GROUPS_KEY/binary, "{", Uid/binary, "}">>.


%% TODO: This code is kind of copied in all the models...
q(Command) ->
    {ok, Result} = gen_server:call(redis_groups_client, {q, Command}),
    Result.


qp(Commands) ->
    {ok, Results} = gen_server:call(redis_groups_client, {qp, Commands}),
    Results.

