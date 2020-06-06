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
    get_group/1,
    get_group_info/1,
    add_member/3,
    remove_member/2,
    promote_admin/2,
    demote_admin/2,
    is_member/2,
    is_admin/2
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
    {ok, _} = q([
        "HSET",
        group_key(Gid),
        ?FIELD_NAME, Name,
        ?FIELD_CREATION_TIME, integer_to_binary(Ts),
        ?FIELD_CREATED_BY, Uid
    ]),
    {ok, true} = add_member_internal(Gid, Uid, Uid, admin),
    {ok, Gid}.


-spec group_exists(Gid :: gid()) -> boolean().
group_exists(Gid) ->
    {ok, Res} = q(["EXISTS", group_key(Gid)]),
    binary_to_integer(Res) == 1.


-spec get_member_uids(Gid :: gid()) -> [uid()].
get_member_uids(Gid) ->
    {ok, Members} = q(["HKEYS", members_key(Gid)]),
    Members.


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
                members = Members
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


-spec add_member(Gid :: gid(), Uid :: uid(), AdminUid :: uid()) -> {ok, boolean()}.
add_member(Gid, Uid, AdminUid) ->
    add_member_internal(Gid, Uid, AdminUid, member).


-spec remove_member(Gid :: gid(), Uid :: uid()) -> {ok, boolean()}.
remove_member(Gid, Uid) ->
    {ok, Res} = q(["HDEL", members_key(Gid), Uid]),
    {ok, binary_to_integer(Res) == 1}.


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


add_member_internal(Gid, Uid, AdminUid, Type) ->
    MemberValue = encode_member_value(Type, util:now_ms(), AdminUid),
    {ok, Res} = q(["HSET", members_key(Gid), Uid, MemberValue]),
    {ok, binary_to_integer(Res) == 1}.


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


-spec group_key(Gid :: gid()) -> binary().
group_key(Gid) ->
    <<?GROUP_KEY/binary, <<"{">>/binary, Gid/binary, <<"}">>/binary>>.


-spec members_key(Gid :: gid()) -> binary().
members_key(Gid) ->
    <<?GROUP_MEMBERS_KEY/binary, <<"{">>/binary, Gid/binary, <<"}">>/binary>>.


%% TODO: This code is kind of copied in all the models...
q(Command) ->
    {ok, Result} = gen_server:call(redis_groups_client, {q, Command}),
    Result.


qp(Commands) ->
    {ok, Results} = gen_server:call(redis_groups_client, {qp, Commands}),
    Results.

