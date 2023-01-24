%%%-------------------------------------------------------------------
%%% Copyright (C) 2022, Halloapp Inc.
%%%
%%%-------------------------------------------------------------------
-module(mod_follow_suggestions_tests).
-author("vipin").

-include_lib("eunit/include/eunit.hrl").
-include("account.hrl").
-include("packets.hrl").
-include("ha_types.hrl").

%% ----------------------------------------------
%% Test data
%% ----------------------------------------------

-define(PHONE1, <<"16505551111">>).
-define(NAME1, <<"Name1">>).
-define(USER_AGENT1, <<"HalloApp/Android1.0">>).
-define(TS1, 1500000000001).
-define(CAMPAIGN_ID, <<"cmpn">>).
-define(AVATAR_ID1, <<"CwlRWoG4TduL93Zyrz30Uw">>).

-define(PHONE2, <<"16505552222">>).
-define(NAME2, <<"Name2">>).
-define(USER_AGENT2, <<"HalloApp/iPhone1.0">>).
-define(TS2, 1500000000002).
-define(AVATAR_ID2, <<>>).

-define(PHONE3, <<"16505553333">>).
-define(NAME3, <<"Name3">>).
-define(AVATAR_ID3, <<"VXGOypdbEeu4UhZ50Wyckw">>).
-define(USER_AGENT3, <<"HalloApp/Android1.0">>).

-define(PHONE4, <<"16505554444">>).
-define(NAME4, <<"Name4">>).
-define(USER_AGENT4, <<"HalloApp/Android1.0">>).
-define(AVATAR_ID4, <<"VXGOypdbEeu4UhZ50Wyckw">>).

-define(USERNAME1, <<"username1">>).
-define(USERNAME2, <<"username2">>).
-define(USERNAME3, <<"username3">>).
-define(USERNAME4, <<"username4">>).

setup() ->
    tutil:setup(),
    ha_redis:start(),
    clear(),
    ok.


clear() ->
    tutil:cleardb(redis_accounts).

follow_suggestions_test() ->
    setup(),
    Uid1 = tutil:generate_uid(?KATCHUP),
    Uid2 = tutil:generate_uid(?KATCHUP),
    Uid3 = tutil:generate_uid(?KATCHUP),
    Uid4 = tutil:generate_uid(?KATCHUP),
    ExpectedRes1 = [
        #pb_suggested_profile{user_profile = #pb_basic_user_profile{uid = Uid2, username = ?USERNAME2, name = ?NAME2, avatar_id = ?AVATAR_ID2}, reason = direct_contact, rank = 1},
        #pb_suggested_profile{user_profile = #pb_basic_user_profile{uid = Uid3, username = ?USERNAME3, name = ?NAME3, avatar_id = ?AVATAR_ID3}, reason = direct_contact, rank = 2},
        #pb_suggested_profile{user_profile = #pb_basic_user_profile{uid = Uid4, username = ?USERNAME4, name = ?NAME4, avatar_id = ?AVATAR_ID4}, reason = direct_contact, rank = 3}
    ],
    ExpectedRes2 = [
        #pb_suggested_profile{user_profile = #pb_basic_user_profile{uid = Uid2, username = ?USERNAME2, name = ?NAME2, avatar_id = ?AVATAR_ID2}, reason = direct_contact, rank = 1},
        #pb_suggested_profile{user_profile = #pb_basic_user_profile{uid = Uid4, username = ?USERNAME4, name = ?NAME4, avatar_id = ?AVATAR_ID4}, reason = direct_contact, rank = 2}
    ],
    ok = model_accounts:create_account(Uid1, ?PHONE1, ?USER_AGENT1, ?CAMPAIGN_ID, ?TS1),
    true = model_accounts:set_username(Uid1, ?USERNAME1),
    ok = model_accounts:set_name(Uid1, ?NAME1),
    ok = model_accounts:create_account(Uid2, ?PHONE2, ?USER_AGENT2, ?CAMPAIGN_ID, ?TS2),
    true = model_accounts:set_username(Uid2, ?USERNAME2),
    ok = model_accounts:set_name(Uid2, ?NAME2),
    ok = model_accounts:create_account(Uid3, ?PHONE3, ?USER_AGENT3, ?CAMPAIGN_ID, ?TS1),
    true = model_accounts:set_username(Uid3, ?USERNAME3),
    ok = model_accounts:set_name(Uid3, ?NAME3),
    ok = model_accounts:create_account(Uid4, ?PHONE4, ?USER_AGENT4, ?CAMPAIGN_ID, ?TS2),
    true = model_accounts:set_username(Uid4, ?USERNAME4),
    ok = model_accounts:set_name(Uid4, ?NAME4),
    ok = model_contacts:add_contacts(Uid1, [?PHONE2, ?PHONE3, ?PHONE4]),
    ?assertEqual({ok, [?PHONE2, ?PHONE3, ?PHONE4]}, model_contacts:get_contacts(Uid1)),
    ok = model_phone:add_phone(?PHONE1, ?KATCHUP, Uid1),
    ok = model_phone:add_phone(?PHONE2, ?KATCHUP, Uid2),
    ok = model_phone:add_phone(?PHONE3, ?KATCHUP, Uid3),
    ok = model_phone:add_phone(?PHONE4, ?KATCHUP, Uid4),
    ?assertEqual({ok, Uid1}, model_phone:get_uid(?PHONE1, ?KATCHUP)),
    ?assertEqual({ok, Uid2}, model_phone:get_uid(?PHONE2, ?KATCHUP)),
    ?assertEqual({ok, Uid3}, model_phone:get_uid(?PHONE3, ?KATCHUP)),
    ?assertEqual({ok, Uid4}, model_phone:get_uid(?PHONE4, ?KATCHUP)),
    ?assertEqual([Uid2, Uid3, Uid4],
        maps:values(model_phone:get_uids([?PHONE2, ?PHONE3, ?PHONE4], ?KATCHUP))),
    ok = model_accounts:set_avatar_id(Uid1, ?AVATAR_ID1),
    ok = model_accounts:set_avatar_id(Uid2, ?AVATAR_ID2),
    ok = model_accounts:set_avatar_id(Uid3, ?AVATAR_ID3),
    ok = model_accounts:set_avatar_id(Uid4, ?AVATAR_ID4),
    ?assert(model_accounts:set_username(Uid1, ?USERNAME1)),
    ?assert(model_accounts:set_username(Uid2, ?USERNAME2)),
    ?assert(model_accounts:set_username(Uid3, ?USERNAME3)),
    ?assert(model_accounts:set_username(Uid4, ?USERNAME4)),
    %% Uid2 has 2 followers, Uid3 has 1, Uid4 has 0.
    ok = model_follow:follow(Uid2, Uid3),
    ok = model_follow:follow(Uid2, Uid4),
    ok = model_follow:follow(Uid3, Uid4),
    ?assertEqual(2, model_follow:get_following_count(Uid2)),
    ?assertEqual(1, model_follow:get_following_count(Uid3)),
    ?assertEqual(0, model_follow:get_following_count(Uid4)),
    ok = model_accounts:set_avatar_id(Uid1, ?AVATAR_ID1),
    ok = model_accounts:set_avatar_id(Uid2, ?AVATAR_ID2),
    ?assertEqual(ExpectedRes1, mod_follow_suggestions:generate_follow_suggestions(Uid1)),
    ok = model_follow:block(Uid1, Uid3),
    ?assertEqual(ExpectedRes2, mod_follow_suggestions:generate_follow_suggestions(Uid1)).

