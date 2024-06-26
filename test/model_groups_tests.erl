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
    tutil:setup(),
    ha_redis:start(),
    clear(),
    ok.

clear() ->
    tutil:cleardb(redis_groups).

fixture_setup() ->
    tutil:setup([
        {redis, [redis_groups]}
    ]).

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
    ?assertEqual([], model_groups:get_groups(?UID1)),
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

    ?assertEqual(ok, model_groups:set_audience_hash(Gid, ?AUDIENCE_HASH)),
    {ok, true} = model_groups:remove_member(Gid, ?UID2),
    Group2 = model_groups:get_group_info(Gid),
    ?assertEqual(undefined, Group2#group_info.audience_hash),
    ?assertEqual(ok, model_groups:set_audience_hash(Gid, ?AUDIENCE_HASH)),
    {ok, false} = model_groups:remove_member(Gid, ?UID2),
    Group3 = model_groups:get_group_info(Gid),
    ?assertEqual(undefined, Group3#group_info.audience_hash),
    ?assertEqual([?UID1, ?UID3], model_groups:get_member_uids(Gid)),
    ok.

get_group_test() ->
    setup(),
    tutil:meck_init(util, now_ms, fun() -> ?TIMESTAMP end),
    Ts = util:now_ms(),
    {ok, Gid} = model_groups:create_group(?UID1, ?GROUP_NAME1, never, -1, Ts),
    Group = model_groups:get_group(Gid),
    ?assertEqual(?GROUP_NAME1, Group#group.name),
    ?assertEqual(undefined, Group#group.avatar),
    ?assertEqual(Ts, Group#group.creation_ts_ms),
    ?assertEqual([#group_member{uid = ?UID1, type = admin, joined_ts_ms = ?TIMESTAMP}],
        Group#group.members),
    tutil:meck_finish(util),
    ok.

get_member_uids_test(_) ->
    {ok, Gid} = model_groups:create_group(?UID1, ?GROUP_NAME1),
    {ok, true} = model_groups:add_member(Gid, ?UID2, ?UID1),
    {ok, true} = model_groups:add_member(Gid, ?UID3, ?UID1),
    G1Uids = sets:from_list(model_groups:get_member_uids(Gid)),

    {ok, Gid2} = model_groups:create_group(?UID2, ?GROUP_NAME2),
    [true, true] = model_groups:add_members(Gid2, [?UID1, ?UID4], ?UID2),
    G2Uids = sets:from_list(model_groups:get_member_uids(Gid2)),
    #{Gid := G1UidList, Gid2 := G2UidList} = model_groups:get_member_uids([Gid, Gid2]),

    [?_assertEqual(sets:from_list([?UID1, ?UID2, ?UID3]), G1Uids), 
    ?_assertEqual(sets:from_list([?UID1, ?UID2, ?UID4]), G2Uids),
    ?_assertEqual(sets:from_list([?UID1, ?UID2, ?UID3]), sets:from_list(G1UidList)), 
    ?_assertEqual(sets:from_list([?UID1, ?UID2, ?UID4]), sets:from_list(G2UidList))].

get_groups_size_test(_) ->
    {ok, Gid} = model_groups:create_group(?UID1, ?GROUP_NAME1),
    {ok, true} = model_groups:add_member(Gid, ?UID2, ?UID1),
    {ok, true} = model_groups:add_member(Gid, ?UID3, ?UID1),
    G1Size = model_groups:get_group_size(Gid),

    {ok, Gid2} = model_groups:create_group(?UID2, ?GROUP_NAME2),
    [true, true, true] = model_groups:add_members(Gid2, [?UID1, ?UID3, ?UID4], ?UID2),
    G2Size = model_groups:get_group_size(Gid2),
    #{Gid := G1Size1, Gid2 := G2Size1} = model_groups:get_group_size([Gid, Gid2]),

    [?_assertEqual(G1Size, G1Size1), 
    ?_assertEqual(G2Size, G2Size1)].

mmembership_test_() ->
    [
        {foreach, fun fixture_setup/0, fun tutil:cleanup/1, [
            fun get_member_uids_test/1, fun get_groups_size_test/1
        ]}
    ].

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
    ?assertEqual([true, true], model_groups:remove_members(Gid, [?UID2, ?UID3])),
    ?assertEqual([false, false], model_groups:remove_members(Gid, [?UID2, ?UID3])),
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


get_group_counts_test() ->
    setup(),
    {ok, Gid} = model_groups:create_group(?UID1, ?GROUP_NAME1),
    ?assertEqual(1, model_groups:get_group_count(?UID1)),
    {ok, _} = model_groups:create_group(?UID1, ?GROUP_NAME2),
    ?assertEqual(#{?UID1 => 2, ?UID2 => 0}, model_groups:get_group_counts([?UID1, ?UID2])),
    [true] = model_groups:add_members(Gid, [?UID2], ?UID1),
    ?assertEqual(#{?UID1 => 2, ?UID2 => 1}, model_groups:get_group_counts([?UID1, ?UID2])),
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


delete_empty_group_test() ->
    setup(),
    {ok, Gid1} = model_groups:create_group(?UID1, ?GROUP_NAME1),
    ok = model_groups:delete_empty_group(Gid1),
    ?assertEqual([Gid1], model_groups:get_groups(?UID1)),
    ok.


get_invite_link_test() ->
    setup(),
    {ok, Gid1} = model_groups:create_group(?UID1, ?GROUP_NAME1),
    ?assertEqual(false, model_groups:has_invite_link(Gid1)),
    {IsNew, Link} = model_groups:get_invite_link(Gid1),
    ?assertEqual(true, model_groups:has_invite_link(Gid1)),
    ?assertEqual(true, IsNew),
    ?assertEqual(24, byte_size(Link)),
    ?assertEqual(Gid1, model_groups:get_invite_link_gid(Link)),
    {IsNew2, Link2} = model_groups:get_invite_link(Gid1),
    ?assertEqual(false, IsNew2),
    ?assertEqual(Link, Link2),
    ?assertEqual(Gid1, model_groups:get_invite_link_gid(Link)),
    ok.


reset_invite_link_test() ->
    setup(),
    {ok, Gid1} = model_groups:create_group(?UID1, ?GROUP_NAME1),
    {true, Link} = model_groups:get_invite_link(Gid1),
    ?assertEqual(Gid1, model_groups:get_invite_link_gid(Link)),
    Link2 = model_groups:reset_invite_link(Gid1),
    ?assertNotEqual(Link, Link2),
    ?assertEqual(undefined, model_groups:get_invite_link_gid(Link)),
    ?assertEqual(Gid1, model_groups:get_invite_link_gid(Link2)),
    ok.


get_invite_link_git_test() ->
    setup(),
    {ok, Gid1} = model_groups:create_group(?UID1, ?GROUP_NAME1),
    ?assertEqual(undefined, model_groups:get_invite_link_gid(undefined)),
    ?assertEqual(undefined, model_groups:get_invite_link_gid(<<>>)),
    {true, Link} = model_groups:get_invite_link(Gid1),
    ?assertEqual(Gid1, model_groups:get_invite_link_gid(Link)),
    ok.


add_removed_member_test() ->
    setup(),
    {ok, Gid1} = model_groups:create_group(?UID1, ?GROUP_NAME1),
    ?assertEqual(0, model_groups:add_removed_members(Gid1, [])),
    ?assertEqual(1, model_groups:add_removed_members(Gid1, [?UID2])),
    ?assertEqual(0, model_groups:add_removed_members(Gid1, [?UID2])),
    ok.


remove_removed_member_test() ->
    setup(),
    {ok, Gid1} = model_groups:create_group(?UID1, ?GROUP_NAME1),
    ?assertEqual(2, model_groups:add_removed_members(Gid1, [?UID2, ?UID3])),
    ?assertEqual(true, model_groups:is_removed_member(Gid1, [?UID2])),
    ?assertEqual(true, model_groups:is_removed_member(Gid1, [?UID3])),
    ?assertEqual(0, model_groups:remove_removed_members(Gid1, [])),
    ?assertEqual(0, model_groups:remove_removed_members(Gid1, [?UID4])),
    ?assertEqual(2, model_groups:remove_removed_members(Gid1, [?UID2, ?UID3])),
    ?assertEqual(false, model_groups:is_removed_member(Gid1, [?UID2])),
    ?assertEqual(false, model_groups:is_removed_member(Gid1, [?UID3])),
    ok.


is_removed_member_test() ->
    setup(),
    {ok, Gid1} = model_groups:create_group(?UID1, ?GROUP_NAME1),
    ?assertEqual(false, model_groups:is_removed_member(Gid1, ?UID2)),
    ?assertEqual(false, model_groups:is_removed_member(Gid1, ?UID3)),
    ?assertEqual(1, model_groups:add_removed_members(Gid1, [?UID2])),
    ?assertEqual(true, model_groups:is_removed_member(Gid1, ?UID2)),
    ?assertEqual(false, model_groups:is_removed_member(Gid1, ?UID3)),
    ok.


clear_removed_members_set_test() ->
    setup(),
    {ok, Gid1} = model_groups:create_group(?UID1, ?GROUP_NAME1),
    ?assertEqual(false, model_groups:is_removed_member(Gid1, ?UID2)),
    ?assertEqual(false, model_groups:is_removed_member(Gid1, ?UID3)),
    ?assertEqual(1, model_groups:add_removed_members(Gid1, [?UID2])),
    ?assertEqual(1, model_groups:add_removed_members(Gid1, [?UID3])),
    ?assertEqual(true, model_groups:is_removed_member(Gid1, ?UID2)),
    ?assertEqual(true, model_groups:is_removed_member(Gid1, ?UID3)),
    ok = model_groups:clear_removed_members_set(Gid1),
    ?assertEqual(false, model_groups:is_removed_member(Gid1, ?UID2)),
    ?assertEqual(false, model_groups:is_removed_member(Gid1, ?UID3)),
    ok.


set_background_test() ->
    setup(),
    {ok, Gid1} = model_groups:create_group(?UID1, ?GROUP_NAME1),
    Group1 = model_groups:get_group(Gid1),
    ?assertEqual(undefined, Group1#group.background),
    model_groups:set_background(Gid1, ?BACKGROUND1),
    Group2 = model_groups:get_group(Gid1),
    ?assertEqual(?BACKGROUND1, Group2#group.background),
    model_groups:set_background(Gid1, undefined),
    Group3 = model_groups:get_group(Gid1),
    ?assertEqual(undefined, Group3#group.background),
    ok.


audience_hash_test() ->
    setup(),
    {ok, Gid} = model_groups:create_group(?UID1, ?GROUP_NAME1),
    Group1 = model_groups:get_group_info(Gid),
    ?assertEqual(undefined, Group1#group_info.audience_hash),

    ?assertEqual(ok, model_groups:delete_audience_hash(Gid)),
    Group3 = model_groups:get_group_info(Gid),
    ?assertEqual(undefined, Group3#group_info.audience_hash),

    ?assertEqual(ok, model_groups:set_audience_hash(Gid, ?AUDIENCE_HASH)),
    Group2 = model_groups:get_group_info(Gid),
    ?assertEqual(?AUDIENCE_HASH, Group2#group_info.audience_hash),

    ?assertEqual(ok, model_groups:delete_audience_hash(Gid)),
    Group3 = model_groups:get_group_info(Gid),
    ?assertEqual(undefined, Group3#group_info.audience_hash),
    ok.


% delete_group_perf_test() ->
%     tutil:perf(
%         10,
%         fun() -> setup() end,
%         fun() ->
%             {ok, Gid} = model_groups:create_group(?UID1, ?GROUP_NAME1),
%             model_groups:add_members(Gid, [?UID2, ?UID3, ?UID4, ?UID5], ?UID1),
%             model_groups:delete_group(Gid)
%         end
%     ).


% remove_member_perf_test() ->
%     tutil:perf(
%         10,
%         fun() -> setup() end,
%         fun() ->
%             {ok, Gid} = model_groups:create_group(?UID1, ?GROUP_NAME1),
%             model_groups:remove_members(Gid, [?UID1, ?UID2, ?UID3, ?UID4])
%         end
%     ).


% add_member_perf_test() ->
%     tutil:perf(
%         10,
%         fun() -> setup() end,
%         fun() ->
%             {ok, Gid} = model_groups:create_group(?UID1, ?GROUP_NAME1),
%             model_groups:add_members(Gid, [?UID2, ?UID3, ?UID4, ?UID5], ?UID1)
%         end
%     ).

