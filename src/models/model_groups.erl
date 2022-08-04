%%%------------------------------------------------------------------------------------
%%% File: model_phone.erl
%%% Copyright (C) 2020, HalloApp, Inc.
%%%
%%% API to the RedisGroups cluster.
%%%
%%%------------------------------------------------------------------------------------
-module(model_groups).
-author("nikola").
-include("logger.hrl").
-include("redis_keys.hrl").
-include("ha_types.hrl").
-include("groups.hrl").
-include("time.hrl").

-define(GROUP_INVITE_LINK_SIZE, 24).
-define(DEFAULT_GROUP_EXPIRY_SEC, (31 * ?DAYS)).


%% API
-export([
    create_group/2,
    create_group/4,
    create_group/5,
    delete_group/1,
    delete_empty_group/1,
    group_exists/1,
    get_member_uids/1,
    get_group_size/1,
    get_group/1,
    get_group_info/1,
    get_groups/1,
    get_group_count/1,
    get_group_counts/1,
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
    set_expiry/3,
    set_description/2,
    set_avatar/2,
    set_background/2,
    set_audience_hash/2,
    delete_audience_hash/1,
    delete_avatar/1,
    has_invite_link/1,
    get_invite_link/1,
    reset_invite_link/1,
    get_invite_link_gid/1,
    is_removed_member/2,
    add_removed_members/2,
    remove_removed_members/2,
    clear_removed_members_set/1,
    check_member/2,
    count_groups/0,
    count_groups/1
]).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-export([
    decode_member/2,
    encode_member_type/1,
    group_key/1,
    members_key/1,
    user_groups_key/1
]).
-endif.

%%====================================================================
%% API
%%====================================================================

-define(FIELD_NAME, <<"na">>).
-define(FIELD_EXPIRY_TYPE, <<"exy">>).
-define(FIELD_EXPIRY_TIMESTAMP, <<"ext">>).
-define(FIELD_DESCRIPTION, <<"de">>).
-define(FIELD_AVATAR_ID, <<"av">>).
-define(FIELD_BACKGROUND, <<"bg">>).
-define(FIELD_CREATION_TIME, <<"ct">>).
-define(FIELD_CREATED_BY, <<"crb">>).
-define(FIELD_INVITE_LINK, <<"il">>).
-define(FIELD_AUDIENCE_HASH, <<"ah">>).


-spec create_group(Uid :: uid(), Name :: binary()) -> {ok, Gid :: gid()}.
create_group(Uid, Name) ->
    create_group(Uid, Name, expires_in_seconds, ?DEFAULT_GROUP_EXPIRY_SEC, util:now_ms()).


-spec create_group(Uid :: uid(), Name :: binary(),
    ExpiryType :: expiry_type(), ExpiryTimestamp :: integer()) -> {ok, Gid :: gid()}.
create_group(Uid, Name, ExpiryType, ExpiryTimestamp) ->
    create_group(Uid, Name, ExpiryType, ExpiryTimestamp, util:now_ms()).


-spec create_group(Uid :: uid(), Name :: binary(),
    ExpiryType :: expiry_type(), ExpiryTimestamp :: integer(), Ts :: integer()) -> {ok, Gid :: gid()}.
create_group(Uid, Name, ExpiryType, ExpiryTimestamp, Ts) ->
    Gid = util_id:generate_gid(),
    MemberValue = encode_member_value(admin, util:now_ms(), Uid),
    [{ok, _}, {ok, _}, {ok, _}] = qp([
        ["HSET",
            group_key(Gid),
            ?FIELD_NAME, Name,
            ?FIELD_EXPIRY_TYPE, encode_expiry_type(ExpiryType),
            ?FIELD_EXPIRY_TIMESTAMP, integer_to_binary(ExpiryTimestamp),
            ?FIELD_CREATION_TIME, integer_to_binary(Ts),
            ?FIELD_CREATED_BY, Uid],
        ["HSET", members_key(Gid), Uid, MemberValue],
        ["INCR", count_groups_key(Gid)]]),
    {ok, _} = q(["SADD", user_groups_key(Uid), Gid]),
    {ok, Gid}.


-spec delete_group(Gid :: gid()) -> ok.
delete_group(Gid) ->
    MemberUids = get_member_uids(Gid),
    RemoveCommands = lists:map(
        fun (Uid) ->
            ["SREM", user_groups_key(Uid), Gid]
        end, MemberUids),
    qmn(RemoveCommands),
    ok = delete_empty_group(Gid),
    ok.


-spec delete_empty_group(Gid :: gid()) -> ok.
delete_empty_group(Gid) ->
    {ok, Link} = q(["HGET", group_key(Gid), ?FIELD_INVITE_LINK]),
    case Link of
        undefined -> ok;
        _ -> q(["DEL", group_invite_link_key(Link)])
    end,
    {ok, Res} = q(["DEL", group_key(Gid), members_key(Gid), group_removed_set_key(Gid)]),
    case Res of
        <<"0">> -> ok;
        _ -> q(["DECR", count_groups_key(Gid)])
    end,
    ok.


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


-spec get_group(Gid :: gid()) -> maybe(group()).
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
            ExpiryInfo = extract_expiry_info(GroupMap),
            #group{
                gid = Gid,
                name = maps:get(?FIELD_NAME, GroupMap, undefined),
                description = maps:get(?FIELD_DESCRIPTION, GroupMap, undefined),
                avatar = maps:get(?FIELD_AVATAR_ID, GroupMap, undefined),
                creation_ts_ms = util_redis:decode_ts(
                    maps:get(?FIELD_CREATION_TIME, GroupMap, undefined)),
                members = lists:sort(fun member_compare/2, Members),
                background = maps:get(?FIELD_BACKGROUND, GroupMap, undefined),
                expiry_info = ExpiryInfo
            }
    end.


-spec get_group_info(Gid :: gid()) -> maybe(group_info()).
get_group_info(Gid) ->
    {ok, GroupData} = q(["HGETALL", group_key(Gid)]),
    case GroupData of
        [] -> undefined;
        _ ->
            GroupMap = util:list_to_map(GroupData),
            ExpiryInfo = extract_expiry_info(GroupMap),
            #group_info{
                gid = Gid,
                name = maps:get(?FIELD_NAME, GroupMap, undefined),
                description = maps:get(?FIELD_DESCRIPTION, GroupMap, undefined),
                avatar = maps:get(?FIELD_AVATAR_ID, GroupMap, undefined),
                background = maps:get(?FIELD_BACKGROUND, GroupMap, undefined),
                audience_hash = maps:get(?FIELD_AUDIENCE_HASH, GroupMap, undefined),
                expiry_info = ExpiryInfo
            }
    end.


extract_expiry_info(GroupMap) ->
    ExpiryType = decode_expiry_type(maps:get(?FIELD_EXPIRY_TYPE, GroupMap, undefined)),
    ExpiryInfo = case ExpiryType of
        expires_in_seconds ->
            #expiry_info{
                expiry_type = ExpiryType,
                expires_in_seconds = util_redis:decode_ts(maps:get(?FIELD_EXPIRY_TIMESTAMP, GroupMap, util:to_binary(?DEFAULT_GROUP_EXPIRY_SEC)))
            };
        custom_date ->
            #expiry_info{
                expiry_type = ExpiryType,
                expiry_timestamp = util_redis:decode_ts(maps:get(?FIELD_EXPIRY_TIMESTAMP, GroupMap, undefined))
            };
        never ->
            #expiry_info{
                expiry_type = ExpiryType,
                expiry_timestamp = -1
            }
    end,
    ExpiryInfo.


-spec get_groups(Uid :: uid()) -> [gid()].
get_groups(Uid) ->
    {ok, Gids} = q(["SMEMBERS", user_groups_key(Uid)]),
    Gids.


-spec get_group_count(Uid :: uid()) -> integer() | {error, any()}.
get_group_count(Uid) ->
    maps:get(Uid, get_group_counts([Uid])).


-spec get_group_counts(Uids :: uid()) -> integer() | {error, any()}.
get_group_counts(Uids) ->
    Commands = lists:map(fun(Uid) -> ["SCARD", user_groups_key(Uid)] end, Uids),
    RedisResults = qmn(Commands),
    Values = lists:map(
        fun(Result) ->
            {ok, Res} = Result,
            binary_to_integer(Res)
        end, RedisResults),
    ResultsList = lists:zip(Uids, Values),
    ResultsMap = maps:from_list(ResultsList),
    ResultsMap.


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
    NewCommands = Commands ++ [delete_audience_hash_command(Gid)],
    {ok, RedisResults} = multi_exec(NewCommands),
    NewResults = lists:droplast(RedisResults),
    AddCommands = lists:map(
        fun (Uid) ->
            ["SADD", user_groups_key(Uid), Gid]
        end, Uids),
    qmn(AddCommands),
    lists:map(
        fun (Res) ->
            binary_to_integer(Res) =:= 1
        end,
        NewResults).


-spec remove_member(Gid :: gid(), Uid :: uid()) -> {ok, boolean()}.
remove_member(Gid, Uid) ->
    [Res] = remove_members(Gid, [Uid]),
    {ok, Res}.


-spec remove_members(Gid :: gid(), Uids :: [uid()]) -> [boolean()].
remove_members(_Gid, []) ->
    [];
remove_members(Gid, Uids) ->
    GidKey = members_key(Gid),
    Commands = [["HDEL", GidKey, U] || U <- Uids],
    NewCommands = Commands ++ [delete_audience_hash_command(Gid)],
    {ok, Results} = multi_exec(NewCommands),
    NewResults = lists:droplast(Results),
    RemoveCommands = lists:map(
        fun (Uid) ->
            ["SREM", user_groups_key(Uid), Gid]
        end, Uids),
    qmn(RemoveCommands),
    lists:map(
        fun (Res) ->
            binary_to_integer(Res) =:= 1
        end,
        NewResults).


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


-spec set_expiry(Gid :: gid(), ExpiryType :: expiry_type(), ExpiryTimestamp :: integer()) -> ok.
set_expiry(Gid, ExpiryType, ExpiryTimestamp) ->
    {ok, _Res} = q(
        ["HMSET", group_key(Gid),
         ?FIELD_EXPIRY_TYPE, encode_expiry_type(ExpiryType),
         ?FIELD_EXPIRY_TIMESTAMP, integer_to_binary(ExpiryTimestamp)
         ]),
    ok.


-spec set_description(Gid :: gid(), Description :: binary()) -> ok.
set_description(Gid, Description) ->
    {ok, _Res} = q(["HSET", group_key(Gid), ?FIELD_DESCRIPTION, Description]),
    ok.


-spec set_avatar(Gid :: gid(), AvatarId :: binary()) -> ok.
set_avatar(Gid, AvatarId) ->
    {ok, _Res} = q(["HSET", group_key(Gid), ?FIELD_AVATAR_ID, AvatarId]),
    ok.

-spec delete_avatar(Gid :: gid()) -> ok.
delete_avatar(Gid) ->
    {ok, _Res} = q(["HDEL", group_key(Gid), ?FIELD_AVATAR_ID]),
    ok.

-spec set_background(Gid :: gid(), Background :: maybe(binary())) -> ok.
set_background(Gid, undefined) ->
    {ok, _Res} = q(["HDEL", group_key(Gid), ?FIELD_BACKGROUND]),
    ok;
set_background(Gid, Background) ->
    {ok, _Res} = q(["HSET", group_key(Gid), ?FIELD_BACKGROUND, Background]),
    ok.

-spec set_audience_hash(Gid :: gid(), AudienceHash :: binary()) -> ok.
set_audience_hash(Gid, AudienceHash) ->
    {ok, _Res} = q(["HSET", group_key(Gid), ?FIELD_AUDIENCE_HASH, AudienceHash]),
    ok.

-spec delete_audience_hash(Gid :: gid()) -> ok.
delete_audience_hash(Gid) ->
    {ok, _Res} = q(delete_audience_hash_command(Gid)),
    ok.

-spec has_invite_link(Gid :: gid()) -> boolean().
has_invite_link(Gid) ->
    {ok, Link} = q(["HGET", group_key(Gid), ?FIELD_INVITE_LINK]),
    Link =/= undefined.


-spec get_invite_link(Gid :: gid()) -> {IsNew :: boolean(), Link :: binary()}.
get_invite_link(Gid) ->
    Link = gen_group_invite_link(),
    [{ok, SetRes}, {ok, Link2}] = qp([
        ["HSETNX", group_key(Gid), ?FIELD_INVITE_LINK, Link],
        ["HGET", group_key(Gid), ?FIELD_INVITE_LINK]
        ]),
    IsNew = util_redis:decode_boolean(SetRes),
    case IsNew of
        false -> ok;
        true ->
            Link2 = Link, % just making sure they are the same
            set_group_invite_link(Link2, Gid)
    end,
    {IsNew, Link2}.

-spec reset_invite_link(Gid :: gid()) -> Link :: binary().
reset_invite_link(Gid) ->
    Link = gen_group_invite_link(),
    Result = qp([
        ["MULTI"],
        ["HGET", group_key(Gid), ?FIELD_INVITE_LINK],
        ["HSET", group_key(Gid), ?FIELD_INVITE_LINK, Link],
        ["EXEC"]
    ]),
    [_, _, _, {ok, [OldLink, _SetRes]}] = Result,
    remove_group_invite_link(OldLink),
    set_group_invite_link(Link, Gid),
    Link.


remove_group_invite_link(undefined) -> ok;
remove_group_invite_link(Link) ->
    {ok, _Res} = q(["DEL", group_invite_link_key(Link)]),
    ok.

-spec set_group_invite_link(Link :: binary(), Gid :: gid()) -> ok.
set_group_invite_link(Link, Gid) ->
    % SETNX protects agains the very unlikely case of duplicate link
    {ok, _Res} = q(["SETNX", group_invite_link_key(Link), Gid]),
    ok.

-spec get_invite_link_gid(Link :: binary()) -> maybe(gid()).
get_invite_link_gid(undefined) -> undefined;
get_invite_link_gid(<<>>) -> undefined;
get_invite_link_gid(Link) ->
    {ok, Gid} = q(["GET", group_invite_link_key(Link)]),
    case Gid of
        undefined -> undefined;
        _ ->
            {ok, CurLink} = q(["HGET", group_key(Gid), ?FIELD_INVITE_LINK]),
            case Link =:= CurLink of
                true -> Gid;
                false ->
                    % This might happen if we fail to delete and old link.
                    ?WARNING("Group link mismatch Gid: ~p Link ~p", [Gid, Link]),
                    undefined
            end
    end.


-spec is_removed_member(Gid :: gid(), Uid :: uid()) -> boolean().
is_removed_member(Gid, Uid) ->
    {ok, Res} = q(["SISMEMBER", group_removed_set_key(Gid), Uid]),
    util_redis:decode_boolean(Res).


-spec add_removed_members(Gid :: gid(), Uids :: [uid()]) -> non_neg_integer().
add_removed_members(_Gid, []) ->
    0;
add_removed_members(Gid, Uids) ->
    {ok, Res} = q(["SADD", group_removed_set_key(Gid) | Uids]),
    util_redis:decode_int(Res).


-spec remove_removed_members(Gid :: gid(), AddUids :: [uid()]) -> non_neg_integer().
remove_removed_members(_Gid, []) ->
    0;
remove_removed_members(Gid, Uids) ->
    {ok, Res} = q(["SREM", group_removed_set_key(Gid) | Uids]),
    util_redis:decode_int(Res).


-spec clear_removed_members_set(Gid :: gid()) -> ok.
clear_removed_members_set(Gid) ->
    {ok, _} = q(["DEL", group_removed_set_key(Gid)]),
    ok.


delete_audience_hash_command(Gid) ->
    ["HDEL", group_key(Gid), ?FIELD_AUDIENCE_HASH].


gen_group_invite_link() ->
    util:random_str(?GROUP_INVITE_LINK_SIZE).


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


encode_expiry_type(expires_in_seconds) -> <<"sec">>;
encode_expiry_type(custom_date) -> <<"date">>;
encode_expiry_type(never) -> <<"never">>;
encode_expiry_type(_) -> <<"sec">>.


decode_expiry_type(<<"sec">>) -> expires_in_seconds;
decode_expiry_type(<<"date">>) -> custom_date;
decode_expiry_type(<<"never">>) -> never;
decode_expiry_type(_) -> expires_in_seconds.


-spec decode_members(Gid :: gid(), MembersMap :: map()) -> [group_member()].
decode_members(Gid, MembersMap)
        when is_map(MembersMap) ->
    maps:fold(
        fun (Uid, MemberValue, Acc) ->
            case decode_member(Uid, MemberValue) of
                {ok, Member} ->
                    [Member | Acc];
                {error, Reason} ->
                    ?ERROR("decode failed ~p Gid: ~s Uid: ~s Value: ~s",
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
        {MemberType, Ts, _AddedBy} = decode_member_value(MemberValue),
        Member = #group_member{
            uid = Uid,
            type = MemberType,
            joined_ts_ms = Ts
        },
        {ok, Member}
    catch
        Class:Reason:Stacktrace ->
            ?ERROR("Stacktrace:~s",
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


-spec group_invite_link_key(Link :: binary()) -> binary().
group_invite_link_key(Link) ->
    <<?GROUP_INVITE_LINK_KEY/binary, "{", Link/binary, "}">>.


-spec group_removed_set_key(Gid :: gid()) -> binary().
group_removed_set_key(Gid) ->
    <<?GROUP_REMOVED_SET_KEY/binary, <<"{">>/binary, Gid/binary, <<"}">>/binary>>.


q(Command) -> ecredis:q(ecredis_groups, Command).
qp(Commands) -> ecredis:qp(ecredis_groups, Commands).
qmn(Commands) -> util_redis:run_qmn(ecredis_groups, Commands).

multi_exec(Commands) ->
    WrappedCommands = lists:append([[["MULTI"]], Commands, [["EXEC"]]]),
    Results = qp(WrappedCommands),
    [ExecResult | _Rest] = lists:reverse(Results),
    ExecResult.


-spec count_groups_key(Gid :: gid()) -> binary().
count_groups_key(Gid) ->
    Slot = crc16_redis:hash(binary_to_list(Gid)),
    count_groups_key_slot(Slot).


count_groups_key_slot(Slot) ->
    redis_counts:count_key(Slot, ?COUNT_GROUPS_KEY).


-spec count_groups() -> non_neg_integer().
count_groups() ->
    redis_counts:count_fold(fun model_groups:count_groups/1).


-spec count_groups(Slot :: non_neg_integer()) -> non_neg_integer().
count_groups(Slot) ->
    {ok, CountBin} = q(["GET", count_groups_key_slot(Slot)]),
    Count = case CountBin of
        undefined -> 0;
        CountBin -> binary_to_integer(CountBin)
    end,
    Count.

