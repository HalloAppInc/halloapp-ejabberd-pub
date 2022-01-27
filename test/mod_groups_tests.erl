%%%-------------------------------------------------------------------
%%% File: model_phone_tests.erl
%%% Copyright (C) 2020, Halloapp Inc.
%%%
%%%-------------------------------------------------------------------
-module(mod_groups_tests).
-author("nikola").

-include("groups.hrl").
-include("xmpp.hrl").
-include("groups_test_data.hrl").
-include_lib("eunit/include/eunit.hrl").


setup() ->
    tutil:setup(),
    stringprep:start(),
    ha_redis:start(),
    clear(),
    setup_accounts(),
    ok.

setup_accounts() ->
    model_accounts:create_account(?UID1, ?PHONE1, ?NAME1, ?UA),
    model_accounts:create_account(?UID2, ?PHONE2, ?NAME2, ?UA),
    model_accounts:create_account(?UID3, ?PHONE3, ?NAME3, ?UA),
    model_accounts:create_account(?UID4, ?PHONE4, ?NAME4, ?UA),
    ok.

clear() ->
    tutil:cleardb(redis_groups),
    tutil:cleardb(redis_accounts).

create_empty_group_test() ->
    setup(),
    meck:new(util, [passthrough]),
    meck:expect(util, now_ms, fun() -> ?TIMESTAMP end),
    {ok, Group} = mod_groups:create_group(?UID1, ?GROUP_NAME1),
    Gid = Group#group.gid,
%%    ?debugVal(Group),
    ?assertEqual(?GROUP_NAME1, Group#group.name),
    ?assertEqual(undefined, Group#group.avatar),
    ?assertEqual(Gid, Group#group.gid),
    % make sure the time is close to now.
    ?assertEqual(?TIMESTAMP, Group#group.creation_ts_ms),
    ?assertEqual([#group_member{uid = ?UID1, type = admin, joined_ts_ms = ?TIMESTAMP}],
        Group#group.members),
    ?assert(meck:validate(util)),
    meck:unload(util),
    ok.

create_group_bad_name_test() ->
    setup(),
    ?assertEqual({error, invalid_name}, mod_groups:create_group(?UID1, 1234)),
    ?assertEqual({error, invalid_name}, mod_groups:create_group(?UID1, <<"">>)),
    {ok, Group} = mod_groups:create_group(?UID1, <<"123456789012345678901234567890">>),
    ?assertEqual(<<"1234567890123456789012345">>, Group#group.name),
    ok.

create_group_with_members_test() ->
    setup(),
    meck:new(util, [passthrough]),
    meck:expect(util, now_ms, fun() -> ?TIMESTAMP end),
    {ok, Group, AddMemberResult} = mod_groups:create_group(?UID1, ?GROUP_NAME1, [?UID2, ?UID3]),
    ?assertEqual(?GROUP_NAME1, Group#group.name),
    ?assertEqual(3, length(Group#group.members)),
    [M1, M2, M3] = Group#group.members,
    ?assertEqual(#group_member{uid = ?UID1, type = admin, joined_ts_ms = ?TIMESTAMP}, M1),
    ?assertEqual(#group_member{uid = ?UID2, type = member, joined_ts_ms = ?TIMESTAMP}, M2),
    ?assertEqual(#group_member{uid = ?UID3, type = member, joined_ts_ms = ?TIMESTAMP}, M3),
    ExpectedAddMemberResult = [
        {?UID2, add, ok},
        {?UID3, add, ok}
    ],
    ?assertEqual(ExpectedAddMemberResult, AddMemberResult),
    ?assert(meck:validate(util)),
    meck:unload(util),
    ok.

create_group_member_has_no_account_test() ->
    setup(),
    meck:new(util, [passthrough]),
    meck:expect(util, now_ms, fun() -> ?TIMESTAMP end),
    {ok, Group, AddMemberResult} = mod_groups:create_group(?UID1, ?GROUP_NAME1, [?UID2, ?UID5]),
    ?assertEqual(2, length(Group#group.members)),
    [M1, M2] = Group#group.members,
    ?assertEqual(#group_member{uid = ?UID1, type = admin, joined_ts_ms = ?TIMESTAMP}, M1),
    ?assertEqual(#group_member{uid = ?UID2, type = member, joined_ts_ms = ?TIMESTAMP}, M2),
    ExpectedAddMemberResult = [
        {?UID2, add, ok},
        {?UID5, add, no_account}
    ],
    ?assertEqual(ExpectedAddMemberResult, AddMemberResult),
    ?assert(meck:validate(util)),
    meck:unload(util),
    ok.


delete_group_test() ->
    setup(),
    {ok, Group, _AddMemberResult} = mod_groups:create_group(?UID1, ?GROUP_NAME1, [?UID2, ?UID3]),
    ?assertEqual({error, not_admin}, mod_groups:delete_group(Group#group.gid, ?UID2)),
    ?assertEqual({error, not_admin}, mod_groups:delete_group(Group#group.gid, ?UID3)),
    ?assertEqual(ok, mod_groups:delete_group(Group#group.gid, ?UID1)),

    ?assertEqual(undefined, model_groups:get_group(Group#group.gid)),
    ?assertEqual({error, not_member}, mod_groups:get_group(Group#group.gid, ?UID1)),
    ?assertEqual({error, not_member}, mod_groups:get_group(Group#group.gid, ?UID2)),
    ?assertEqual({error, not_member}, mod_groups:get_group(Group#group.gid, ?UID3)),
    ok.


% TODO: add test for max groups size.

add_members_test() ->
    setup(),
    {ok, Group} = mod_groups:create_group(?UID1, ?GROUP_NAME1),
    Gid = Group#group.gid,
    ?assertEqual({ok, []}, mod_groups:add_members(Gid, ?UID1, [])),
    ?assertEqual(
        {ok, [{?UID2, add, ok}, {?UID3, add, ok}]},
        mod_groups:add_members(Gid, ?UID1, [?UID2, ?UID3])),
    ?assertEqual(
        {ok, [{?UID4, add, ok}, {?UID5, add, no_account}]},
        mod_groups:add_members(Gid, ?UID1, [?UID4, ?UID5])),
    ok.

add_members_no_admin_test() ->
    setup(),
    {ok, Group} = mod_groups:create_group(?UID1, ?GROUP_NAME1),
    Gid = Group#group.gid,
    mod_groups:add_members(Gid, ?UID1, [?UID2, ?UID3]),
    ?assertEqual({error, not_admin}, mod_groups:add_members(Gid, ?UID2, [?UID4])),
    ok.

remove_members_test() ->
    setup(),
    {ok, Group} = mod_groups:create_group(?UID1, ?GROUP_NAME1),
    Gid = Group#group.gid,
    mod_groups:add_members(Gid, ?UID1, [?UID2, ?UID3]),
    ?assertEqual(3, model_groups:get_group_size(Gid)),
    ?assertEqual({ok, []}, mod_groups:remove_members(Gid, ?UID1, [])),
    ?assertEqual(3, model_groups:get_group_size(Gid)),
    ?assertEqual({ok, [{?UID3, remove, ok}]},
        mod_groups:remove_members(Gid, ?UID1, [?UID3])),
    ?assertEqual(2, model_groups:get_group_size(Gid)),
    ?assertEqual({ok, [{?UID2, remove, ok}, {?UID3, remove, already_not_member}]},
        mod_groups:remove_members(Gid, ?UID1, [?UID2, ?UID3])),
    ?assertEqual(1, model_groups:get_group_size(Gid)),
    ok.

remove_members_not_admin_test() ->
    setup(),
    {ok, Group} = mod_groups:create_group(?UID1, ?GROUP_NAME1),
    Gid = Group#group.gid,
    mod_groups:add_members(Gid, ?UID1, [?UID2, ?UID3]),
    % member but not admin
    ?assertEqual({error, not_admin}, mod_groups:remove_members(Gid, ?UID2, [?UID3])),
    % not member
    ?assertEqual({error, not_admin}, mod_groups:remove_members(Gid, ?UID4, [?UID3])),
    ok.

leave_group_test() ->
    setup(),
    {ok, Group} = mod_groups:create_group(?UID1, ?GROUP_NAME1),
    Gid = Group#group.gid,
    mod_groups:add_members(Gid, ?UID1, [?UID2, ?UID3]),
    ?assertEqual(true, model_groups:is_member(Gid, ?UID2)),
    ?assertEqual({ok, true}, mod_groups:leave_group(Gid, ?UID2)),
    ?assertEqual(false, model_groups:is_member(Gid, ?UID2)),
    ?assertEqual({ok, false}, mod_groups:leave_group(Gid, ?UID2)),
    ok.


remove_user_test() ->
    setup(),
    ?assertEqual(ok, mod_groups:remove_user(?UID1, <<>>)),
    {ok, Group1, _AddMemberResult} = mod_groups:create_group(?UID1, ?GROUP_NAME1, [?UID2, ?UID3]),
    {ok, Group2} = mod_groups:create_group(?UID1, ?GROUP_NAME2),
    Gid1 = Group1#group.gid,
    Gid2 = Group2#group.gid,
    ?assertEqual(ok, mod_groups:remove_user(?UID1, <<>>)),
    ?assertEqual(false, model_groups:is_member(Gid1, ?UID1)),
    ?assertEqual(false, model_groups:is_member(Gid2, ?UID1)),
    ?assertEqual(true, model_groups:group_exists(Gid1)),
    ?assertEqual(false, model_groups:group_exists(Gid2)),
    ok.


promote_admins_test() ->
    setup(),
    {ok, Group} = mod_groups:create_group(?UID1, ?GROUP_NAME1),
    Gid = Group#group.gid,
    mod_groups:add_members(Gid, ?UID1, [?UID2, ?UID3]),
    ?assertEqual(false, model_groups:is_admin(Gid, ?UID2)),
    ?assertEqual(true, model_groups:is_admin(Gid, ?UID1)),
    ?assertEqual(
        {ok, [{?UID2, promote, ok}, {?UID3, promote, ok}, {?UID4, promote, not_member}]},
        mod_groups:promote_admins(Gid, ?UID1, [?UID2, ?UID3, ?UID4])),
    ?assertEqual(true, model_groups:is_admin(Gid, ?UID2)),
    ?assertEqual(true, model_groups:is_admin(Gid, ?UID3)),
    ?assertEqual({ok, []}, mod_groups:promote_admins(Gid, ?UID1, [])),
    ok.

promote_admins_not_admin_test() ->
    setup(),
    {ok, Group} = mod_groups:create_group(?UID1, ?GROUP_NAME1),
    Gid = Group#group.gid,
    mod_groups:add_members(Gid, ?UID1, [?UID2, ?UID3]),
    ?assertEqual({error, not_admin}, mod_groups:promote_admins(Gid, ?UID2, [?UID3])),
    ok.

demote_admins_test() ->
    setup(),
    {ok, Group} = mod_groups:create_group(?UID1, ?GROUP_NAME1),
    Gid = Group#group.gid,
    mod_groups:add_members(Gid, ?UID1, [?UID2, ?UID3]),
    ?assertEqual(
        {ok, [{?UID2, promote, ok}, {?UID3, promote, ok}]},
        mod_groups:promote_admins(Gid, ?UID1, [?UID2, ?UID3])),
    ?assertEqual(true, model_groups:is_admin(Gid, ?UID2)),
    ?assertEqual(true, model_groups:is_admin(Gid, ?UID3)),
    ?assertEqual(
        {ok, [{?UID1, demote, ok}, {?UID4, demote, not_member}]},
        mod_groups:demote_admins(Gid, ?UID2, [?UID1, ?UID4])),
    ?assertEqual(false, model_groups:is_admin(Gid, ?UID1)),
    ?assertEqual(true, model_groups:is_member(Gid, ?UID1)),
    ok.

demote_admins_not_admin_test() ->
    setup(),
    {ok, Group} = mod_groups:create_group(?UID1, ?GROUP_NAME1),
    Gid = Group#group.gid,
    mod_groups:add_members(Gid, ?UID1, [?UID2, ?UID3]),
    ?assertEqual({error, not_admin}, mod_groups:demote_admins(Gid, ?UID2, [?UID3])),
    ok.

get_group_not_member_test() ->
    setup(),
    {ok, Group} = mod_groups:create_group(?UID1, ?GROUP_NAME1),
    Gid = Group#group.gid,
    ?assertEqual({error, not_member}, mod_groups:get_group(Gid, ?UID2)),
    ok.

get_group_test() ->
    setup(),
    meck:new(util, [passthrough]),
    meck:expect(util, now_ms, fun() -> ?TIMESTAMP end),
    {ok, Group} = mod_groups:create_group(?UID1, ?GROUP_NAME1),
    Gid = Group#group.gid,
    mod_groups:add_members(Gid, ?UID1, [?UID2, ?UID3]),
    {ok, Group2} = mod_groups:get_group(Gid, ?UID1),
    ExpectedGroup = #group{
        gid = Gid,
        name = ?GROUP_NAME1,
        creation_ts_ms = Group2#group.creation_ts_ms,
        members = [
            #group_member{uid = ?UID1, type = admin, joined_ts_ms = ?TIMESTAMP},
            #group_member{uid = ?UID2, type = member, joined_ts_ms = ?TIMESTAMP},
            #group_member{uid = ?UID3, type = member, joined_ts_ms = ?TIMESTAMP}
        ]
    },
    ?assertEqual(ExpectedGroup, Group2),
    ?assert(meck:validate(util)),
    meck:unload(util),
    ok.

get_groups_test() ->
    setup(),
    ?assertEqual([], mod_groups:get_groups(?UID1)),
    ?assertEqual([], mod_groups:get_groups(?UID2)),
    ?assertEqual([], mod_groups:get_groups(?UID3)),
    {ok, Group} = mod_groups:create_group(?UID1, ?GROUP_NAME1),
    Gid = Group#group.gid,
    mod_groups:add_members(Gid, ?UID1, [?UID2, ?UID3]),
    GroupInfo1 = #group_info{gid = Gid, name = ?GROUP_NAME1},

    ?assertEqual([GroupInfo1], mod_groups:get_groups(?UID1)),
    ?assertEqual([GroupInfo1], mod_groups:get_groups(?UID2)),
    ?assertEqual([GroupInfo1], mod_groups:get_groups(?UID3)),
    {ok, Group2} = mod_groups:create_group(?UID2, ?GROUP_NAME2),
    Gid2 = Group2#group.gid,
    GroupInfo2 = #group_info{gid = Gid2, name = ?GROUP_NAME2},
    mod_groups:add_members(Gid2, ?UID2, [?UID1, ?UID4]),
    ?assertEqual(lists:sort([GroupInfo1, GroupInfo2]), lists:sort(mod_groups:get_groups(?UID1))),
    ?assertEqual(lists:sort([GroupInfo1, GroupInfo2]), lists:sort(mod_groups:get_groups(?UID2))),
    ?assertEqual(lists:sort([GroupInfo1]), lists:sort(mod_groups:get_groups(?UID3))),
    ?assertEqual(lists:sort([GroupInfo2]), lists:sort(mod_groups:get_groups(?UID4))),
    mod_groups:leave_group(Gid2, ?UID4),
    ?assertEqual(lists:sort([]), lists:sort(mod_groups:get_groups(?UID4))),
    ok.

set_name_test() ->
    setup(),
    {ok, Group} = mod_groups:create_group(?UID1, ?GROUP_NAME1),
    Gid = Group#group.gid,
    ?assertEqual(?GROUP_NAME1, Group#group.name),
    ?assertEqual(ok, mod_groups:set_name(Gid, ?UID1, ?GROUP_NAME2_LONG_NAME)),
    {ok, GroupNew} = mod_groups:get_group(Gid, ?UID1),
    ?assertEqual(?GROUP_NAME2, GroupNew#group.name),
    ok.


set_description_test() ->
    setup(),
    {ok, Group} = mod_groups:create_group(?UID1, ?GROUP_NAME1),
    Gid = Group#group.gid,
    ?assertEqual(undefined, Group#group.description),
    ?assertEqual(ok, mod_groups:set_description(Gid, ?UID1, ?GROUP_DESCRIPTION1)),
    {ok, GroupNew} = mod_groups:get_group(Gid, ?UID1),
    ?assertEqual(?GROUP_DESCRIPTION1, GroupNew#group.description),
    ?assertEqual(ok, mod_groups:set_description(Gid, ?UID1, ?GROUP_DESCRIPTION2)),
    {ok, GroupNew2} = mod_groups:get_group(Gid, ?UID1),
    ?assertEqual(?GROUP_DESCRIPTION2, GroupNew2#group.description),
    ok.

set_avatar_test() ->
    setup(),
    {ok, Group} = mod_groups:create_group(?UID1, ?GROUP_NAME1),
    Gid = Group#group.gid,
    ?assertEqual(undefined, Group#group.avatar),
    ?assertEqual({ok, ?AVATAR1, ?GROUP_NAME1}, mod_groups:set_avatar(Gid, ?UID1, ?AVATAR1)),
    {ok, GroupNew} = mod_groups:get_group(Gid, ?UID1),
    ?assertEqual(?AVATAR1, GroupNew#group.avatar),
    ok.

delete_avatar_test() ->
    setup(),
    meck:new(mod_user_avatar),
    meck:expect(mod_user_avatar, delete_avatar_s3, fun(_Id) -> ok end),
    {ok, Group} = mod_groups:create_group(?UID1, ?GROUP_NAME1),
    Gid = Group#group.gid,
    ?assertEqual(undefined, Group#group.avatar),
    ?assertEqual({ok, ?AVATAR1, ?GROUP_NAME1}, mod_groups:set_avatar(Gid, ?UID1, ?AVATAR1)),
    {ok, GroupNew} = mod_groups:get_group(Gid, ?UID1),
    ?assertEqual(?AVATAR1, GroupNew#group.avatar),
    ?assertEqual({ok, ?GROUP_NAME1}, mod_groups:delete_avatar(Gid, ?UID1)),
    {ok, GroupNew2} = mod_groups:get_group(Gid, ?UID1),
    ?assertEqual(undefined, GroupNew2#group.avatar),
    meck:unload(mod_user_avatar),
    ok.

set_background_test() ->
    setup(),
    {ok, Group} = mod_groups:create_group(?UID1, ?GROUP_NAME1),
    Gid = Group#group.gid,
    ?assertEqual(undefined, Group#group.background),
    ?assertEqual({ok, ?BACKGROUND1}, mod_groups:set_background(Gid, ?UID1, ?BACKGROUND1)),
    {ok, GroupNew} = mod_groups:get_group(Gid, ?UID1),
    ?assertEqual(?BACKGROUND1, GroupNew#group.background),
    ?assertEqual({ok, undefined}, mod_groups:set_background(Gid, ?UID1, undefined)),
    {ok, GroupNew2} = mod_groups:get_group(Gid, ?UID1),
    ?assertEqual(undefined, GroupNew2#group.background),
    ok.


modify_members_test() ->
    setup(),
    {ok, Group} = mod_groups:create_group(?UID1, ?GROUP_NAME1),
    Gid = Group#group.gid,
    ?assertEqual({ok, []}, mod_groups:modify_members(Gid, ?UID1, [])),
    ?assertEqual(
        {ok, [{?UID2, add, ok}, {?UID3, add, ok}]},
        mod_groups:modify_members(Gid, ?UID1, [{?UID2, add}, {?UID3, add}])),
    ?assertEqual(
        {ok, [{?UID3, remove, ok}, {?UID4, add, ok}, {?UID5, add, no_account}]},
        mod_groups:modify_members(Gid, ?UID1, [{?UID4, add}, {?UID3, remove}, {?UID5, add}])),
    ?assertEqual(lists:sort([?UID1, ?UID2, ?UID4]), lists:sort(model_groups:get_member_uids(Gid))),
    ok.

send_chat_message_test() ->
    setup(),
    {ok, Group, _Res} = mod_groups:create_group(?UID1, ?GROUP_NAME1, [?UID2, ?UID3]),
    Gid = Group#group.gid,
    {ok, _Ts} = mod_groups:send_chat_message(?MSG_ID1, Gid, ?UID1, <<"TestMessage">>),
    ok.

send_retract_message_test() ->
    setup(),
    {ok, Group, _Res} = mod_groups:create_group(?UID1, ?GROUP_NAME1, [?UID2, ?UID3]),
    Gid = Group#group.gid,
    GroupChatRetractSt = #groupchat_retract_st{id = <<"id1">>, gid = Gid},
    {ok, _Ts} = mod_groups:send_retract_message(?MSG_ID1, Gid, ?UID1, GroupChatRetractSt),
    ok.

cleanup_empty_groups_test() ->
    setup(),
    {ok, Group} = mod_groups:create_group(?UID1, ?GROUP_NAME1),
    Gid = Group#group.gid,
    ?assertEqual(true, model_groups:group_exists(Gid)),
    ?assertEqual({ok, true}, mod_groups:leave_group(Gid, ?UID1)),
    ?assertEqual(false, model_groups:group_exists(Gid)),
    ok.

admin_leave_test() ->
    setup(),
    {ok, Group, _Res} = mod_groups:create_group(?UID1, ?GROUP_NAME1, [?UID2, ?UID3]),
    Gid = Group#group.gid,
    mod_groups:leave_group(Gid, ?UID1),
    IsUid2Admin = model_groups:is_admin(Gid, ?UID2),
    IsUid3Admin = model_groups:is_admin(Gid, ?UID3),
    % make sure at least one of 2 or 3 is now admin.
    ?assertEqual(true, IsUid2Admin or IsUid3Admin),

    {ok, Group2} = mod_groups:get_group(Gid, ?UID2),
    Members = Group2#group.members,
    ?assertEqual(2, length(Members)),
    Admins = lists:filter(fun (M) -> M#group_member.type =:= admin end, Members),
    % check that there is only one admin
    ?assertEqual(1, length(Admins)),
    ok.


get_all_group_members_test() ->
    setup(),
    ?assertEqual(sets:new(), mod_groups:get_all_group_members(?UID1)),
    {ok, _, _} = mod_groups:create_group(?UID1, ?GROUP_NAME1, [?UID2, ?UID3]),
    {ok, _, _} = mod_groups:create_group(?UID1, ?GROUP_NAME2, [?UID2, ?UID4]),
    ?assertEqual(sets:from_list([?UID2, ?UID3, ?UID4]), mod_groups:get_all_group_members(?UID1)),
    ok.

web_preview_invite_link_test() ->
    setup(),
    {ok, Group, _} = mod_groups:create_group(?UID1, ?GROUP_NAME1, [?UID2, ?UID3]),
    Gid = Group#group.gid,
    {ok, Link} = mod_groups:get_invite_link(Gid, ?UID1),
    ?assertEqual(
        {ok, ?GROUP_NAME1, null},
        mod_groups:web_preview_invite_link(Link)),
    ok.


max_group_count_test() ->
    setup(),
    MockedFunction = fun(Uids) ->
        Values = lists:map(fun(Uid) -> case Uid of ?UID1 -> 1000; _ -> 1 end end, Uids),
        maps:from_list(lists:zip(Uids, Values))
    end,
    tutil:meck_init(model_groups, get_group_counts, MockedFunction),
    % create empty group
    {error, max_group_count} = mod_groups:create_group(?UID1, ?GROUP_NAME1),
    % create group with members
    {ok, Group, GroupResults} = mod_groups:create_group(?UID2, ?GROUP_NAME1, [?UID1, ?UID3]),
    ?assertEqual(GroupResults, [{?UID1, add, max_group_count}, {?UID3, add, ok}]),
    Gid = Group#group.gid,
    % join invite link
    {ok, Link} = mod_groups:get_invite_link(Gid, ?UID2),
    {error, max_group_count} = mod_groups:join_with_invite_link(?UID1, Link),
    % add member
    {ok, GroupResults2} = mod_groups:add_members(Gid, ?UID2, [?UID1, ?UID4]),
    ?assertEqual(GroupResults2, [{?UID1, add, max_group_count}, {?UID4, add, ok}]),
    tutil:meck_finish(model_groups),
    ok.

