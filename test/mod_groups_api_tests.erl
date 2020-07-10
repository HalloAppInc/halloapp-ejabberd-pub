%%%-------------------------------------------------------------------
%%% File: model_phone_tests.erl
%%% Copyright (C) 2020, Halloapp Inc.
%%%
%%%-------------------------------------------------------------------
-module(mod_groups_api_tests).
-author("nikola").

-include("xmpp.hrl").
-include("groups.hrl").

-include_lib("eunit/include/eunit.hrl").

% TODO: move this data into header file to share across the group tests
-define(GROUP_NAME1, <<"Test Group 1">>).
-define(GROUP_NAME2, <<"Test Group 2">>).
-define(GROUP_NAME3, <<"Test Group 3">>).
-define(UID1, <<"1">>).
-define(UID2, <<"2">>).
-define(UID3, <<"3">>).
-define(UID4, <<"4">>).
-define(UID5, <<"5">>).
-define(PHONE1, <<"12065550001">>).
-define(PHONE2, <<"12065550002">>).
-define(PHONE3, <<"12065550003">>).
-define(PHONE4, <<"12065550004">>).
-define(NAME1, <<"Name1">>).
-define(NAME2, <<"Name2">>).
-define(NAME3, <<"Name3">>).
-define(NAME4, <<"Name4">>).
-define(UA, <<"HalloApp/Android1.0">>).


setup() ->
    stringprep:start(),
    gen_iq_handler:start(ejabberd_local),
    ejabberd_hooks:start_link(),
    mod_redis:start(undefined, []),
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
    ok = gen_server:cast(redis_groups_client, flushdb),
    ok = gen_server:cast(redis_accounts_client, flushdb).


create_group_IQ(Uid, Name) ->
    create_group_IQ(Uid, Name, []).


create_group_IQ(Uid, Name, Uids) ->
    MemberSt = [#member_st{uid = Ouid} || Ouid <- Uids],
    #iq{
        from = #jid{luser = Uid},
        type = set,
        sub_els = [
            #group_st{
                action = create,
                name = Name,
                members = MemberSt
            }
        ]
    }.


delete_group_IQ(Uid, Gid) ->
    make_group_IQ(Uid, Gid, set, delete, []).


modify_members_IQ(Uid, Gid, Changes) ->
    make_group_IQ(Uid, Gid, set, modify_members, Changes).


modify_admins_IQ(Uid, Gid, Changes) ->
    make_group_IQ(Uid, Gid, set, modify_admins, Changes).


get_group_IQ(Uid, Gid) ->
    make_group_IQ(Uid, Gid, get, get, []).


leave_group_IQ(Uid, Gid) ->
    make_group_IQ(Uid, Gid, set, leave, []).


set_name_IQ(Uid, Gid, Name) ->
    #iq{
        from = #jid{luser = Uid},
        type = set,
        sub_els = [
            #group_st{
                gid = Gid,
                action = set_name,
                name = Name
            }
        ]
    }.


make_group_IQ(Uid, Gid, Type, Action, Changes) ->
    MemberSt = [#member_st{uid = Ouid, action = MAction} || {Ouid, MAction} <- Changes],
    #iq{
        from = #jid{luser = Uid},
        type = Type,
        sub_els = [
            #group_st{
                gid = Gid,
                action = Action,
                members = MemberSt
            }
        ]
    }.


get_groups_IQ(Uid) ->
    #iq{
        from = #jid{luser = Uid},
        type = get,
        sub_els = [
            #groups{action = get}
        ]
    }.


get_result_iq_sub_el(#iq{} = IQ) ->
    ?assertEqual(result, IQ#iq.type),
    [Res] = IQ#iq.sub_els,
    Res.


get_error_iq_sub_el(#iq{} = IQ) ->
    ?assertEqual(error, IQ#iq.type),
    [Res] = IQ#iq.sub_els,
    Res.


mod_groups_api_test() ->
    setup(),
    Host = <<"s.halloapp.net">>,
    ?assertEqual(ok, mod_groups_api:start(Host, [])),
    ?assertEqual(ok, mod_groups_api:stop(Host)),
    ?assertEqual([{mod_groups, hard}], mod_groups_api:depends(Host, [])),
    ?assertEqual([], mod_groups_api:mod_options(Host)),
    ok.


create_empty_group_test() ->
    setup(),
    IQ = create_group_IQ(?UID1, ?GROUP_NAME1),
    IQRes = mod_groups_api:process_local_iq(IQ),
    GroupSt = get_result_iq_sub_el(IQRes),
    #group_st{
        gid = Gid,
        name = ?GROUP_NAME1,
        members = []
    } = GroupSt,
    ?assertEqual(true, model_groups:group_exists(Gid)),
    ?assertEqual(
        {ok, #group_info{gid = Gid, name = ?GROUP_NAME1}},
        mod_groups:get_group_info(Gid, ?UID1)),
%%    ?debugVal(IQRes),
    ok.


create_group_with_members_test() ->
    setup(),
    IQ = create_group_IQ(?UID1, ?GROUP_NAME1, [?UID2, ?UID3, ?UID5]),
    IQRes = mod_groups_api:process_local_iq(IQ),
    GroupSt = get_result_iq_sub_el(IQRes),
    #group_st{
        gid = _Gid,
        name = ?GROUP_NAME1,
        members = Members
    } = GroupSt,
%%    ?debugVal(Members),
    M2 = #member_st{uid = ?UID2, type = member, result = ok},
    M3 = #member_st{uid = ?UID3, type = member, result = ok},
    M5 = #member_st{uid = ?UID5, type = member, result = failed, reason = no_account},
    ?assertEqual([M2, M3, M5], Members),
    ok.


create_group_with_creator_as_member_test() ->
    setup(),
    IQ = create_group_IQ(?UID1, ?GROUP_NAME1, [?UID1, ?UID2]),
    IQRes = mod_groups_api:process_local_iq(IQ),
    GroupSt = get_result_iq_sub_el(IQRes),
    #group_st{
        gid = _Gid,
        name = ?GROUP_NAME1,
        members = Members
    } = GroupSt,
%%    ?debugVal(Members),
    M1 = #member_st{uid = ?UID1, type = admin, result = ok},
    M2 = #member_st{uid = ?UID2, type = member, result = ok},
    ?assertEqual([M1, M2], Members),
    ok.


delete_group_test() ->
    setup(),
    Gid1 = undefined,
    IQ = delete_group_IQ(?UID1, Gid1),
    IQRes = mod_groups_api:process_local_iq(IQ),
    ExpectedError = xmpp:err_feature_not_implemented(),
%%    ?debugVal(IQRes),
    ?assertMatch(
        #iq{
            type = error,
            sub_els = [ExpectedError]
        },
        IQRes),
    ok.


create_group(Uid, Name, Members) ->
    IQ = create_group_IQ(Uid, Name, Members),
    IQRes = mod_groups_api:process_local_iq(IQ),
    GroupSt = get_result_iq_sub_el(IQRes),
    #group_st{gid = Gid} = GroupSt,
    Gid.


modify_members_test() ->
    setup(),
    Gid = create_group(?UID1, ?GROUP_NAME1, [?UID2, ?UID3]),
%%    ?debugVal(Gid, 1000),
    IQ = modify_members_IQ(?UID1, Gid, [{?UID2, remove}, {?UID4, add}, {?UID5, add}]),
    IQRes = mod_groups_api:process_local_iq(IQ),
    GroupSt = get_result_iq_sub_el(IQRes),
%%    ?debugVal(GroupSt, 1000),
    ?assertMatch(
        #group_st{
            gid = Gid,
            action = modify_members,
            members = [
                #member_st{uid = ?UID2, action = remove, result = ok},
                #member_st{uid = ?UID4, action = add, type = member, result = ok},
                #member_st{uid = ?UID5, action = add, type = member,
                    result = failed, reason = no_account}]
        },
        GroupSt),
    ok.


modify_members_not_admin_test() ->
    setup(),
    Gid = create_group(?UID1, ?GROUP_NAME1, [?UID2, ?UID3]),
%%    ?debugVal(Gid, 1000),
    IQ = modify_members_IQ(?UID2, Gid, [{?UID4, add}, {?UID5, add}]),
    IQRes = mod_groups_api:process_local_iq(IQ),
    Error = get_error_iq_sub_el(IQRes),
%%    ?debugVal(Error, 1000),
    ?assertEqual(#stanza_error{reason = not_admin}, Error),
    ok.


modify_admins_test() ->
    setup(),
    Gid = create_group(?UID1, ?GROUP_NAME1, [?UID2, ?UID3]),
%%    ?debugVal(Gid, 1000),
    IQ = modify_admins_IQ(?UID1, Gid, [{?UID2, promote}, {?UID3, demote}, {?UID5, promote}]),
    IQRes = mod_groups_api:process_local_iq(IQ),
    GroupSt = get_result_iq_sub_el(IQRes),
%%    ?debugVal(GroupSt, 1000),
    ExpectedGroupSt = #group_st{
        gid = Gid,
        action = modify_admins,
        members = [
            #member_st{uid = ?UID3, action = demote, type = member, result = ok},
            #member_st{uid = ?UID2, action = promote, type = admin, result = ok},
            #member_st{uid = ?UID5, action = promote, type = admin,
                result = failed, reason = not_member}]
    },
%%    ?debugVal(ExpectedGroupSt, 1000),
    ?assertEqual(ExpectedGroupSt, GroupSt),
    ok.


modify_admins_not_admin_test() ->
    setup(),
    Gid = create_group(?UID1, ?GROUP_NAME1, [?UID2, ?UID3]),
    IQ = modify_admins_IQ(?UID2, Gid, [{?UID4, promote}, {?UID3, demote}]),
    IQRes = mod_groups_api:process_local_iq(IQ),
    Error = get_error_iq_sub_el(IQRes),
    ?assertEqual(#stanza_error{reason = not_admin}, Error),
    ok.


get_group_test() ->
    setup(),
    Gid = create_group(?UID1, ?GROUP_NAME1, [?UID2, ?UID3]),
%%    ?debugVal(Gid, 1000),
    IQ = get_group_IQ(?UID1, Gid),
    IQRes = mod_groups_api:process_local_iq(IQ),
    GroupSt = get_result_iq_sub_el(IQRes),
%%    ?debugVal(GroupSt, 1000),
    ExpectedGroupSt = #group_st{
        gid = Gid,
        name = ?GROUP_NAME1,
        avatar = undefined,
        members = [
            #member_st{uid = ?UID1, type = admin},
            #member_st{uid = ?UID2, type = member},
            #member_st{uid = ?UID3, type = member}]
    },
%%    ?debugVal(ExpectedGroupSt, 1000),
    ?assertEqual(ExpectedGroupSt, GroupSt),
    ok.


get_group_error_not_member_test() ->
    setup(),
    Gid = create_group(?UID1, ?GROUP_NAME1, [?UID2, ?UID3]),
    IQ = get_group_IQ(?UID4, Gid),
    IQRes = mod_groups_api:process_local_iq(IQ),
    Error = get_error_iq_sub_el(IQRes),
    ?assertEqual(#stanza_error{reason = not_member}, Error),

    IQ2 = get_group_IQ(?UID1, <<"gdasdkjaskd">>),
    IQRes2 = mod_groups_api:process_local_iq(IQ2),
    Error2 = get_error_iq_sub_el(IQRes2),
    ?assertEqual(#stanza_error{reason = not_member}, Error2),
    ok.


get_groups_test() ->
    setup(),
    Gid1 = create_group(?UID1, ?GROUP_NAME1, [?UID2, ?UID3]),
    Gid2 = create_group(?UID2, ?GROUP_NAME2, [?UID1, ?UID4]),
    IQ = get_groups_IQ(?UID1),
    IQRes = mod_groups_api:process_local_iq(IQ),
    GroupsSt = get_result_iq_sub_el(IQRes),
%%    ?debugVal(GroupsSt, 1000),
    GroupsSet = lists:sort(GroupsSt#groups.groups),
    ExpectedGroupsSet = lists:sort([
        % TODO: figure out the default value for this avatar field.
            #group_st{gid = Gid1, name = ?GROUP_NAME1, avatar = undefined},
            #group_st{gid = Gid2, name = ?GROUP_NAME2, avatar = undefined}
    ]),
%%    ?debugVal(ExpectedGroupsSet, 1000),
    ?assertEqual(ExpectedGroupsSet, GroupsSet),
    ok.


set_name_test() ->
    setup(),
    Gid = create_group(?UID1, ?GROUP_NAME1, [?UID2, ?UID3]),
    IQ = set_name_IQ(?UID1, Gid, ?GROUP_NAME3),
    IQRes = mod_groups_api:process_local_iq(IQ),
    GroupSt = get_result_iq_sub_el(IQRes),
%%    ?debugVal(GroupSt, 1000),
    ExpectedGroupSt = #group_st{
        gid = Gid,
        name = ?GROUP_NAME3,
        avatar = undefined
    },
%%    ?debugVal(ExpectedGroupSt, 1000),
    ?assertEqual(ExpectedGroupSt, GroupSt),
    ok.


set_name_error_test() ->
    setup(),
    Gid = create_group(?UID1, ?GROUP_NAME1, []),
    IQ = set_name_IQ(?UID1, Gid, <<>>),
    IQRes = mod_groups_api:process_local_iq(IQ),
    Error = get_error_iq_sub_el(IQRes),
    ?assertEqual(#stanza_error{reason = invalid_name}, Error),

    IQ2 = set_name_IQ(?UID2, Gid, ?GROUP_NAME2),
    IQRes2 = mod_groups_api:process_local_iq(IQ2),
    Error2 = get_error_iq_sub_el(IQRes2),
    ?assertEqual(#stanza_error{reason = not_member}, Error2),
    ok.


leave_group_test() ->
    setup(),
    Gid = create_group(?UID1, ?GROUP_NAME1, [?UID2, ?UID3]),
    IQ = leave_group_IQ(?UID2, Gid),
    IQRes = mod_groups_api:process_local_iq(IQ),
%%    ?debugVal(IQRes, 1000),
    ?assertEqual(result, IQRes#iq.type),
    ?assertEqual([], IQRes#iq.sub_els),
    ok.

