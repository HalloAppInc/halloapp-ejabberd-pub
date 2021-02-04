-module(groups_tests).

-compile(export_all).
-include("suite.hrl").
-include("packets.hrl").
-include("account_test_data.hrl").

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

create_group_test(_Conf) ->
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
    ct:pal("Group Config ~p", [_Conf]),

    {ok, C2} = ha_client:connect_and_login(?UID2, ?PASSWORD2),
    GroupMsg = ha_client:wait_for(C2,
        fun (P) ->
            case P of
                #pb_packet{stanza = #pb_msg{payload = #pb_group_stanza{}}} -> true;
                _Any -> false
            end
        end),
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

    Conf2 = [{gid, Gid} | _Conf],
    {save_config, Conf2}.

add_members_test(_Conf) ->
    ok.

remove_members_test(_Conf) ->
    ok.

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

