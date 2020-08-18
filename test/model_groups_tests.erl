%%%-------------------------------------------------------------------
%%% File: model_phone_tests.erl
%%% Copyright (C) 2020, Halloapp Inc.
%%%
%%%-------------------------------------------------------------------
-module(model_groups_tests).
-author("nikola").

-include("groups.hrl").
-include("groups_test_data.hrl").
-include_lib("eunit/include/eunit.hrl").

setup() ->
    mod_redis:start(undefined, []),
    clear(),
    ok.

clear() ->
    {ok, ok} = gen_server:call(redis_groups_client, flushdb).

group_key_test() ->
    ?assertEqual(<<"g:{g9kljfdl39kfsljlsfj03}">>, model_groups:group_key(?GID1)).


members_key_test() ->
    ?assertEqual(<<"gm:{g9kljfdl39kfsljlsfj03}">>, model_groups:members_key(?GID1)).


user_groups_key_test() ->
    ?assertEqual(<<"ug:{1}">>, model_groups:user_groups_key(?UID1)).


create_group_test() ->
    setup(),
    {ok, Gid} = model_groups:create_group(?UID1, ?GROUP_NAME1),
    ?assertEqual(true, model_groups:group_exists(Gid)),
    ?assertEqual([?UID1], model_groups:get_member_uids(Gid)),
    ok.

delete_group_test() ->
    setup(),
    {ok, Gid} = model_groups:create_group(?UID1, ?GROUP_NAME1),
    ?assertEqual(true, model_groups:group_exists(Gid)),
    ?assertEqual(ok, model_groups:delete_group(Gid)),
    ?assertEqual(false, model_groups:group_exists(Gid)),
    ?assertEqual(0, model_groups:get_group_size(Gid)),
    ok.

add_member_test() ->
    setup(),
    {ok, Gid} = model_groups:create_group(?UID1, ?GROUP_NAME1),
    ?assertEqual([?UID1], model_groups:get_member_uids(Gid)),
    {ok, true} = model_groups:add_member(Gid, ?UID2, ?UID1),
    {ok, false} = model_groups:add_member(Gid, ?UID2, ?UID1),
    ?assertEqual([?UID1, ?UID2], model_groups:get_member_uids(Gid)),
    {ok, true} = model_groups:add_member(Gid, ?UID3, ?UID1),
    ?assertEqual([?UID1, ?UID2, ?UID3], model_groups:get_member_uids(Gid)),
    ok.

encode_member_test() ->
    ?assertEqual(<<"m">>, model_groups:encode_member_type(member)),
    ?assertEqual(<<"a">>, model_groups:encode_member_type(admin)),
    ?assertError({bad_member_type, bla}, model_groups:encode_member_type(bla)),
    ok.

remove_member_test() ->
    setup(),
    {ok, Gid} = model_groups:create_group(?UID1, ?GROUP_NAME1),
    ?assertEqual([?UID1], model_groups:get_member_uids(Gid)),
    {ok, true} = model_groups:add_member(Gid, ?UID2, ?UID1),
    {ok, true} = model_groups:add_member(Gid, ?UID3, ?UID1),
    ?assertEqual([?UID1, ?UID2, ?UID3], model_groups:get_member_uids(Gid)),
    {ok, true} = model_groups:remove_member(Gid, ?UID2),
    {ok, false} = model_groups:remove_member(Gid, ?UID2),
    ?assertEqual([?UID1, ?UID3], model_groups:get_member_uids(Gid)),
    ok.

get_group_test() ->
    setup(),
    Ts = util:now_ms(),
    {ok, Gid} = model_groups:create_group(?UID1, ?GROUP_NAME1, Ts),
    Group = model_groups:get_group(Gid),
    ?assertEqual(?GROUP_NAME1, Group#group.name),
    ?assertEqual(undefined, Group#group.avatar),
    ?assertEqual(Ts, Group#group.creation_ts_ms),
    ?assertEqual([#group_member{uid = ?UID1, type = admin}], Group#group.members),
    ok.

get_member_uids_test() ->
    setup(),
    {ok, Gid} = model_groups:create_group(?UID1, ?GROUP_NAME1),
    {ok, true} = model_groups:add_member(Gid, ?UID2, ?UID1),
    {ok, true} = model_groups:add_member(Gid, ?UID3, ?UID1),
    ?assertEqual([?UID1, ?UID2, ?UID3], model_groups:get_member_uids(Gid)),
    ok.

get_group_size_test() ->
    setup(),
    {ok, Gid} = model_groups:create_group(?UID1, ?GROUP_NAME1),
    ?assertEqual(1, model_groups:get_group_size(Gid)),
    {ok, true} = model_groups:add_member(Gid, ?UID2, ?UID1),
    ?assertEqual(2, model_groups:get_group_size(Gid)),
    {ok, true} = model_groups:add_member(Gid, ?UID3, ?UID1),
    ?assertEqual(3, model_groups:get_group_size(Gid)),
    {ok, true} = model_groups:remove_member(Gid, ?UID3),
    {ok, true} = model_groups:remove_member(Gid, ?UID2),
    ?assertEqual(1, model_groups:get_group_size(Gid)),
    ok.

is_member_test() ->
    setup(),
    {ok, Gid} = model_groups:create_group(?UID1, ?GROUP_NAME1),
    ?assertEqual(true, model_groups:is_member(Gid, ?UID1)),
    ?assertEqual(false, model_groups:is_member(Gid, ?UID2)),
    ?assertEqual(false, model_groups:is_member(Gid, ?UID3)),
    {ok, true} = model_groups:add_member(Gid, ?UID2, ?UID1),
    {ok, true} = model_groups:add_member(Gid, ?UID3, ?UID1),
    ?assertEqual(true, model_groups:is_member(Gid, ?UID1)),
    ?assertEqual(true, model_groups:is_member(Gid, ?UID2)),
    ?assertEqual(true, model_groups:is_member(Gid, ?UID3)),
    ok.

is_admin_test() ->
    setup(),
    {ok, Gid} = model_groups:create_group(?UID1, ?GROUP_NAME1),
    ?assertEqual(true, model_groups:is_admin(Gid, ?UID1)),
    ?assertEqual(false, model_groups:is_admin(Gid, ?UID2)),
    {ok, true} = model_groups:add_member(Gid, ?UID2, ?UID1),
    {ok, true} = model_groups:promote_admin(Gid, ?UID2),
    ?assertEqual(true, model_groups:is_admin(Gid, ?UID2)),
    {ok, true} = model_groups:demote_admin(Gid, ?UID2),
    ?assertEqual(false, model_groups:is_admin(Gid, ?UID2)),
    ?assertEqual(true, model_groups:is_admin(Gid, ?UID1)),
    ok.


promote_admin_not_member_test() ->
    setup(),
    {ok, Gid} = model_groups:create_group(?UID1, ?GROUP_NAME1),
    ?assertEqual({error, not_member}, model_groups:promote_admin(Gid, ?UID2)),
    {ok, true} = model_groups:add_member(Gid, ?UID2, ?UID1),
    ?assertEqual({ok, true}, model_groups:promote_admin(Gid, ?UID2)),
    ?assertEqual({ok, false}, model_groups:promote_admin(Gid, ?UID2)),
    ok.

decode_member_test() ->
    {ok, Member} = model_groups:decode_member(?UID1, <<"a,123,2">>),
    ?assertEqual(Member#group_member.uid, ?UID1),
    ?assertEqual(Member#group_member.type, admin),
    {error, _Reason} = model_groups:decode_member(?UID1, <<"x,123,2">>),
    ok.

add_members_test() ->
    setup(),
    {ok, Gid} = model_groups:create_group(?UID1, ?GROUP_NAME1),
    [true, true] = model_groups:add_members(Gid, [?UID2, ?UID3], ?UID1),
    ?assertEqual([?UID1, ?UID2, ?UID3], model_groups:get_member_uids(Gid)),
    ok.

remove_members_test() ->
    setup(),
    {ok, Gid} = model_groups:create_group(?UID1, ?GROUP_NAME1),
    ?assertEqual([true, true], model_groups:add_members(Gid, [?UID2, ?UID3], ?UID1)),
    ?assertEqual([?UID1, ?UID2, ?UID3], model_groups:get_member_uids(Gid)),
    ?assertEqual({ok, 2}, model_groups:remove_members(Gid, [?UID2, ?UID3])),
    ?assertEqual({ok, 0}, model_groups:remove_members(Gid, [?UID2, ?UID3])),
    ok.

get_groups_test() ->
    setup(),
    [] = model_groups:get_groups(?UID1),
    {ok, Gid} = model_groups:create_group(?UID1, ?GROUP_NAME1),
    ?assertEqual([true, true], model_groups:add_members(Gid, [?UID2, ?UID3], ?UID1)),
    ?assertEqual([Gid], model_groups:get_groups(?UID1)),
    ?assertEqual([Gid], model_groups:get_groups(?UID2)),
    ?assertEqual([], model_groups:get_groups(?UID4)),
    {ok, Gid2} = model_groups:create_group(?UID2, ?GROUP_NAME2),
    ?assertEqual([true, true], model_groups:add_members(Gid2, [?UID1, ?UID4], ?UID2)),
    ?assertEqual(lists:sort([Gid, Gid2]), lists:sort(model_groups:get_groups(?UID1))),
    ?assertEqual(lists:sort([Gid, Gid2]), lists:sort(model_groups:get_groups(?UID2))),
    ?assertEqual(lists:sort([Gid]), lists:sort(model_groups:get_groups(?UID3))),
    ?assertEqual(lists:sort([Gid2]), lists:sort(model_groups:get_groups(?UID4))),
    ok.

set_avatar_test() ->
    setup(),
    {ok, Gid} = model_groups:create_group(?UID1, ?GROUP_NAME1),
    Group1 = model_groups:get_group(Gid),
    ?assertEqual(undefined, Group1#group.avatar),

    ?assertEqual(ok, model_groups:set_avatar(Gid, ?AVATAR1)),
    Group2 = model_groups:get_group(Gid),
    ?assertEqual(?AVATAR1, Group2#group.avatar),
    Gid.

delete_avatar_test() ->
    Gid = set_avatar_test(),
    ?assertEqual(ok, model_groups:delete_avatar(Gid)),
    Group1 = model_groups:get_group(Gid),
    ?assertEqual(undefined, Group1#group.avatar),
    ok.


count_groups_test() ->
    setup(),
    {ok, Gid1} = model_groups:create_group(?UID1, ?GROUP_NAME1),
    {ok, Gid2} = model_groups:create_group(?UID2, ?GROUP_NAME2),
    ?assertEqual(2, model_groups:count_groups()),
    ok = model_groups:delete_group(Gid1),
    ok = model_groups:delete_group(Gid2),
    ?assertEqual(0, model_groups:count_groups()),
    ok.

