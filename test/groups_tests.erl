-module(groups_tests).

-compile(export_all).
-include("suite.hrl").
-include("packets.hrl").
-include("account_test_data.hrl").
-include_lib("stdlib/include/assert.hrl").

-define(GROUP_NAME1, <<"gname1">>).
-define(GROUP_NAME2, <<"gname2">>).
-define(GROUP_NAME3, <<"gname3">>).
-define(GROUP_NAME1_CHANGED, <<"gname1_changed">>).

group() ->
    {groups, [sequence], [
        groups_dummy_test,
        groups_create_group_test,
        groups_add_members_test,
        groups_remove_members_test,
        groups_promote_admin_test,
        groups_demote_admin_test,
        groups_get_groups_test,
        groups_get_group_test,
        groups_set_name_test,
        groups_set_group_avatar_test,
        groups_not_admin_modify_group_test
    ]}.

dummy_test(_Conf) ->
    ok.

% create group with Uid1 and Uid2, make sure Uid2 gets msg about the group
create_group_test(Conf) ->
    {ok, C1} = ha_client:connect_and_login(?UID1, ?PASSWORD1),
    Uid1 = binary_to_integer(?UID1),
    Uid2 = binary_to_integer(?UID2),
    Id = <<"g_iq_id1">>,
    Payload = #pb_group_stanza{
        action = create,
        name = ?GROUP_NAME1,
        members = [#pb_group_member{
            uid = binary_to_integer(?UID2)
        }]
    },
    % check the create_group result
    Result = ha_client:send_iq(C1, Id, set, Payload),
    #pb_packet{
        stanza = #pb_iq{
            id = Id,
            type = result,
            payload = #pb_group_stanza{
                gid = Gid,
                name = ?GROUP_NAME1,
                avatar_id = undefined, % TODO: was thinking it will be empty str
                members = [
                    % TODO: the spec says we should get back our selves also... but we don't
%%                    #pb_group_member{uid = Uid1, type = admin, name = ?NAME1},
                    % TODO: it looks like we are missing the name of UID2
                    #pb_group_member{uid = Uid2, type = member}
                ]
            }
        }
    } = Result,


    ct:pal("Group Gid ~p", [Gid]),
    ct:pal("Group Config ~p", [Conf]),

    {ok, C2} = ha_client:connect_and_login(?UID2, ?PASSWORD2),
    GroupMsg = ha_client:wait_for_msg(C2, pb_group_stanza),
    GroupSt = GroupMsg#pb_packet.stanza#pb_msg.payload,
    #pb_group_stanza{
        action = create, % TODO: create event is not documented
        gid = Gid,
        name = ?GROUP_NAME1,
        sender_uid = Uid1,
        sender_name = ?NAME1,
        members = [
            #pb_group_member{uid = Uid2, action = add, type = member, name = ?NAME2}
        ]
    } = GroupSt,

    {save_config, [{gid, Gid}]}.


% Uid1 adds Uid2, Uid3 to the group (created above). Uid2 is already a member.
% Make sure Uid2 and Uid3 get msg about the group change.
add_members_test(Conf) ->
    {groups_create_group_test, SConfig} = ?config(saved_config, Conf),
    Gid = ?config(gid, SConfig),
    ?assertEqual([?UID1, ?UID2], model_groups:get_member_uids(Gid)),

    % Uid1 adds Uid3 to the group
    {ok, C1} = ha_client:connect_and_login(?UID1, ?PASSWORD1),
    % TODO: use defines for this
    Uid1 = binary_to_integer(?UID1),
    Uid2 = binary_to_integer(?UID2),
    Uid3 = binary_to_integer(?UID3),

    Id = <<"g_iq_id2">>,
    Payload = #pb_group_stanza{
        gid = Gid,
        action = modify_members,
        members = [
            #pb_group_member{uid = binary_to_integer(?UID2), action = add},
            #pb_group_member{uid = binary_to_integer(?UID3), action = add}
        ]
    },
    % check the  result
    Result = ha_client:send_iq(C1, Id, set, Payload),
    ct:pal("Result ~p", [Result]),
    #pb_packet{
        stanza = #pb_iq{
            id = Id,
            type = result,
            payload = #pb_group_stanza{
                gid = Gid,
                members = [
                    #pb_group_member{uid = Uid2, type = member, action = add,
                        result = <<"failed">>, reason = <<"already_member">>},
                    #pb_group_member{uid = Uid3, type = member, action = add,
                        result = <<"ok">>, reason = undefined}
                ]
            }
        }
    } = Result,

    % make sure Uid2 and Uid3 get message about the group modification
    lists:map(
        fun({User, Password}) ->
            {ok, C2} = ha_client:connect_and_login(User, Password),
            GroupMsg = ha_client:wait_for_msg(C2, pb_group_stanza),
            GroupSt = GroupMsg#pb_packet.stanza#pb_msg.payload,
            #pb_group_stanza{
                action = modify_members,
                gid = Gid,
                name = ?GROUP_NAME1,
                sender_uid = Uid1,
                sender_name = ?NAME1,
                members = [
                    % Because Uid2 was already a member, nothing is broadcasted about him
                    #pb_group_member{uid = Uid3, action = add, type = member, name = ?NAME3}
                ]
            } = GroupSt
        end,
        [{?UID2, ?PASSWORD2}, {?UID3, ?PASSWORD3}]),
    {save_config, [{gid, Gid}]}.

% Uid1 removes Uid3 to the group. Make sure Uid2 and Uid3 get msg about the group change
remove_members_test(Conf) ->
    {groups_add_members_test, SConfig} = ?config(saved_config, Conf),
    Gid = ?config(gid, SConfig),
    ?assertEqual([?UID1, ?UID2, ?UID3], model_groups:get_member_uids(Gid)),

    % Uid1 adds Uid3 to the group
    {ok, C1} = ha_client:connect_and_login(?UID1, ?PASSWORD1),
    % TODO: use defines for this
    Uid1 = binary_to_integer(?UID1),
    Uid2 = binary_to_integer(?UID2),
    Uid3 = binary_to_integer(?UID3),

    Id = <<"g_iq_id3">>,
    Payload = #pb_group_stanza{
        gid = Gid,
        action = modify_members,
        members = [
            #pb_group_member{uid = binary_to_integer(?UID3), action = remove},
            #pb_group_member{uid = binary_to_integer(?UID4), action = remove}
        ]
    },
    % check the  result
    Result = ha_client:send_iq(C1, Id, set, Payload),
    ct:pal("Result ~p", [Result]),
    #pb_packet{
        stanza = #pb_iq{
            id = Id,
            type = result,
            payload = #pb_group_stanza{
                gid = Gid,
                members = [
                    #pb_group_member{uid = Uid3, type = member, action = remove,
                        result = <<"ok">>, reason = undefined},
                    #pb_group_member{uid = Uid4, type = member, action = remove,
                        result = <<"failed">>, reason = <<"already_not_member">>}
                ]
            }
        }
    } = Result,

    % make sure Uid2 and Uid3 get message about the group modification
    lists:map(
        fun({User, Password}) ->
            {ok, C2} = ha_client:connect_and_login(User, Password),
            GroupMsg = ha_client:wait_for_msg(C2, pb_group_stanza),

            GroupSt = GroupMsg#pb_packet.stanza#pb_msg.payload,
            ct:pal("Debug ~p", [GroupSt]),
            #pb_group_stanza{
                action = modify_members,
                gid = Gid,
                name = ?GROUP_NAME1,
                sender_uid = Uid1,
%%                sender_name = ?NAME1,
                members = [
                    #pb_group_member{uid = Uid3, action = remove, type = member, name = ?NAME3,
                        result = undefined, reason = undefined}
                    % Nothing is broadcasted about Uid4
                ]
            } = GroupSt
        end,
        [{?UID2, ?PASSWORD2}, {?UID3, ?PASSWORD3}]),

    ?assertEqual([?UID1, ?UID2], model_groups:get_member_uids(Gid)),
    {save_config, [{gid, Gid}]}.


% Uid1 promotes Uid2 to be admin of the group. Makes sure Uid2 gets msg about the change.
promote_admin_test(Conf) ->
    {groups_remove_members_test, SConfig} = ?config(saved_config, Conf),
    Gid = ?config(gid, SConfig),
    ?assertEqual([?UID1, ?UID2], model_groups:get_member_uids(Gid)),


    {ok, C1} = ha_client:connect_and_login(?UID1, ?PASSWORD1),
    % TODO: use defines for this
    Uid1 = binary_to_integer(?UID1),
    Uid2 = binary_to_integer(?UID2),
    Uid3 = binary_to_integer(?UID3),

    ?assertEqual(false, model_groups:is_admin(Gid, ?UID2)),
    % Uid1 makes Uid2 admin
    Id = <<"g_iq_id4">>,
    Payload = #pb_group_stanza{
        gid = Gid,
        action = modify_admins,
        members = [#pb_group_member{
            uid = binary_to_integer(?UID2), action = promote
        }]
    },

    PromoteResult = ha_client:send_iq(C1, Id, set, Payload),
    % check the result
    ct:pal("Result : ~p", [PromoteResult]),
    #pb_packet{
        stanza = #pb_iq{
            id = Id,
            type = result,
            payload = #pb_group_stanza{
                action = modify_admins,
                gid = Gid,
                avatar_id = undefined,
                members = [
                    #pb_group_member{uid = Uid2, type = admin, action = promote,
                        result = <<"ok">>, reason = undefined}
                ]
            }
        }
    } = PromoteResult,
    ?assertEqual(true, model_groups:is_admin(Gid, ?UID2)),

    {ok, C2} = ha_client:connect_and_login(?UID2, ?PASSWORD2),
    GroupMsg = ha_client:wait_for_msg(C2, pb_group_stanza),
    GroupSt = GroupMsg#pb_packet.stanza#pb_msg.payload,
    ct:pal("GroupSt : ~p", [GroupSt]),
    #pb_group_stanza{
        action = modify_admins,
        gid = Gid,
        name = ?GROUP_NAME1,
        sender_uid = Uid1,
        sender_name = ?NAME1,
        avatar_id = undefined,
        members = [
            #pb_group_member{uid = Uid2, action = promote, type = admin, name = ?NAME2,
                result = undefined, reason = undefined}
        ]
    } = GroupSt,

    {save_config, [{gid, Gid}]}.


% Uid1 demotes Uid2 from being admin of the group. Makes sure Uid2 gets msg about the change.
demote_admin_test(Conf) ->
    {groups_promote_admin_test, SConfig} = ?config(saved_config, Conf),
    Gid = ?config(gid, SConfig),
    ?assertEqual([?UID1, ?UID2], model_groups:get_member_uids(Gid)),


    {ok, C1} = ha_client:connect_and_login(?UID1, ?PASSWORD1),
    % TODO: use defines for this
    Uid1 = binary_to_integer(?UID1),
    Uid2 = binary_to_integer(?UID2),
    Uid3 = binary_to_integer(?UID3),

    ?assertEqual(true, model_groups:is_admin(Gid, ?UID2)),
    % Uid1 demotes Uid2
    Id = <<"g_iq_id5">>,
    Payload = #pb_group_stanza{
        gid = Gid,
        action = modify_admins,
        members = [#pb_group_member{
            uid = binary_to_integer(?UID2), action = demote
        }]
    },

    DemoteResult = ha_client:send_iq(C1, Id, set, Payload),
    % check the result
    ct:pal("Result : ~p", [DemoteResult]),
    #pb_packet{
        stanza = #pb_iq{
            id = Id,
            type = result,
            payload = #pb_group_stanza{
                action = modify_admins,
                gid = Gid,
                avatar_id = undefined,
                members = [
                    #pb_group_member{uid = Uid2, type = member, action = demote,
                        result = <<"ok">>, reason = undefined}
                ]
            }
        }
    } = DemoteResult,
    ?assertEqual(false, model_groups:is_admin(Gid, ?UID2)),

    {ok, C2} = ha_client:connect_and_login(?UID2, ?PASSWORD2),
    GroupMsg = ha_client:wait_for_msg(C2, pb_group_stanza),
    GroupSt = GroupMsg#pb_packet.stanza#pb_msg.payload,
    ct:pal("GroupSt : ~p", [GroupSt]),
    #pb_group_stanza{
        action = modify_admins,
        gid = Gid,
        name = ?GROUP_NAME1,
        sender_uid = Uid1,
        sender_name = ?NAME1,
        avatar_id = undefined,
        members = [
            #pb_group_member{uid = Uid2, action = demote, type = member, name = ?NAME2,
                result = undefined, reason = undefined}
        ]
    } = GroupSt,

    {save_config, [{gid, Gid}]}.


% Uid1 creates a second group with Uid3. Uid1 calls get_groups and makes sure he gets back both groups
get_groups_test(Conf) ->
    {groups_demote_admin_test, SConfig} = ?config(saved_config, Conf),
    Gid = ?config(gid, SConfig),
    ?assertEqual([?UID1, ?UID2], model_groups:get_member_uids(Gid)),

    {ok, C1} = ha_client:connect_and_login(?UID1, ?PASSWORD1),
    % TODO: code is duplicated
    Uid1 = binary_to_integer(?UID1),
    Uid2 = binary_to_integer(?UID2),
    Uid3 = binary_to_integer(?UID3),

    % create second group, this way Uid1 is in 2 groups
    Id = <<"g_iq_id6">>,
    CreateGroup = #pb_group_stanza{
        action = create,
        name = ?GROUP_NAME2,
        members = [#pb_group_member{
            uid = binary_to_integer(?UID3)
        }]
    },
    % check the create_group result
    Result = ha_client:send_iq(C1, Id, set, CreateGroup),
    #pb_packet{
        stanza = #pb_iq{
            id = Id,
            type = result,
            payload = #pb_group_stanza{
                gid = Gid2,
                name = ?GROUP_NAME2,
                members = [
                    #pb_group_member{uid = Uid3, type = member}
                ]
            }
        }
    } = Result,

    % now get the groups Uid1 is in
    GetGroups = #pb_groups_stanza{
        action = get
    },
    Id2 = <<"g_iq_id7">>,
    GroupsResult = ha_client:send_iq(C1, Id2, get, GetGroups),
    #pb_packet{
        stanza = #pb_iq{
            id = Id2,
            type = result,
            payload = #pb_groups_stanza{
                action = get,
                group_stanzas = GroupStanzas
            }
        }
    } = GroupsResult,

    ct:pal("Groups ~p", [GroupStanzas]),
    ?assertEqual(2, length(GroupStanzas)),
    Group1Stanza = lists:keyfind(Gid, 3, GroupStanzas),
    Group2Stanza = lists:keyfind(Gid2, 3, GroupStanzas),

    % TODO: why is the type set :(
    #pb_group_stanza{action = set, gid = Gid, name = ?GROUP_NAME1, members = []} = Group1Stanza,
    #pb_group_stanza{action = set, gid = Gid2, name = ?GROUP_NAME2, members = []} = Group2Stanza,

    {save_config, [{gid, Gid}, {gid2, Gid2}]}.


% Uid1 calls get_group for Group1 and Group2 making sure he get the group names and members.
get_group_test(Conf) ->
    {groups_get_groups_test, SConfig} = ?config(saved_config, Conf),
    Gid = ?config(gid, SConfig),
    Gid2 = ?config(gid2, SConfig),
    ?assertEqual([?UID1, ?UID2], model_groups:get_member_uids(Gid)),
    ?assertEqual([?UID1, ?UID3], model_groups:get_member_uids(Gid2)),

    {ok, C1} = ha_client:connect_and_login(?UID1, ?PASSWORD1),
    % TODO: code is duplicated
    Uid1 = binary_to_integer(?UID1),
    Uid2 = binary_to_integer(?UID2),
    Uid3 = binary_to_integer(?UID3),

    % Get members of group1
    Id = <<"g_iq_id8">>,
    GetGroup1 = #pb_group_stanza{
        action = get,
        gid = Gid
    },

    Group1Result = ha_client:send_iq(C1, Id, get, GetGroup1),
    ct:pal("Group1Result ~p", [Group1Result]),
    % check the result group1
    #pb_packet{
        stanza = #pb_iq{
            id = Id,
            type = result,
            payload = #pb_group_stanza{
                action = set, % TODO: Why set
                gid = Gid,
                name = ?GROUP_NAME1,
                members = [
                    #pb_group_member{uid = Uid1, type = admin, name = ?NAME1},
                    #pb_group_member{uid = Uid2, type = member, name = ?NAME2}
                ]
            }
        }
    } = Group1Result,


    % Get members of group2
    Id2 = <<"g_iq_id9">>,
    GetGroup2 = #pb_group_stanza{
        action = get,
        gid = Gid2
    },

    Group2Result = ha_client:send_iq(C1, Id2, get, GetGroup2),
    ct:pal("Group1Result ~p", [Group2Result]),
    % check the result group2
    #pb_packet{
        stanza = #pb_iq{
            id = Id2,
            type = result,
            payload = #pb_group_stanza{
                action = set, % TODO: Why set
                gid = Gid2,
                name = ?GROUP_NAME2,
                members = [
                    #pb_group_member{uid = Uid1, type = admin, name = ?NAME1},
                    #pb_group_member{uid = Uid3, type = member, name = ?NAME3}
                ]
            }
        }
    } = Group2Result,

    {save_config, [{gid, Gid}, {gid2, Gid2}]}.


% Uid1 sets the name of the group.
set_name_test(Conf) ->
    {groups_get_group_test, SConfig} = ?config(saved_config, Conf),
    Gid = ?config(gid, SConfig),
    Gid2 = ?config(gid2, SConfig),
    ?assertEqual([?UID1, ?UID2], model_groups:get_member_uids(Gid)),
    ?assertEqual([?UID1, ?UID3], model_groups:get_member_uids(Gid2)),


    {ok, C1} = ha_client:connect_and_login(?UID1, ?PASSWORD1),
    % TODO: code is duplicated
    Uid1 = binary_to_integer(?UID1),
    Uid2 = binary_to_integer(?UID2),
    Uid3 = binary_to_integer(?UID3),

    % Get members of group1
    Id = <<"g_iq_id9">>,
    SetName = #pb_group_stanza{
        action = set_name,
        gid = Gid,
        name = ?GROUP_NAME1_CHANGED
    },

    Result = ha_client:send_iq(C1, Id, set, SetName),
    ct:pal("Result ~p", [Result]),
    % check the result group1
    #pb_packet{
        stanza = #pb_iq{
            id = Id,
            type = result,
            payload = #pb_group_stanza{
                action = set, % TODO: Why set
                gid = Gid,
                name = ?GROUP_NAME1_CHANGED,
                members = [
                ]
            }
        }
    } = Result,

    % TODO: check that others get the group name change.

    {save_config, [{gid, Gid}, {gid2, Gid2}]}.

set_group_avatar_test(Conf) ->
    ok.

not_admin_modify_group_test(Conf) ->
    ok.

