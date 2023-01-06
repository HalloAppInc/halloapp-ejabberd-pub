%%%-------------------------------------------------------------------
%%% @author nikola
%%% @copyright (C) 2020, Halloapp Inc.
%%% @doc
%%%
%%% @end
%%% Created : 09. Apr 2020 1:32 PM
%%%-------------------------------------------------------------------
-module(model_accounts_tests).
-author("nikola").

-include("account.hrl").
-include("feed.hrl").
-include("ha_types.hrl").
-include("util_redis.hrl").
-include("tutil.hrl").

%% ----------------------------------------------
%% Test data
%% ----------------------------------------------

-define(UID1, <<"1">>).
-define(PHONE1, <<"16505551111">>).
-define(NAME1, <<"Name1">>).
-define(USER_AGENT1, <<"HalloApp/Android1.0">>).
-define(TS1, 1500000000001).
-define(CAMPAIGN_ID, <<"cmpn">>).
-define(AS1, available).
-define(AVATAR_ID1, <<"CwlRWoG4TduL93Zyrz30Uw">>).
-define(CLIENT_VERSION1, <<"HalloApp/Android0.65">>).
-define(CLIENT_VERSION2, <<"HalloApp/Android0.72">>).
-define(DEVICE, <<"Device">>).
-define(OS_VERSION1, <<"1.0">>).
-define(OS_VERSION2, <<"2.0">>).
-define(PUSH_TOKEN_OS1, <<"android">>).
-define(PUSH_TOKEN1, <<"eXh2yYFZShGXzpobZEc5kg">>).
-define(PUSH_TOKEN_TIMESTAMP1, 1589300000082).
-define(PUSH_LANG_ID1, <<"en-US">>).
-define(PUSH_INFO1, #push_info{uid = ?UID1, os = ?PUSH_TOKEN_OS1,
        token = ?PUSH_TOKEN1, timestamp_ms = ?PUSH_TOKEN_TIMESTAMP1,
        post_pref = true, comment_pref = true, lang_id = ?PUSH_LANG_ID1}).

-define(VOIP_PUSH_INFO1, #push_info{uid = ?UID1,
        voip_token = ?PUSH_TOKEN1, timestamp_ms = ?PUSH_TOKEN_TIMESTAMP1,
        post_pref = true, comment_pref = true, lang_id = ?PUSH_LANG_ID1}).

-define(UID2, <<"2">>).
-define(PHONE2, <<"16505552222">>).
-define(NAME2, <<"Name2">>).
-define(USER_AGENT2, <<"HalloApp/iPhone1.0">>).
-define(TS2, 1500000000002).
-define(AVATAR_ID2, <<>>).
-define(PUSH_TOKEN_OS2, <<"ios">>).
-define(PUSH_TOKEN2, <<"pu7YCnjPQpa4yHm0gJRJ1g">>).
-define(PUSH_TOKEN_TIMESTAMP2, 1570300000148).
-define(PUSH_LANG_ID2, <<"es-AR">>).
-define(ZONE_OFFSET2, 100).
-define(PUSH_INFO2, #push_info{uid = ?UID2, os = ?PUSH_TOKEN_OS2,
        token = ?PUSH_TOKEN2, timestamp_ms = ?PUSH_TOKEN_TIMESTAMP2,
        post_pref = true, comment_pref = true, lang_id = ?PUSH_LANG_ID2,
        zone_offset = 100}).

-define(UID3, <<"3">>).
-define(PHONE3, <<"16505553333">>).
-define(NAME3, <<"Name3">>).
-define(AVATAR_ID3, <<"VXGOypdbEeu4UhZ50Wyckw">>).
-define(USER_AGENT3, <<"HalloApp/Android1.0">>).

-define(UID4, <<"4">>).
-define(PHONE4, <<"16505554444">>).
-define(NAME4, <<"Name4">>).
-define(USER_AGENT4, <<"HalloApp/Android1.0">>).

-define(UID5, <<"5">>).
-define(PHONE5, <<"16505555555">>).
-define(NAME5, <<"Name5">>).
-define(USER_AGENT5, <<"HalloApp/Android1.0">>).

-define(IDENTITY_KEY1, <<"3eF5_JpDEeqYWQoOKynmRg">>).
-define(SIGNED_KEY1, <<"5PTKZJpDEeqkKQoOKynmRg">>).
-define(OTP1_KEY1, <<"6z2ZgppDEeqyowoOKynmRg">>).
-define(OTP1_KEY2, <<"7pahRppDEeqxzgoOKynmRg">>).
-define(OTP1_KEY3, <<"8ZsIRppDEeqm-AoOKynmRg">>).
-define(OTP1_KEY4, <<"9RyKYppDEeq6ugoOKynmRg">>).
-define(OTP1_KEY5, <<"-EOkWppDEeq-DwoOKynmRg">>).

-define(IDENTITY_KEY2, <<"4Z8hNJpDEeqk_goOKynmRg">>).
-define(SIGNED_KEY2, <<"6BO9zJpDEeq9qQoOKynmRg">>).
-define(OTP2_KEY1, <<"-zqNQJpDEeqGRwoOKynmRg">>).
-define(OTP2_KEY2, <<"_sSNsppDEeq7_goOKynmRg">>).
-define(OTP2_KEY3, <<"Aa0OZJpEEeqKfgoOKynmRg">>).

-define(IDENTITY_KEY3, <<"5Z8hNJpDEeqk_goOKynmRg">>).
-define(SIGNED_KEY3, <<>>).
-define(OTP3_KEY1, <<"-zqNQJpDEeqGRwoOKynmRg">>).
-define(OTP3_KEY2, <<"_sSNsppDEeq7_goOKynmRg">>).
-define(OTP3_KEY3, <<"Aa0OZJpEEeqKfgoOKynmRg">>).

-define(MARKETING_TAG1, <<"tag1">>).
-define(MARKETING_TAG2, <<"tag2">>).

-define(PSA_TAG1, <<"ptag1">>).
-define(PSA_TAG2, <<"ptag2">>).

-define(POSTID1, <<"post1">>).

-define(ZONE_OFFSET1, -28800).
-define(ZONE_OFFSET3, 28800).

-define(USERNAME1, <<"username1">>).
-define(USERNAME2, <<"usernaem1">>).
-define(USERNAME3, <<"nusernaem1">>).
-define(USERNAMEPFIX1, <<"use">>).
-define(USERNAMEPFIX2, <<"userna">>).
-define(USERNAMEPFIX3, <<"username1">>).
-define(USERNAMEPFIX4, <<"usernaem1">>).
%% ----------------------------------------------
%% Key Tests
%% ----------------------------------------------

account_key(_) ->
    [?_assertEqual(<<"acc:{1}">>, model_accounts:account_key(?UID1))].

deleted_account_key(_) ->
    [?_assertEqual(<<"dac:{1}">>, model_accounts:deleted_account_key(?UID1))].

subscribe_key(_) ->
    [?_assertEqual(<<"sub:{1}">>, model_accounts:subscribe_key(?UID1))].

broadcast_key(_) ->
    [?_assertEqual(<<"bro:{1}">>, model_accounts:broadcast_key(?UID1))].

count_registrations_key(_) ->
    [?_assertEqual(<<"c_reg:{1}.9842">>, model_accounts:count_registrations_key(?UID1))].

count_accounts_key(_) ->
    [?_assertEqual(<<"c_acc:{1}.9842">>, model_accounts:count_accounts_key(?UID1))].

version_key(_) ->
    [?_assertEqual(<<"v:{1}">>, model_accounts:version_key(1))].

os_version_key(_) ->
    [?_assertEqual(<<"osv:{1}">>, model_accounts:os_version_key(1, ?HALLOAPP))].

lang_key(_) ->
    [?_assertEqual(<<"l:{1}">>, model_accounts:lang_key(1, ?HALLOAPP))].

key_test_() ->
    tutil:setup_once(fun setup/0, fun tutil:cleanup/1, [
        fun account_key/1,
        fun deleted_account_key/1,
        fun subscribe_key/1,
        fun broadcast_key/1,
        fun count_registrations_key/1,
        fun count_accounts_key/1,
        fun version_key/1,
        fun os_version_key/1,
        fun lang_key/1
    ], inparallel).

%% ----------------------------------------------
%% API Tests
%% ----------------------------------------------

create_account(_) ->
    [?_assertNot(model_accounts:account_exists(?UID1)),
    ?_assertNot(model_accounts:is_account_deleted(?UID1)),
    ?_assertOk(model_accounts:create_account(?UID1, ?PHONE1, ?USER_AGENT1, ?CAMPAIGN_ID, ?TS1)),
    ?_assertOk(model_accounts:set_name(?UID1, ?NAME1)),
    ?_assertEqual({error, exists},
        model_accounts:create_account(?UID1, ?PHONE1, ?USER_AGENT1, ?CAMPAIGN_ID, ?TS1)),
    ?_assert(model_accounts:account_exists(?UID1)),
    ?_assertNot(model_accounts:is_account_deleted(?UID1)),
    ?_assertEqual({ok, ?PHONE1}, model_accounts:get_phone(?UID1)),
    ?_assertEqual({ok, ?NAME1}, model_accounts:get_name(?UID1)),
    ?_assertEqual({ok, ?USER_AGENT1}, model_accounts:get_signup_user_agent(?UID1)),
    ?_assertEqual({ok, ?TS1}, model_accounts:get_creation_ts_ms(?UID1))].


delete_account(_) ->
    [?_assertOk(model_accounts:create_account(?UID1, ?PHONE1, ?USER_AGENT1, ?CAMPAIGN_ID, ?TS1)),
    ?_assertOk(model_accounts:set_name(?UID1, ?NAME1)),
    ?_assert(model_accounts:account_exists(?UID1)),
    ?_assertNot(model_accounts:is_account_deleted(?UID1)),
    ?_assertOk(model_accounts:delete_account(?UID1)),
    ?_assertNot(model_accounts:account_exists(?UID1)),
    ?_assert(model_accounts:is_account_deleted(?UID1)),
    ?_assertEqual({error, deleted},
        model_accounts:create_account(?UID1, ?PHONE1, ?USER_AGENT1)),
    ?_assertEqual({error, missing}, model_accounts:get_signup_user_agent(?UID1))].


get_account(_) ->
    ok = model_accounts:create_account(?UID1, ?PHONE1, ?USER_AGENT1, ?CAMPAIGN_ID, ?TS1),
    ok = model_accounts:set_name(?UID1, ?NAME1),
    {ok, Account} = model_accounts:get_account(?UID1),
    Test1 = [?_assertEqual(?PHONE1, Account#account.phone),
    ?_assertEqual(?NAME1, Account#account.name),
    ?_assertEqual(?USER_AGENT1, Account#account.signup_user_agent),
    ?_assertEqual(?CAMPAIGN_ID, Account#account.campaign_id),
    ?_assertEqual(?TS1, Account#account.creation_ts_ms),
    ?_assertEqual(?TS1, Account#account.last_registration_ts_ms),
    ?_assertEqual(undefined, Account#account.last_activity_ts_ms),
    ?_assertEqual(undefined, Account#account.activity_status),
    ?_assertEqual(undefined, Account#account.client_version),
    ?_assertEqual(undefined, Account#account.lang_id),
    ?_assertEqual(undefined, Account#account.device),
    ?_assertEqual(undefined, Account#account.os_version),
    ?_assertEqual("undefined", Account#account.last_ipaddress),
    ?_assertEqual(undefined, Account#account.avatar_id)],
    ok = model_accounts:set_avatar_id(?UID1, ?AVATAR_ID1),
    {ok, Account1} = model_accounts:get_account(?UID1),
    Test1 ++ [?_assertEqual(?AVATAR_ID1, Account1#account.avatar_id)].


get_deleted_account(_) ->
    ok = model_accounts:create_account(?UID1, ?PHONE1, ?USER_AGENT1, ?CAMPAIGN_ID, ?TS1),
    ok = model_accounts:set_name(?UID1, ?NAME1),
    ok = model_accounts:delete_account(?UID1),
    {DeletionTsMs, Account} = model_accounts:get_deleted_account(?UID1),
    [?_assert(util:now_ms() >= DeletionTsMs andalso DeletionTsMs >= util:now_ms() - 250),
    ?_assertEqual(undefined, Account#account.phone),
    ?_assertEqual(undefined, Account#account.name),
    ?_assertEqual(?USER_AGENT1, Account#account.signup_user_agent),
    ?_assertEqual(?CAMPAIGN_ID, Account#account.campaign_id),
    ?_assertEqual(?TS1, Account#account.creation_ts_ms),
    ?_assertEqual(?TS1, Account#account.last_registration_ts_ms),
    ?_assertEqual(undefined, Account#account.last_activity_ts_ms),
    ?_assertEqual(<<"undefined">>, Account#account.activity_status),
    ?_assertEqual(<<"undefined">>, Account#account.client_version),
    ?_assertEqual(<<"undefined">>, Account#account.device),
    ?_assertEqual(<<"undefined">>, Account#account.os_version)].


get_signup_user_agent(_) ->
    [?_assertEqual({ok, ?USER_AGENT1}, model_accounts:get_signup_user_agent(?UID1)),
    ?_assertOk(model_accounts:set_user_agent(?UID1, ?USER_AGENT2)),
    ?_assertEqual({ok, ?USER_AGENT2}, model_accounts:get_signup_user_agent(?UID1))].


get_last_registration_ts_ms(_) ->
    {ok, Timestamp1} = model_accounts:get_creation_ts_ms(?UID1),
    Timestamp2 = 2,
    [?_assertEqual({ok, Timestamp1}, model_accounts:get_last_registration_ts_ms(?UID1)),
    ?_assertNotEqual(undefined, Timestamp1),
    ?_assertOk(model_accounts:set_last_registration_ts_ms(?UID1, Timestamp2)),
    ?_assertEqual({ok, Timestamp2}, model_accounts:get_last_registration_ts_ms(?UID1))].


get_set_client_version(_) ->
    [?_assertEqual(0, maps:get(?CLIENT_VERSION1, model_accounts:count_version_keys(), 0)),
    ?_assertEqual(0, maps:get(?CLIENT_VERSION2, model_accounts:count_version_keys(), 0)),
    ?_assertEqual({error, missing}, model_accounts:get_client_version(?UID2)),
    ?_assertOk(model_accounts:set_client_version(?UID2, ?CLIENT_VERSION2)),
    ?_assertEqual({ok, ?CLIENT_VERSION2}, model_accounts:get_client_version(?UID2)),
    ?_assertOk(model_accounts:set_client_version(?UID1, ?CLIENT_VERSION1)),
    ?_assertEqual(1, maps:get(?CLIENT_VERSION1, model_accounts:count_version_keys(), 0)),
    ?_assertEqual(1, maps:get(?CLIENT_VERSION2, model_accounts:count_version_keys(), 0)),
    ?_assertOk(model_accounts:set_client_version(?UID1, ?CLIENT_VERSION2)),
    ?_assertEqual(0, maps:get(?CLIENT_VERSION1, model_accounts:count_version_keys(), 0)),
    ?_assertEqual(2, maps:get(?CLIENT_VERSION2, model_accounts:count_version_keys(), 0))].


get_set_device_info(_) ->
    ok = model_accounts:set_device_info(?UID1, ?DEVICE, ?OS_VERSION1),
    [?_assertEqual(1, maps:get(?OS_VERSION1, model_accounts:count_os_version_keys(?HALLOAPP), 0)),
    ?_assertEqual(0, maps:get(?OS_VERSION2, model_accounts:count_os_version_keys(?HALLOAPP), 0)),
    ?_assertOk(model_accounts:set_device_info(?UID1, ?DEVICE, ?OS_VERSION2)),
    ?_assertEqual(0, maps:get(?OS_VERSION1, model_accounts:count_os_version_keys(?HALLOAPP), 0)),
    ?_assertEqual(1, maps:get(?OS_VERSION2, model_accounts:count_os_version_keys(?HALLOAPP), 0)),
    ?_assertOk(model_accounts:set_device_info(?UID2, ?DEVICE, ?OS_VERSION1)),
    ?_assertEqual(1, maps:get(?OS_VERSION1, model_accounts:count_os_version_keys(?HALLOAPP), 0)),
    ?_assertEqual(1, maps:get(?OS_VERSION2, model_accounts:count_os_version_keys(?HALLOAPP), 0))].

set_client_info_test() ->
    setup(),
    ok = model_accounts:set_client_info(?UID1, ?CLIENT_VERSION1, ?DEVICE, ?OS_VERSION1),
    OsVersionCount1 = model_accounts:count_os_version_keys(?HALLOAPP),
    ClientVersionCount1 = model_accounts:count_version_keys(),
    ?assertEqual(1, maps:get(?OS_VERSION1, OsVersionCount1, 0)),
    ?assertEqual(0, maps:get(?OS_VERSION2, OsVersionCount1, 0)),
    ?assertEqual(1, maps:get(?CLIENT_VERSION1, ClientVersionCount1, 0)),
    ?assertEqual(0, maps:get(?CLIENT_VERSION2, ClientVersionCount1, 0)),
    ok = model_accounts:set_client_info(?UID1, ?CLIENT_VERSION2, ?DEVICE, ?OS_VERSION2),
    OsVersionCount2 = model_accounts:count_os_version_keys(?HALLOAPP),
    ClientVersionCount2 = model_accounts:count_version_keys(),
    ?assertEqual(0, maps:get(?OS_VERSION1, OsVersionCount2, 0)),
    ?assertEqual(1, maps:get(?OS_VERSION2, OsVersionCount2, 0)),
    ?assertEqual(0, maps:get(?CLIENT_VERSION1, ClientVersionCount2, 0)),
    ?assertEqual(1, maps:get(?CLIENT_VERSION2, ClientVersionCount2, 0)),
    ok = model_accounts:set_client_info(?UID2, ?CLIENT_VERSION2, ?DEVICE, ?OS_VERSION1),
    OsVersionCount3 = model_accounts:count_os_version_keys(?HALLOAPP),
    ClientVersionCount3 = model_accounts:count_version_keys(),
    ?assertEqual(1, maps:get(?OS_VERSION1, OsVersionCount3, 0)),
    ?assertEqual(1, maps:get(?OS_VERSION2, OsVersionCount3, 0)),
    ?assertEqual(0, maps:get(?CLIENT_VERSION1, ClientVersionCount3, 0)),
    ?assertEqual(2, maps:get(?CLIENT_VERSION2, ClientVersionCount3, 0)).


get_set_name(_) ->
    Name = <<"John">>,
    ok = model_accounts:set_name(?UID1, Name),
    [?_assertEqual({ok, Name}, model_accounts:get_name(?UID1)),
    ?_assertEqual({ok, undefined}, model_accounts:get_name(?UID2))].


get_set_avatar_id(_) ->
    [?_assertEqual({ok, undefined}, model_accounts:get_avatar_id(?UID1)),
    ?_assertOk(model_accounts:set_avatar_id(?UID1, ?AVATAR_ID1)),
    ?_assertEqual({ok, ?AVATAR_ID1}, model_accounts:get_avatar_id(?UID1)),
    ?_assertEqual(?AVATAR_ID1, model_accounts:get_avatar_id_binary(?UID1)),

    ?_assertEqual(<<>>, model_accounts:get_avatar_id_binary(?UID2)),
    ?_assertOk(model_accounts:set_avatar_id(?UID2, ?AVATAR_ID2)),
    ?_assertEqual({ok, ?AVATAR_ID2}, model_accounts:get_avatar_id(?UID2)),
    ?_assertEqual(?AVATAR_ID2, model_accounts:get_avatar_id_binary(?UID2))].


get_phone(_) ->
    [?_assertEqual({ok, ?PHONE1}, model_accounts:get_phone(?UID1)),
    ?_assertEqual({error, missing}, model_accounts:get_phone(?UID3))].


get_user_agent(_) ->
    [?_assertEqual({ok, ?USER_AGENT1}, model_accounts:get_signup_user_agent(?UID1)),
    ?_assertEqual({error, missing}, model_accounts:get_signup_user_agent(?UID3))].


last_activity(_) ->
    LastActivitySet = 5,
    LastActivitySet2 = 21,
    [?_assertEqual({ok, #activity{uid = ?UID1, last_activity_ts_ms = undefined, status = undefined}},
        model_accounts:get_last_activity(?UID1)),
    ?_assertOk(model_accounts:set_last_activity(?UID1, LastActivitySet, ?AS1)),
    ?_assertEqual({ok, #activity{uid = ?UID1, last_activity_ts_ms = LastActivitySet, status = ?AS1}},
        model_accounts:get_last_activity(?UID1)),
    ?_assertEqual(#{}, model_accounts:get_last_activity_ts_ms([])),
    ?_assertEqual(#{}, model_accounts:get_last_activity_ts_ms([?UID2, ?UID3])),
    ?_assertEqual(LastActivitySet, maps:get(?UID1, model_accounts:get_last_activity_ts_ms([?UID1]), undefined)),
    ?_assertEqual(undefined, maps:get(?UID2, model_accounts:get_last_activity_ts_ms([?UID1]), undefined)),
    ?_assertOk(model_accounts:set_last_activity(?UID2, LastActivitySet2, ?AS1)),
    ?_assertEqual(LastActivitySet, maps:get(?UID1, model_accounts:get_last_activity_ts_ms([?UID1, ?UID2]), undefined)),
    ?_assertEqual(LastActivitySet2, maps:get(?UID2, model_accounts:get_last_activity_ts_ms([?UID1, ?UID2]), undefined))].


last_ipaddress(_) ->
    [?_assertEqual(undefined, model_accounts:get_last_ipaddress(?UID1)),
    ?_assertOk(model_accounts:set_last_ip_and_connection_time(?UID1, <<"73.223.182.178">>, util:now_ms())),
    ?_assertEqual(<<"73.223.182.178">>, model_accounts:get_last_ipaddress(?UID1))].


sub_unsub_clear_subscriptions(_) ->
    [?_assertOk(model_accounts:presence_subscribe(?UID1, ?UID2)),
    ?_assertEqual({ok, [?UID2]}, model_accounts:get_subscribed_uids(?UID1)),
    ?_assertEqual({ok, [?UID1]}, model_accounts:get_broadcast_uids(?UID2)),
    ?_assertOk(model_accounts:presence_subscribe(?UID1, ?UID3)),
    ?_assertEqual({ok, [?UID2, ?UID3]}, model_accounts:get_subscribed_uids(?UID1)),
    ?_assertEqual({ok, [?UID1]}, model_accounts:get_broadcast_uids(?UID2)),
    ?_assertEqual({ok, [?UID1]}, model_accounts:get_broadcast_uids(?UID3)),
    ?_assertOk(model_accounts:presence_unsubscribe(?UID1, ?UID2)),
    ?_assertEqual({ok, []}, model_accounts:get_broadcast_uids(?UID2)),
    ?_assertEqual({ok, [?UID1]}, model_accounts:get_broadcast_uids(?UID3)),
    ?_assertOk(model_accounts:presence_unsubscribe_all(?UID1)),
    ?_assertEqual({ok, []}, model_accounts:get_subscribed_uids(?UID1)),
    ?_assertEqual({ok, []}, model_accounts:get_broadcast_uids(?UID2)),
    ?_assertEqual({ok, []}, model_accounts:get_broadcast_uids(?UID3))].


voip_and_push_tokens(_) ->
    %% push token
    [?_assertEqual({ok, #push_info{uid = ?UID1, post_pref = true, comment_pref = true}}, model_accounts:get_push_info(?UID1)),
    ?_assertOk(model_accounts:set_push_token(?UID1, ?PUSH_TOKEN_OS1,
            ?PUSH_TOKEN1, ?PUSH_TOKEN_TIMESTAMP1, ?PUSH_LANG_ID1)),
    ?_assertEqual({ok, ?PUSH_INFO1}, model_accounts:get_push_info(?UID1)),
    ?_assertOk(model_accounts:remove_push_info(?UID1)),
    ?_assertEqual({ok, #push_info{uid = ?UID1, post_pref = true, comment_pref = true}}, model_accounts:get_push_info(?UID1)),
    ?_assertEqual({ok, #push_info{uid = ?UID2, post_pref = true, comment_pref = true}}, model_accounts:get_push_info(?UID2)),
    ?_assertOk(model_accounts:set_push_token(?UID2, ?PUSH_TOKEN_OS2,
            ?PUSH_TOKEN2, ?PUSH_TOKEN_TIMESTAMP2, ?PUSH_LANG_ID2, ?ZONE_OFFSET2)),
    ?_assertEqual({ok, ?PUSH_INFO2}, model_accounts:get_push_info(?UID2)),
    ?_assertEqual(?ZONE_OFFSET2, model_accounts:get_zone_offset(?UID2)),
    %% voip token
    ?_assertOk(model_accounts:remove_push_info(?UID1)),
    ?_assertEqual({ok, #push_info{uid = ?UID1, post_pref = true, comment_pref = true}}, model_accounts:get_push_info(?UID1)),
    ?_assertOk(model_accounts:set_voip_token(?UID1,
        ?PUSH_TOKEN1, ?PUSH_TOKEN_TIMESTAMP1, ?PUSH_LANG_ID1, undefined)),
    ?_assertEqual({ok, ?VOIP_PUSH_INFO1}, model_accounts:get_push_info(?UID1))].


lang_id_count(_) ->
    [?_assertEqual(0, maps:get(?PUSH_LANG_ID1, model_accounts:count_lang_keys(?HALLOAPP), 0)),
    ?_assertEqual(0, maps:get(?PUSH_LANG_ID2, model_accounts:count_lang_keys(?HALLOAPP), 0)),
    ?_assertOk(model_accounts:set_push_token(?UID1, ?PUSH_TOKEN_OS1,
            ?PUSH_TOKEN1, ?PUSH_TOKEN_TIMESTAMP1, ?PUSH_LANG_ID1)),
    ?_assertEqual(1, maps:get(?PUSH_LANG_ID1, model_accounts:count_lang_keys(?HALLOAPP), 0)),
    ?_assertEqual(0, maps:get(?PUSH_LANG_ID2, model_accounts:count_lang_keys(?HALLOAPP), 0)),
    ?_assertOk(model_accounts:set_push_token(?UID2, ?PUSH_TOKEN_OS2,
            ?PUSH_TOKEN2, ?PUSH_TOKEN_TIMESTAMP2, ?PUSH_LANG_ID1)),
    ?_assertEqual(2, maps:get(?PUSH_LANG_ID1, model_accounts:count_lang_keys(?HALLOAPP), 0)),
    ?_assertEqual(0, maps:get(?PUSH_LANG_ID2, model_accounts:count_lang_keys(?HALLOAPP), 0)),
    ?_assertOk(model_accounts:set_push_token(?UID2, ?PUSH_TOKEN_OS2,
            ?PUSH_TOKEN2, ?PUSH_TOKEN_TIMESTAMP2, ?PUSH_LANG_ID2)),
    ?_assertEqual(1, maps:get(?PUSH_LANG_ID1, model_accounts:count_lang_keys(?HALLOAPP), 0)),
    ?_assertEqual(1, maps:get(?PUSH_LANG_ID2, model_accounts:count_lang_keys(?HALLOAPP), 0))].


push_post(_) ->
    [?_assertEqual({ok, true}, model_accounts:get_push_post_pref(?UID1)),
    ?_assertOk(model_accounts:set_push_post_pref(?UID1, false)),
    ?_assertEqual({ok, false}, model_accounts:get_push_post_pref(?UID1)),
    ?_assertOk(model_accounts:remove_push_post_pref(?UID1)),
    ?_assertEqual({ok, true}, model_accounts:get_push_post_pref(?UID1))].


push_comment(_) ->
    [?_assertEqual({ok, true}, model_accounts:get_push_comment_pref(?UID1)),
    ?_assertOk(model_accounts:set_push_comment_pref(?UID1, true)),
    ?_assertEqual({ok, true}, model_accounts:get_push_comment_pref(?UID1)),
    ?_assertOk(model_accounts:remove_push_comment_pref(?UID1)),
    ?_assertEqual({ok, true}, model_accounts:get_push_comment_pref(?UID1))].


count(_) ->
    Uid1 = tutil:generate_uid(?HALLOAPP),
    Slot = crc16_redis:hash(binary_to_list(Uid1)),
    [?_assertEqual(#{?HALLOAPP => 0, ?KATCHUP => 0}, model_accounts:count_accounts()),
    ?_assertEqual(#{?HALLOAPP => 0, ?KATCHUP => 0}, model_accounts:count_registrations()),
    ?_assertOk(model_accounts:create_account(Uid1, ?PHONE1, ?USER_AGENT1, ?CAMPAIGN_ID, ?TS1)),
    ?_assertOk(model_accounts:set_name(?UID1, ?NAME1)),
    ?_assertEqual(1, model_accounts:count_accounts(Slot, ?HALLOAPP)),
    ?_assertEqual(1, model_accounts:count_registrations(Slot, ?HALLOAPP)),
    ?_assertEqual(0, model_accounts:count_accounts(Slot, ?KATCHUP)),
    ?_assertEqual(0, model_accounts:count_registrations(Slot, ?KATCHUP)),
    ?_assertEqual(#{?HALLOAPP => 1, ?KATCHUP => 0}, model_accounts:count_registrations()),
    ?_assertEqual(#{?HALLOAPP => 1, ?KATCHUP => 0}, model_accounts:count_accounts()),
    ?_assertOk(model_accounts:create_account(tutil:generate_uid(?HALLOAPP), ?PHONE2, ?USER_AGENT1, ?CAMPAIGN_ID, ?TS1)),
    ?_assertOk(model_accounts:set_name(?UID2, ?NAME1)),
    ?_assertOk(model_accounts:create_account(tutil:generate_uid(?HALLOAPP), ?PHONE3, ?USER_AGENT1, ?CAMPAIGN_ID, ?TS1)),
    ?_assertOk(model_accounts:set_name(?UID3, ?NAME1)),
    ?_assertOk(model_accounts:create_account(tutil:generate_uid(?KATCHUP), ?PHONE4, ?USER_AGENT1, ?CAMPAIGN_ID, ?TS1)),
    ?_assertOk(model_accounts:set_name(?UID4, ?NAME1)),
    ?_assertEqual(#{?HALLOAPP => 3, ?KATCHUP => 1}, model_accounts:count_accounts()),
    ?_assertEqual(#{?HALLOAPP => 3, ?KATCHUP => 1}, model_accounts:count_registrations()),
    ?_assertOk(model_accounts:delete_account(Uid1)),
    ?_assertEqual(#{?HALLOAPP => 2, ?KATCHUP => 1}, model_accounts:count_accounts()),
    ?_assertEqual(#{?HALLOAPP => 3, ?KATCHUP => 1}, model_accounts:count_registrations())].


traced_uids(_) ->
    [?_assertNot(model_accounts:is_uid_traced(?UID1)),
    ?_assertEqual({ok, []}, model_accounts:get_traced_uids()),
    ?_assertOk(model_accounts:add_uid_to_trace(?UID1)),
    ?_assert(model_accounts:is_uid_traced(?UID1)),
    ?_assertEqual({ok, [?UID1]}, model_accounts:get_traced_uids()),
    ?_assertNot(model_accounts:is_uid_traced(?UID2)),
    ?_assertOk(model_accounts:add_uid_to_trace(?UID2)),
    ?_assertEqual({ok, [?UID1, ?UID2]}, model_accounts:get_traced_uids()),
    ?_assertOk(model_accounts:remove_uid_from_trace(?UID2)),
    ?_assertOk(model_accounts:remove_uid_from_trace(?UID1)),
    ?_assertNot(model_accounts:is_uid_traced(?UID1)),
    ?_assertEqual({ok, []}, model_accounts:get_traced_uids())].


traced_phones(_) ->
    [?_assertNot(model_accounts:is_phone_traced(?PHONE1)),
    ?_assertEqual({ok, []}, model_accounts:get_traced_phones()),
    ?_assertOk(model_accounts:add_phone_to_trace(?PHONE1)),
    ?_assert(model_accounts:is_phone_traced(?PHONE1)),
    ?_assertEqual({ok, [?PHONE1]}, model_accounts:get_traced_phones()),
    ?_assertNot(model_accounts:is_phone_traced(?PHONE2)),
    ?_assertOk(model_accounts:add_phone_to_trace(?PHONE2)),
    ?_assertOk(model_accounts:add_phone_to_trace(?PHONE2)),  % should have no effect
    ?_assertEqual({ok, [?PHONE1, ?PHONE2]}, model_accounts:get_traced_phones()),
    ?_assertOk(model_accounts:remove_phone_from_trace(?PHONE2)),
    ?_assertOk(model_accounts:remove_phone_from_trace(?PHONE1)),
    ?_assertNot(model_accounts:is_phone_traced(?PHONE1)),
    ?_assertNot(model_accounts:is_phone_traced(?PHONE2)),
    ?_assertEqual({ok, []}, model_accounts:get_traced_phones())].


get_names(_) ->
    ResMap = #{?UID1 => ?NAME1, ?UID2 => ?NAME2},
    [?_assertEqual(#{}, model_accounts:get_names([])),
    ?_assertEqual(ResMap, model_accounts:get_names([?UID1, ?UID2])),
    ?_assertEqual(ResMap, model_accounts:get_names([?UID1, ?UID2, ?UID3]))].


get_avatar_ids(_) ->
    ResMap = #{?UID1 => ?AVATAR_ID1, ?UID2 => ?AVATAR_ID2},
    [?_assertEqual(#{}, model_accounts:get_avatar_ids([])),
    ?_assertOk(model_accounts:set_avatar_id(?UID1, ?AVATAR_ID1)),
    ?_assertOk(model_accounts:set_avatar_id(?UID2, ?AVATAR_ID2)),
    ?_assertEqual(ResMap, model_accounts:get_avatar_ids([?UID1, ?UID2])),
    ?_assertEqual(ResMap, model_accounts:get_avatar_ids([?UID1, ?UID2, ?UID3]))].


check_account_exists(_) ->
    [?_assertNot(model_accounts:account_exists(?UID1)),
    ?_assertOk(model_accounts:create_account(?UID1, ?PHONE1, ?USER_AGENT1, ?CAMPAIGN_ID, ?TS1)),
    ?_assertOk(model_accounts:set_name(?UID1, ?NAME1)),
    ?_assert(model_accounts:account_exists(?UID1))].


accounts_exist(_) ->
    [?_assertEqual([{?UID1, true}, {?UID3, false}, {?UID2, true}], model_accounts:accounts_exist([?UID1, ?UID3, ?UID2]))].


filter_nonexisting_uids(_) ->
    [?_assertEqual([?UID1, ?UID2], model_accounts:filter_nonexisting_uids([?UID1, ?UID3, ?UID2]))].


check_uid_to_delete(_) ->
    AllToDelete = fun() ->
        lists:foldl(
            fun(Slot, Acc) ->
                {ok, Uids} = model_accounts:get_uids_to_delete(Slot),
                Acc ++ Uids
            end,
            [],
            lists:seq(0, ?NUM_SLOTS - 1))
        end,
    [?_assertOk(model_accounts:create_account(?UID1, ?PHONE1, ?USER_AGENT1, ?CAMPAIGN_ID, ?TS1)),
    ?_assertOk(model_accounts:set_name(?UID1, ?NAME1)),
    ?_assertOk(model_accounts:create_account(?UID2, ?PHONE2, ?USER_AGENT2, ?CAMPAIGN_ID, ?TS2)),
    ?_assertOk(model_accounts:set_name(?UID2, ?NAME2)),
    ?_assertOk(model_accounts:create_account(?UID3, ?PHONE3, ?USER_AGENT3, ?CAMPAIGN_ID, ?TS1)),
    ?_assertOk(model_accounts:set_name(?UID3, ?NAME3)),
    ?_assertOk(model_accounts:create_account(?UID4, ?PHONE4, ?USER_AGENT4, ?CAMPAIGN_ID, ?TS2)),
    ?_assertOk(model_accounts:set_name(?UID4, ?NAME4)),
    ?_assertOk(model_accounts:create_account(?UID5, ?PHONE5, ?USER_AGENT5, ?CAMPAIGN_ID, ?TS1)),
    ?_assertOk(model_accounts:set_name(?UID5, ?NAME5)),
    ?_assertEqual(0, model_accounts:count_uids_to_delete()),
    ?_assertOk(model_accounts:add_uid_to_delete(?UID1)),
    ?_assertEqual(1, model_accounts:count_uids_to_delete()),
    ?_assertOk(model_accounts:add_uid_to_delete(?UID2)),
    ?_assertEqual(2, model_accounts:count_uids_to_delete()),
    ?_assertOk(model_accounts:cleanup_uids_to_delete_keys()),
    ?_assertEqual(0, model_accounts:count_uids_to_delete()),
    ?_assertOk(model_accounts:add_uid_to_delete(?UID1)),
    ?_assertOk(model_accounts:add_uid_to_delete(?UID2)),
    ?_assertOk(model_accounts:add_uid_to_delete(?UID3)),
    ?_assertOk(model_accounts:add_uid_to_delete(?UID4)),
    ?_assertOk(model_accounts:add_uid_to_delete(?UID5)),
    ?_assertEqual(5, model_accounts:count_uids_to_delete()),
    ?_assertEqual(sets:from_list(AllToDelete()), sets:from_list([?UID1, ?UID2, ?UID3, ?UID4, ?UID5])),
    %% TODO(vipin): uncomment the redis scan test.
    %% redis_migrate:start_migration("Check whisper keys", ecredis_accounts, find_inactive_accounts,
    %%        [{dry_run, false}, {execute, sequential}]),
    %% Just so the above async range scan finish, we will wait for 1 second.
    %% timer:sleep(timer:seconds(1)),
    %% ?assertEqual(0, model_accounts:count_uids_to_delete()),
    ?_assert(model_accounts:mark_inactive_uids_gen_start()),
    ?_assert(model_accounts:mark_inactive_uids_deletion_start()),
    ?_assert(model_accounts:mark_inactive_uids_check_start()),
    ?_assertNot(model_accounts:mark_inactive_uids_gen_start()),
    ?_assertNot(model_accounts:mark_inactive_uids_deletion_start()),
    ?_assertNot(model_accounts:mark_inactive_uids_check_start())].


start_get_export(_) ->
    ExportId = util:random_str(20),
    [?_assert(
        fun() ->
            {ok, Ts} = model_accounts:start_export(?UID1, ExportId),
            {ok, Ts, ExportId, TTL} = model_accounts:get_export(?UID1),
            "integer" =:= util:type(TTL)
        end()),
    ?_assertEqual({error, already_started}, model_accounts:start_export(?UID1, ExportId))].


marketing_tag(_) ->
    [?_assertEqual({ok, []}, model_accounts:get_marketing_tags(?UID1)),
    ?_assertOk(model_accounts:add_marketing_tag(?UID1, ?MARKETING_TAG1)),
    ?_assertMatch({ok, [{?MARKETING_TAG1, _}]}, model_accounts:get_marketing_tags(?UID1)),
    ?_assertOk(model_accounts:add_marketing_tag(?UID1, ?MARKETING_TAG2)),
    ?_assertMatch({ok, [{?MARKETING_TAG2, _}, {?MARKETING_TAG1, _}]},
        model_accounts:get_marketing_tags(?UID1))].


psa_tag_test(_) ->
    UidsList = fun() ->
        lists:foldl(
            fun(Slot, Acc) ->
                {ok, List} = model_accounts:get_psa_tagged_uids(Slot, ?PSA_TAG1),
                Acc ++ List
            end,
            [],
            lists:seq(0, ?NUM_SLOTS -1))
    end,
    [?_assertEqual(0, model_accounts:count_psa_tagged_uids(?PSA_TAG1)),
    lists:map(fun(Slot) ->
        ?_assertEqual({ok, []}, model_accounts:get_psa_tagged_uids(Slot, ?PSA_TAG1))
    end, lists:seq(0, ?NUM_SLOTS -1)),
    ?_assertOk(model_accounts:add_uid_to_psa_tag(?UID1, ?PSA_TAG1)),
    ?_assertOk(model_accounts:add_uid_to_psa_tag(?UID2, ?PSA_TAG1)),
    ?_assertEqual(2, model_accounts:count_psa_tagged_uids(?PSA_TAG1)),
    ?_assertEqual(sets:from_list([?UID1, ?UID2]), sets:from_list(UidsList())),
    ?_assertOk(model_accounts:cleanup_psa_tagged_uids(?PSA_TAG1)),
    ?_assertEqual(0, model_accounts:count_psa_tagged_uids(?PSA_TAG1)),
    lists:map(fun(Slot) ->
        ?_assertEqual({ok, []}, model_accounts:get_psa_tagged_uids(Slot, ?PSA_TAG1))
    end, lists:seq(0, ?NUM_SLOTS -1)),
    ?_assert(model_accounts:mark_psa_post_sent(?UID1, ?POSTID1)),
    ?_assertNot(model_accounts:mark_psa_post_sent(?UID1, ?POSTID1))].

moment_notification_test(_) ->
    [?_assert(model_accounts:mark_moment_notification_sent(?UID1, ?POSTID1)),
    ?_assertNot(model_accounts:mark_moment_notification_sent(?UID1, ?POSTID1))].

rejected_suggestions_test(_) ->
    [?_assertOk(model_accounts:add_rejected_suggestions(?UID1, [?UID2])),
    ?_assertEqual({ok, [?UID2]}, model_accounts:get_all_rejected_suggestions(?UID1))].

username_test(_) ->
    ExpectedRes1 = [
        #pb_basic_user_profile{uid = ?UID2, username = ?USERNAME2, name = ?NAME2, avatar_id = ?AVATAR_ID2},
        #pb_basic_user_profile{uid = ?UID1, username = ?USERNAME1, name = ?NAME1, avatar_id = ?AVATAR_ID1}
    ],
    ExpectedRes2 = [
        #pb_basic_user_profile{uid = ?UID1, username = ?USERNAME1, name = ?NAME1, avatar_id = ?AVATAR_ID1}
    ],
    [?_assertEqual({false, tooshort}, mod_username:is_valid_username(<<"ab">>)),
    ?_assertEqual({false, badexpr}, mod_username:is_valid_username(<<"1ab">>)),
    ?_assertEqual({false, badexpr}, mod_username:is_valid_username(<<"Abc">>)),
    ?_assertEqual({false, badexpr}, mod_username:is_valid_username(<<"aAbc">>)),
    ?_assert(model_accounts:is_username_available(?USERNAME1)),
    ?_assert(model_accounts:set_username(?UID1, ?USERNAME1)),
    ?_assertEqual({false, notuniq}, model_accounts:set_username(?UID1, ?USERNAME1)),
    ?_assertNot(model_accounts:is_username_available(?USERNAME1)),
    ?_assertEqual({ok, ?USERNAME1}, model_accounts:get_username(?UID1)),
    ?_assertEqual({ok, ?UID1}, model_accounts:get_username_uid(?USERNAME1)),
    ?_assertEqual(#{?USERNAME1 => ?UID1}, model_accounts:get_username_uids([?USERNAME1])),
    ?_assert(model_accounts:set_username(?UID1, ?USERNAME2)),
    ?_assertEqual({ok, ?USERNAME2}, model_accounts:get_username(?UID1)),
    ?_assertEqual({ok, undefined}, model_accounts:get_username_uid(?USERNAME1)),
    ?_assertEqual(#{}, model_accounts:get_username_uids([?USERNAME1])),
    ?_assert(model_accounts:is_username_available(?USERNAME1)),
    ?_assertNot(model_accounts:is_username_available(?USERNAME2)),
    ?_assert(model_accounts:set_username(?UID1, ?USERNAME1)),
    ?_assert(model_accounts:set_username(?UID2, ?USERNAME2)),
    ?_assertEqual({ok, [?USERNAME2, ?USERNAME1]}, model_accounts:search_username_prefix(?USERNAMEPFIX1, 10)),
    ?_assertEqual({ok, [?USERNAME2, ?USERNAME1]}, model_accounts:search_username_prefix(?USERNAMEPFIX2, 10)),
    ?_assertEqual({ok, [?USERNAME1]}, model_accounts:search_username_prefix(?USERNAMEPFIX3, 10)),
    ?_assertEqual({ok, [?USERNAME2]}, model_accounts:search_username_prefix(?USERNAMEPFIX4, 10)),
    ?_assert(model_accounts:set_username(?UID1, ?USERNAME3)),
    ?_assertEqual({ok, [?USERNAME2]}, model_accounts:search_username_prefix(?USERNAMEPFIX1, 10)),
    ?_assertEqual({ok, [?USERNAME2]}, model_accounts:search_username_prefix(?USERNAMEPFIX2, 10)),
    ?_assertEqual({ok, []}, model_accounts:search_username_prefix(?USERNAMEPFIX3, 10)),
    ?_assertEqual({ok, [?USERNAME2]}, model_accounts:search_username_prefix(?USERNAMEPFIX4, 10)),
    ?_assertOk(model_accounts:create_account(?UID1, ?PHONE1, ?USER_AGENT1, ?CAMPAIGN_ID, ?TS1)),
    ?_assertOk(model_accounts:set_name(?UID1, ?NAME1)),
    ?_assertOk(model_accounts:create_account(?UID2, ?PHONE2, ?USER_AGENT2, ?CAMPAIGN_ID, ?TS2)),
    ?_assertOk(model_accounts:set_name(?UID2, ?NAME2)),
    ?_assert(model_accounts:set_username(?UID1, ?USERNAME1)),
    ?_assertOk(model_accounts:set_avatar_id(?UID1, ?AVATAR_ID1)),
    ?_assertOk(model_accounts:set_avatar_id(?UID2, ?AVATAR_ID2)),
    ?_assertEqual(ExpectedRes1, mod_search:search_username_prefix(?USERNAMEPFIX1, ?UID3)),
    ?_assertOk(model_follow:block(?UID2, ?UID3)),
    ?_assertEqual(ExpectedRes2, mod_search:search_username_prefix(?USERNAMEPFIX1, ?UID3))
    ].


geo_tag_test(_) ->
    TagToExpire = 'GEO0',
    ExpiredTime = util:now() - ?GEO_TAG_EXPIRATION,
    Tag1 = 'GEO1',
    Time1 = util:to_binary(util:now()),
    Tag2 = 'GEO2',
    Time2 = util:to_binary(util:now() + 1),
    [?_assertEqual([], model_accounts:get_all_geo_tags(?UID1)),
    ?_assertEqual(undefined, model_accounts:get_latest_geo_tag(?UID1)),
    ?_assertOk(model_accounts:add_geo_tag(?UID1, TagToExpire, ExpiredTime)),
    ?_assertOk(model_accounts:add_geo_tag(?UID1, Tag1, Time1)),
    ?_assertOk(model_accounts:add_geo_tag(?UID1, Tag2, Time2)),
    ?_assertEqual([{util:to_binary(Tag2), Time2}, {util:to_binary(Tag1), Time1}], model_accounts:get_all_geo_tags(?UID1)),
    ?_assertEqual(Tag2, model_accounts:get_latest_geo_tag(?UID1))].

%% TODO: this test will start failing whent PST(GMT-8) becomes PDT(GMT-7).
zone_offset_tag_test(_) ->
    [?_assertEqual({ok, []},
        model_accounts:get_zone_offset_tag_uids(?ZONE_OFFSET1)),
    ?_assertOk(model_accounts:update_zone_offset_tag(
        ?UID1, ?ZONE_OFFSET1, undefined)),
    ?_assertOk(model_accounts:update_zone_offset_tag(
        ?UID1, ?ZONE_OFFSET1, undefined)),
    ?_assertEqual({ok, [?UID1]},
        model_accounts:get_zone_offset_tag_uids(?ZONE_OFFSET1)),
    ?_assertOk(model_accounts:update_zone_offset_tag(
        ?UID1, ?ZONE_OFFSET1, ?ZONE_OFFSET1)),
    ?_assertEqual({ok, [?UID1]},
        model_accounts:get_zone_offset_tag_uids(?ZONE_OFFSET1)),
    ?_assertOk(model_accounts:delete_zone_offset_tag(
        ?UID1, ?ZONE_OFFSET1)),
    ?_assertEqual({ok, []},
        model_accounts:get_zone_offset_tag_uids(?ZONE_OFFSET1)),
    ?_assertEqual({ok, []},
        model_accounts:get_zone_offset_tag_uids(?ZONE_OFFSET3)),
    ?_assertOk(model_accounts:update_zone_offset_tag(?UID1, ?ZONE_OFFSET1, undefined)),
    ?_assertOk(model_accounts:update_zone_offset_tag(?UID1, ?ZONE_OFFSET3, ?ZONE_OFFSET1)),
    ?_assertEqual({ok, []},
                  model_accounts:get_zone_offset_tag_uids(?ZONE_OFFSET1)),
    ?_assertEqual({ok, [?UID1]},
                   model_accounts:get_zone_offset_tag_uids(?ZONE_OFFSET3)),
    ?_assertOk(model_accounts:del_zone_offset(?ZONE_OFFSET3)),
    ?_assertEqual({ok, []},
                   model_accounts:get_zone_offset_tag_uids(?ZONE_OFFSET3))].

set_get_bio_test(_) ->
    Bio = <<"test bio">>,
    [
        ?_assertEqual(undefined, model_accounts:get_bio(?UID1)),
        ?_assertOk(model_accounts:set_bio(?UID1, Bio)),
        ?_assertEqual(Bio, model_accounts:get_bio(?UID1))
    ].

set_get_links_test(_) ->
    Links = #{snapchat => "snap_name", user_defined => "https://localhost/test"},
    [
        ?_assertEqual(#{}, model_accounts:get_links(?UID1)),
        ?_assertOk(model_accounts:set_links(?UID1, Links)),
        ?_assertEqual(Links, model_accounts:get_links(?UID1))
    ].

user_profile_test(_) ->
    Username = <<"test_username">>,
    AvatarId = <<"avID">>,
    Bio = <<"my bio">>,
    LinkMap = #{snapchat => <<"snap_name">>, user_defined => <<"https://localhost/test">>},
    Links = [
        #pb_link{type = snapchat, text = <<"snap_name">>},
        #pb_link{type = user_defined, text = <<"https://localhost/test">>}
    ],
    ExpectedResult = #pb_user_profile{
        uid = ?UID1,
        username = Username,
        name = ?NAME1,
        avatar_id = AvatarId,
        follower_status = none,
        following_status = none,
        num_mutual_following = 0,
        bio = Bio,
        links = sets:from_list(Links)
    },
    LinkListToSet = fun
        (#pb_user_profile{links = LinkList} = UserProfile) ->
            UserProfile#pb_user_profile{links = sets:from_list(LinkList)}
    end,
    [
        ?_assertOk(model_accounts:create_account(?UID1, ?PHONE1, ?USER_AGENT1)),
        ?_assertOk(model_accounts:set_name(?UID1, ?NAME1)),
        ?_assert(model_accounts:set_username(?UID1, Username)),
        ?_assertOk(model_accounts:set_avatar_id(?UID1, AvatarId)),
        ?_assertOk(model_accounts:set_bio(?UID1, Bio)),
        ?_assertOk(model_accounts:set_links(?UID1, LinkMap)),
        ?_assertMatch(ExpectedResult, LinkListToSet(model_accounts:get_user_profiles(?UID2, ?UID1)))
    ].

api_test_() ->
    [tutil:setup_foreach(fun setup/0, [
        fun create_account/1,
        fun get_account/1,
        fun delete_account/1,
        fun get_deleted_account/1,
        fun get_set_name/1,
        fun lang_id_count/1,
        fun count/1,
        fun check_account_exists/1,
        fun check_uid_to_delete/1,
        fun voip_and_push_tokens/1,
        fun username_test/1,
        fun user_profile_test/1
    ]),
    tutil:in_parallel(fun setup_accounts/0, fun tutil:cleanup/1, [
        fun get_signup_user_agent/1,
        fun get_last_registration_ts_ms/1,
        fun get_set_client_version/1,
        fun get_set_device_info/1,
        fun get_set_avatar_id/1,
        fun get_phone/1,
        fun get_user_agent/1,
        fun last_activity/1,
        fun last_ipaddress/1,
        fun sub_unsub_clear_subscriptions/1,
        fun push_post/1,
        fun push_comment/1,
        fun traced_phones/1,
        fun traced_uids/1,
        fun get_names/1,
        fun get_avatar_ids/1,
        fun accounts_exist/1,
        fun filter_nonexisting_uids/1,
        fun start_get_export/1,
        fun marketing_tag/1,
        fun psa_tag_test/1,
        fun moment_notification_test/1,
        fun rejected_suggestions_test/1,
        fun geo_tag_test/1,
        fun zone_offset_tag_test/1,
        fun set_get_bio_test/1,
        fun set_get_links_test/1
    ])].


setup() ->
    phone_number_util:init(undefined, undefined),
    tutil:setup([
        {redis, [redis_accounts]}
    ]).


setup_accounts() ->
    CleanupInfo = setup(),
    model_accounts:create_account(?UID1, ?PHONE1, ?USER_AGENT1, ?CAMPAIGN_ID, ?TS1),
    model_accounts:set_name(?UID1, ?NAME1),
    model_accounts:create_account(?UID2, ?PHONE2, ?USER_AGENT2, ?CAMPAIGN_ID, ?TS2),
    model_accounts:set_name(?UID2, ?NAME2),
    CleanupInfo.

