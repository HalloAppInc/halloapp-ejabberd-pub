-module(groups_tests).

-compile(export_all).
-include("suite.hrl").
-include("packets.hrl").
-include("account_test_data.hrl").
-include_lib("stdlib/include/assert.hrl").

-define(GROUP_NAME1, <<"gname1">>).

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
        members = [#pb_group_member{
            uid = binary_to_integer(?UID3), action = add
        }]
    },
    % check the  result
    Result = ha_client:send_iq(C1, Id, set, Payload),
    #pb_packet{
        stanza = #pb_iq{
            id = Id,
            type = result,
            payload = #pb_group_stanza{
                gid = Gid,
                members = [
                    #pb_group_member{uid = Uid3, type = member, action = add}
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
                    #pb_group_member{uid = Uid3, action = add, type = member, name = ?NAME3}
                ]
            } = GroupSt
        end,
        [{?UID2, ?PASSWORD2}, {?UID3, ?PASSWORD3}]),
    {save_config, [{gid, Gid}]}.

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

    Id = <<"g_iq_id2">>,
    Payload = #pb_group_stanza{
        gid = Gid,
        action = modify_members,
        members = [#pb_group_member{
            uid = binary_to_integer(?UID3), action = remove
        }]
    },
    % check the  result
    Result = ha_client:send_iq(C1, Id, set, Payload),
    #pb_packet{
        stanza = #pb_iq{
            id = Id,
            type = result,
            payload = #pb_group_stanza{
                gid = Gid,
                members = [
                    #pb_group_member{uid = Uid3, type = member, action = remove}
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
                    #pb_group_member{uid = Uid3, action = remove, type = member, name = ?NAME3}
                ]
            } = GroupSt
        end,
        [{?UID2, ?PASSWORD2}, {?UID3, ?PASSWORD3}]),

    ?assertEqual([?UID1, ?UID2], model_groups:get_member_uids(Gid)),
    {save_config, [{gid, Gid}]}.

promote_admin_test(_Conf) ->
    ok.

demote_admin_test(_Conf) ->
    ok.

get_groups_test(_Conf) ->
    ok.

get_group_test(_Conf) ->
    ok.

set_name_test(_Conf) ->
    ok.

set_group_avatar_test(_Conf) ->
    ok.

not_admin_modify_group_test(_Conf) ->
    ok.

