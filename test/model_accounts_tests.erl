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
-include_lib("eunit/include/eunit.hrl").
-include("ha_types.hrl").
-include("util_redis.hrl").

setup() ->
    tutil:setup(),
    ha_redis:start(),
    clear(),
    ok.

clear() ->
  tutil:cleardb(redis_accounts).

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
        post_pref = undefined, comment_pref = undefined, lang_id = ?PUSH_LANG_ID1}).

-define(VOIP_PUSH_INFO1, #push_info{uid = ?UID1,
        voip_token = ?PUSH_TOKEN1, timestamp_ms = ?PUSH_TOKEN_TIMESTAMP1,
        post_pref = undefined, comment_pref = undefined, lang_id = ?PUSH_LANG_ID1}).

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
-define(PUSH_INFO2, #push_info{uid = ?UID2, os = ?PUSH_TOKEN_OS2,
        token = ?PUSH_TOKEN2, timestamp_ms = ?PUSH_TOKEN_TIMESTAMP2,
        post_pref = undefined, comment_pref = undefined, lang_id = ?PUSH_LANG_ID2}).

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


empty_test() ->
    ok.


key_test() ->
    ?assertEqual(<<"acc:{1}">>, model_accounts:account_key(?UID1)).


deleted_account_key_test() ->
    ?assertEqual(<<"dac:{1}">>, model_accounts:deleted_account_key(?UID1)).


subscribe_key_test() ->
    ?assertEqual(<<"sub:{1}">>, model_accounts:subscribe_key(?UID1)).


broadcast_key_test() ->
    ?assertEqual(<<"bro:{1}">>, model_accounts:broadcast_key(?UID1)).


count_registrations_key_test() ->
    setup(),
    ?assertEqual(<<"c_reg:{1}.9842">>, model_accounts:count_registrations_key(?UID1)).


count_accounts_key_test() ->
    setup(),
    ?assertEqual(<<"c_acc:{1}.9842">>, model_accounts:count_accounts_key(?UID1)).

version_key_test() ->
    setup(),
    ?assertEqual(<<"v:{1}">>, model_accounts:version_key(1)).

os_version_key_test() ->
    setup(),
    ?assertEqual(<<"osv:{1}">>, model_accounts:os_version_key(1)).

lang_key_test() ->
    setup(),
    ?assertEqual(<<"l:{1}">>, model_accounts:lang_key(1)).


create_account_test() ->
    setup(),
    false = model_accounts:account_exists(?UID1),
    false = model_accounts:is_account_deleted(?UID1),
    ok = model_accounts:create_account(?UID1, ?PHONE1, ?NAME1, ?USER_AGENT1, ?CAMPAIGN_ID, ?TS1),
    {error, exists} = model_accounts:create_account(?UID1, ?PHONE1, ?NAME1, ?USER_AGENT1, ?CAMPAIGN_ID, ?TS1),
    true = model_accounts:account_exists(?UID1),
    false = model_accounts:is_account_deleted(?UID1),
    ok.


delete_account_test() ->
    setup(),
    ok = model_accounts:create_account(?UID1, ?PHONE1, ?NAME1, ?USER_AGENT1, ?CAMPAIGN_ID, ?TS1),
    ?assertEqual(true, model_accounts:account_exists(?UID1)),
    ?assertEqual(false, model_accounts:is_account_deleted(?UID1)),
    ok = model_accounts:delete_account(?UID1),
    ?assertEqual(false, model_accounts:account_exists(?UID1)),
    ?assertEqual(true, model_accounts:is_account_deleted(?UID1)),
    {error, deleted} = model_accounts:create_account(?UID1, ?PHONE1, ?NAME1, ?USER_AGENT1),
    ?assertEqual({error, missing}, model_accounts:get_signup_user_agent(?UID1)),
    ok.


create_account2_test() ->
    setup(),
    ok = model_accounts:create_account(?UID1, ?PHONE1, ?NAME1, ?USER_AGENT1, ?CAMPAIGN_ID, ?TS1),
    ?assertEqual({ok, ?PHONE1}, model_accounts:get_phone(?UID1)),
    ?assertEqual({ok, ?NAME1}, model_accounts:get_name(?UID1)),
    ?assertEqual({ok, ?USER_AGENT1}, model_accounts:get_signup_user_agent(?UID1)),
    ?assertEqual({ok, ?TS1}, model_accounts:get_creation_ts_ms(?UID1)).


get_account_test() ->
    setup(),
    ok = model_accounts:create_account(?UID1, ?PHONE1, ?NAME1, ?USER_AGENT1, ?CAMPAIGN_ID, ?TS1),
    {ok, Account} = model_accounts:get_account(?UID1),
    ?assertEqual(?PHONE1, Account#account.phone),
    ?assertEqual(?NAME1, Account#account.name),
    ?assertEqual(?USER_AGENT1, Account#account.signup_user_agent),
    ?assertEqual(?CAMPAIGN_ID, Account#account.campaign_id),
    ?assertEqual(?TS1, Account#account.creation_ts_ms),
    ?assertEqual(?TS1, Account#account.last_registration_ts_ms),
    ?assertEqual(undefined, Account#account.last_activity_ts_ms),
    ?assertEqual(undefined, Account#account.activity_status),
    ?assertEqual(undefined, Account#account.client_version),
    ?assertEqual(undefined, Account#account.lang_id),
    ?assertEqual(undefined, Account#account.device),
    ?assertEqual(undefined, Account#account.os_version),
    ?assertEqual("undefined", Account#account.last_ipaddress),
    ?assertEqual(undefined, Account#account.avatar_id),
    ok = model_accounts:set_avatar_id(?UID1, ?AVATAR_ID1),
    {ok, Account1} = model_accounts:get_account(?UID1),
    ?assertEqual(?AVATAR_ID1, Account1#account.avatar_id),
    ok.


get_signup_user_agent_test() ->
    setup(),
    ok = model_accounts:create_account(?UID1, ?PHONE1, ?NAME1, ?USER_AGENT1),
    ?assertEqual({ok, ?USER_AGENT1}, model_accounts:get_signup_user_agent(?UID1)),
    ok = model_accounts:set_user_agent(?UID1, ?USER_AGENT2),
    ?assertEqual({ok, ?USER_AGENT2}, model_accounts:get_signup_user_agent(?UID1)).


get_last_registration_ts_ms_test() ->
    setup(),
    ok = model_accounts:create_account(?UID1, ?PHONE1, ?NAME1, ?USER_AGENT1),
    {ok, Timestamp1} = model_accounts:get_creation_ts_ms(?UID1),
    ?assertEqual({ok, Timestamp1}, model_accounts:get_last_registration_ts_ms(?UID1)),
    ?assertNotEqual(undefined, Timestamp1),
    Timestamp2 = util:now_ms(),
    ok = model_accounts:set_last_registration_ts_ms(?UID1, Timestamp2),
    ?assertEqual({ok, Timestamp2}, model_accounts:get_last_registration_ts_ms(?UID1)).


get_client_version_test() ->
    setup(),
    ok = model_accounts:set_client_version(?UID1, ?CLIENT_VERSION1),
    ?assertEqual({ok, ?CLIENT_VERSION1}, model_accounts:get_client_version(?UID1)),
    ok = model_accounts:set_client_version(?UID1, ?CLIENT_VERSION2),
    ?assertEqual({ok, ?CLIENT_VERSION2}, model_accounts:get_client_version(?UID1)),
    ok.


set_client_version() ->
    setup(),
    VersionCountsMap1 = model_accounts:count_version_keys(),
    ?assertEqual(0, maps:get(?CLIENT_VERSION1, VersionCountsMap1, 0)),
    ?assertEqual(0, maps:get(?CLIENT_VERSION2, VersionCountsMap1, 0)),

    ok = model_accounts:set_client_version(?UID1, ?CLIENT_VERSION1),
    VersionCountsMap2 = model_accounts:count_version_keys(),
    ?assertEqual(1, maps:get(?CLIENT_VERSION1, VersionCountsMap2, 0)),
    ?assertEqual(0, maps:get(?CLIENT_VERSION2, VersionCountsMap2, 0)),

    ok = model_accounts:set_client_version(?UID2, ?CLIENT_VERSION1),
    VersionCountsMap3 = model_accounts:count_version_keys(),
    ?assertEqual(2, maps:get(?CLIENT_VERSION1, VersionCountsMap3, 0)),
    ?assertEqual(0, maps:get(?CLIENT_VERSION2, VersionCountsMap3, 0)),

    ok = model_accounts:set_client_version(?UID1, ?CLIENT_VERSION2),
    VersionCountsMap4 = model_accounts:count_version_keys(),
    ?assertEqual(1, maps:get(?CLIENT_VERSION1, VersionCountsMap4, 0)),
    ?assertEqual(1, maps:get(?CLIENT_VERSION2, VersionCountsMap4, 0)),
    ok.


set_client_version_test() ->
    {timeout, 20,
        fun set_client_version/0}.


get_os_version_test() ->
    setup(),
    ok = model_accounts:set_device_info(?UID1, ?DEVICE, ?OS_VERSION1),
    ?assertEqual({ok, ?OS_VERSION1}, model_accounts:get_os_version(?UID1)),
    ok = model_accounts:set_device_info(?UID1, ?DEVICE, ?OS_VERSION2),
    ?assertEqual({ok, ?OS_VERSION2}, model_accounts:get_os_version(?UID1)),
    ok.


set_device_info_test() ->
    ok = model_accounts:set_device_info(?UID1, ?DEVICE, ?OS_VERSION1),
    VersionCount = model_accounts:count_os_version_keys(),
    ?assertEqual(1, maps:get(?OS_VERSION1, VersionCount, 0)),
    ?assertEqual(0, maps:get(?OS_VERSION2, VersionCount, 0)),
    ok = model_accounts:set_device_info(?UID1, ?DEVICE, ?OS_VERSION2),
    VersionCount2 = model_accounts:count_os_version_keys(),
    ?assertEqual(0, maps:get(?OS_VERSION1, VersionCount2, 0)),
    ?assertEqual(1, maps:get(?OS_VERSION2, VersionCount2, 0)),
    ok = model_accounts:set_device_info(?UID2, ?DEVICE, ?OS_VERSION1),
    VersionCount3 = model_accounts:count_os_version_keys(),
    ?assertEqual(1, maps:get(?OS_VERSION1, VersionCount3, 0)),
    ?assertEqual(1, maps:get(?OS_VERSION2, VersionCount3, 0)),
    ok.


list_to_map_test() ->
    L = ["a", 1, "b", 2],
    M = util:list_to_map(L),
    ?assertEqual(#{"a" => 1,"b" => 2}, M).


get_set_name_test() ->
    setup(),
    ok = model_accounts:set_name(?UID1, <<"John">>),
    {ok, Name} = model_accounts:get_name(?UID1),
    ?assertEqual(<<"John">>, Name).


get_name_missing_test() ->
    setup(),
    {ok, undefined} = model_accounts:get_name(?UID2).


get_set_avatar_id_test() ->
    setup(),
    ?assertEqual({ok, undefined}, model_accounts:get_avatar_id(?UID1)),
    ok = model_accounts:set_avatar_id(?UID1, ?AVATAR_ID1),
    ?assertEqual({ok, ?AVATAR_ID1}, model_accounts:get_avatar_id(?UID1)),
    ?assertEqual(?AVATAR_ID1, model_accounts:get_avatar_id_binary(?UID1)),

    ?assertEqual(<<>>, model_accounts:get_avatar_id_binary(?UID2)),
    ok = model_accounts:set_avatar_id(?UID2, ?AVATAR_ID2),
    ?assertEqual({ok, ?AVATAR_ID2}, model_accounts:get_avatar_id(?UID2)),
    ?assertEqual(?AVATAR_ID2, model_accounts:get_avatar_id_binary(?UID2)).


get_phone_test() ->
    setup(),
    ok = model_accounts:create_account(?UID1, ?PHONE1, ?NAME1, ?USER_AGENT1, ?CAMPAIGN_ID, ?TS1),
    {ok, ?PHONE1} = model_accounts:get_phone(?UID1),
    {error, missing} = model_accounts:get_phone(?UID2).


get_user_agent_test() ->
    setup(),
    ok = model_accounts:create_account(?UID1, ?PHONE1, ?NAME1, ?USER_AGENT1, ?CAMPAIGN_ID, ?TS1),
    {ok, ?USER_AGENT1} = model_accounts:get_signup_user_agent(?UID1),
    {error, missing} = model_accounts:get_signup_user_agent(?UID2).


last_activity_test() ->
    setup(),
    ok = model_accounts:create_account(?UID1, ?PHONE1, ?NAME1, ?USER_AGENT1, ?CAMPAIGN_ID, ?TS1),
    {ok, LastActivity} = model_accounts:get_last_activity(?UID1),
    ?assertEqual(?UID1, LastActivity#activity.uid),
    ?assertEqual(undefined, LastActivity#activity.last_activity_ts_ms),
    ?assertEqual(undefined, LastActivity#activity.status),
    Now = util:now_ms(),
    ok = model_accounts:set_last_activity(?UID1, Now, ?AS1),
    {ok, NewLastActivity} = model_accounts:get_last_activity(?UID1),
    ?assertEqual(?UID1, NewLastActivity#activity.uid),
    ?assertEqual(Now, NewLastActivity#activity.last_activity_ts_ms),
    ?assertEqual(?AS1, NewLastActivity#activity.status),
    #{} = model_accounts:get_last_activity_ts_ms([]),
    #{} = model_accounts:get_last_activity_ts_ms([?UID2, ?UID3]),
    FirstMap = model_accounts:get_last_activity_ts_ms([?UID1]),
    ?assertEqual(Now, maps:get(?UID1, FirstMap, undefined)),
    ?assertEqual(undefined, maps:get(?UID2, FirstMap, undefined)),
    ok = model_accounts:create_account(?UID2, ?PHONE2, ?NAME2, ?USER_AGENT2, ?CAMPAIGN_ID, ?TS2),
    Now2 = util:now_ms(),
    ok = model_accounts:set_last_activity(?UID2, Now2, ?AS1),
    SecondMap = model_accounts:get_last_activity_ts_ms([?UID1, ?UID2]),
    ?assertEqual(Now, maps:get(?UID1, SecondMap, undefined)),
    ?assertEqual(Now2, maps:get(?UID2, SecondMap, undefined)).


last_ipaddress_test() ->
    setup(),
    ok = model_accounts:create_account(?UID1, ?PHONE1, ?NAME1, ?USER_AGENT1, ?CAMPAIGN_ID, ?TS1),
    undefined = model_accounts:get_last_ipaddress(?UID1),

    ok = model_accounts:set_last_ip_and_connection_time(?UID1, <<"73.223.182.178">>, util:now_ms()),
    <<"73.223.182.178">> = model_accounts:get_last_ipaddress(?UID1),
    ok.


subscribe_test() ->
    setup(),
    ok = model_accounts:presence_subscribe(?UID1, ?UID2),
    ok = model_accounts:presence_subscribe(?UID1, ?UID2),
    {ok, [?UID2]} = model_accounts:get_subscribed_uids(?UID1),
    {ok, [?UID1]} = model_accounts:get_broadcast_uids(?UID2).


unsubscribe_test() ->
    setup(),
    ok = model_accounts:presence_subscribe(?UID1, ?UID2),
    ok = model_accounts:presence_subscribe(?UID1, ?UID3),
    {ok, [?UID2, ?UID3]} = model_accounts:get_subscribed_uids(?UID1),
    {ok, [?UID1]} = model_accounts:get_broadcast_uids(?UID2),
    {ok, [?UID1]} = model_accounts:get_broadcast_uids(?UID3),
    ok = model_accounts:presence_unsubscribe(?UID1, ?UID2),
    {ok, []} = model_accounts:get_broadcast_uids(?UID2),
    {ok, [?UID1]} = model_accounts:get_broadcast_uids(?UID3),
    ok.


clear_subscriptions_test() ->
    setup(),
    ok = model_accounts:presence_subscribe(?UID1, ?UID2),
    ok = model_accounts:presence_subscribe(?UID1, ?UID3),
    {ok, [?UID2, ?UID3]} = model_accounts:get_subscribed_uids(?UID1),
    {ok, [?UID1]} = model_accounts:get_broadcast_uids(?UID2),
    {ok, [?UID1]} = model_accounts:get_broadcast_uids(?UID3),
    ok = model_accounts:presence_unsubscribe_all(?UID1),
    {ok, []} = model_accounts:get_subscribed_uids(?UID1),
    {ok, []} = model_accounts:get_broadcast_uids(?UID2),
    {ok, []} = model_accounts:get_broadcast_uids(?UID3),
    ok.


push_token_test() ->
    setup(),
    ?assertEqual({ok, undefined}, model_accounts:get_push_token(?UID1)),
    ?assertEqual(ok, model_accounts:set_push_token(?UID1, ?PUSH_TOKEN_OS1,
            ?PUSH_TOKEN1, ?PUSH_TOKEN_TIMESTAMP1, ?PUSH_LANG_ID1)),
    ?assertEqual({ok, ?PUSH_INFO1}, model_accounts:get_push_token(?UID1)),
    ?assertEqual(ok, model_accounts:remove_push_token(?UID1)),
    ?assertEqual({ok, undefined}, model_accounts:get_push_token(?UID1)),

    ?assertEqual({ok, undefined}, model_accounts:get_push_token(?UID2)),
    ?assertEqual(ok, model_accounts:set_push_token(?UID2, ?PUSH_TOKEN_OS2,
            ?PUSH_TOKEN2, ?PUSH_TOKEN_TIMESTAMP2, ?PUSH_LANG_ID2)),
    ?assertEqual({ok, ?PUSH_INFO2}, model_accounts:get_push_token(?UID2)).


voip_token_test() ->
    setup(),
    ?assertEqual({ok, undefined}, model_accounts:get_push_token(?UID1)),
    ?assertEqual(ok, model_accounts:set_voip_token(?UID1,
        ?PUSH_TOKEN1, ?PUSH_TOKEN_TIMESTAMP1, ?PUSH_LANG_ID1)),
    ?assertEqual({ok, ?VOIP_PUSH_INFO1}, model_accounts:get_push_token(?UID1)),
    ?assertEqual(ok, model_accounts:remove_push_token(?UID1)),
    ?assertEqual({ok, undefined}, model_accounts:get_push_token(?UID1)),
    ok.


lang_id_count_test() ->
    setup(),
    persistent_term:put(lang_id, true),
    LangCountsMap1 = model_accounts:count_lang_keys(),
    ?assertEqual(0, maps:get(?PUSH_LANG_ID1, LangCountsMap1, 0)),
    ?assertEqual(0, maps:get(?PUSH_LANG_ID2, LangCountsMap1, 0)),

    ok = model_accounts:set_push_token(?UID1, ?PUSH_TOKEN_OS1,
            ?PUSH_TOKEN1, ?PUSH_TOKEN_TIMESTAMP1, ?PUSH_LANG_ID1),
    LangCountsMap2 = model_accounts:count_lang_keys(),
    ?assertEqual(1, maps:get(?PUSH_LANG_ID1, LangCountsMap2, 0)),
    ?assertEqual(0, maps:get(?PUSH_LANG_ID2, LangCountsMap2, 0)),

    ok = model_accounts:set_push_token(?UID2, ?PUSH_TOKEN_OS2,
            ?PUSH_TOKEN2, ?PUSH_TOKEN_TIMESTAMP2, ?PUSH_LANG_ID1),
    LangCountsMap3 = model_accounts:count_lang_keys(),
    ?assertEqual(2, maps:get(?PUSH_LANG_ID1, LangCountsMap3, 0)),
    ?assertEqual(0, maps:get(?PUSH_LANG_ID2, LangCountsMap3, 0)),

    ok = model_accounts:set_push_token(?UID2, ?PUSH_TOKEN_OS2,
            ?PUSH_TOKEN2, ?PUSH_TOKEN_TIMESTAMP2, ?PUSH_LANG_ID2),
    LangCountsMap4 = model_accounts:count_lang_keys(),
    ?assertEqual(1, maps:get(?PUSH_LANG_ID1, LangCountsMap4, 0)),
    ?assertEqual(1, maps:get(?PUSH_LANG_ID2, LangCountsMap4, 0)),
    persistent_term:erase(lang_id),
    ok.


push_post_test() ->
    setup(),
    ?assertEqual({ok, true}, model_accounts:get_push_post_pref(?UID1)),
    ?assertEqual(ok, model_accounts:set_push_post_pref(?UID1, false)),
    ?assertEqual({ok, false}, model_accounts:get_push_post_pref(?UID1)),
    ?assertEqual(ok, model_accounts:remove_push_post_pref(?UID1)),
    ?assertEqual({ok, true}, model_accounts:get_push_post_pref(?UID1)).


push_coment_test() ->
    setup(),
    ?assertEqual({ok, true}, model_accounts:get_push_comment_pref(?UID1)),
    ?assertEqual(ok, model_accounts:set_push_comment_pref(?UID1, true)),
    ?assertEqual({ok, true}, model_accounts:get_push_comment_pref(?UID1)),
    ?assertEqual(ok, model_accounts:remove_push_comment_pref(?UID1)),
    ?assertEqual({ok, true}, model_accounts:get_push_comment_pref(?UID1)).


count_test() ->
    setup(),
    Slot = crc16_redis:hash(binary_to_list(?UID1)),
    ?assertEqual(0, model_accounts:count_accounts()),
    ?assertEqual(0, model_accounts:count_registrations()),
    ?assertEqual(ok, model_accounts:create_account(?UID1, ?PHONE1, ?NAME1, ?USER_AGENT1, ?CAMPAIGN_ID, ?TS1)),
    ?assertEqual(1, model_accounts:count_accounts(Slot)),
    ?assertEqual(1, model_accounts:count_registrations(Slot)),
    ?assertEqual(1, model_accounts:count_registrations()),
    ?assertEqual(1, model_accounts:count_accounts()),

    ?assertEqual(ok, model_accounts:create_account(?UID2, ?PHONE2, ?NAME1, ?USER_AGENT1, ?CAMPAIGN_ID, ?TS1)),
    ?assertEqual(ok, model_accounts:create_account(?UID3, ?PHONE3, ?NAME1, ?USER_AGENT1, ?CAMPAIGN_ID, ?TS1)),
    ?assertEqual(ok, model_accounts:create_account(?UID4, ?PHONE4, ?NAME1, ?USER_AGENT1, ?CAMPAIGN_ID, ?TS1)),
    ?assertEqual(4, model_accounts:count_accounts()),

    ok.


traced_uids_test() ->
    setup(),
    ?assertEqual({ok, []}, model_accounts:get_traced_uids()),
    model_accounts:add_uid_to_trace(?UID1),
    ?assertEqual({ok, [?UID1]}, model_accounts:get_traced_uids()),
    model_accounts:add_uid_to_trace(?UID2),
    ?assertEqual({ok, [?UID1, ?UID2]}, model_accounts:get_traced_uids()),
    model_accounts:remove_uid_from_trace(?UID2),
    model_accounts:remove_uid_from_trace(?UID1),
    ?assertEqual({ok, []}, model_accounts:get_traced_uids()),
    ok.


traced_phones_test() ->
    setup(),
    ?assertEqual({ok, []}, model_accounts:get_traced_phones()),
    model_accounts:add_phone_to_trace(?PHONE1),
    ?assertEqual({ok, [?PHONE1]}, model_accounts:get_traced_phones()),
    model_accounts:add_phone_to_trace(?PHONE2),
    model_accounts:add_phone_to_trace(?PHONE2),  % should have no effect
    ?assertEqual({ok, [?PHONE1, ?PHONE2]}, model_accounts:get_traced_phones()),
    model_accounts:remove_phone_from_trace(?PHONE2),
    model_accounts:remove_phone_from_trace(?PHONE1),
    ?assertEqual({ok, []}, model_accounts:get_traced_phones()),
    ok.


test_counts() ->
    setup(),
    ?assertEqual(ok, model_accounts:create_account(?UID1, ?PHONE1, ?NAME1, ?USER_AGENT1, ?CAMPAIGN_ID, ?TS1)),
    ?assertEqual(ok, model_accounts:create_account(?UID2, ?PHONE2, ?NAME2, ?USER_AGENT2, ?CAMPAIGN_ID, ?TS2)),
    ?assertEqual(ok, model_accounts:delete_account(?UID1)),
    ?assertEqual(2, model_accounts:count_registrations()),
    ?assertEqual(1, model_accounts:count_accounts()),
    ok.


counts_test_() ->
    {timeout, 20,
        fun test_counts/0}.


is_uid_traced_test() ->
    setup(),
    ?assertEqual(false, model_accounts:is_uid_traced(?UID1)),
    model_accounts:add_uid_to_trace(?UID1),
    ?assertEqual(true, model_accounts:is_uid_traced(?UID1)),
    ?assertEqual(false, model_accounts:is_uid_traced(?UID2)),
    model_accounts:remove_uid_from_trace(?UID1),
    ?assertEqual(false, model_accounts:is_uid_traced(?UID1)),
    ok.


is_phone_traced_test() ->
    setup(),
    ?assertEqual(false, model_accounts:is_phone_traced(?PHONE1)),
    model_accounts:add_phone_to_trace(?PHONE1),
    ?assertEqual(true, model_accounts:is_phone_traced(?PHONE1)),
    ?assertEqual(false, model_accounts:is_phone_traced(?PHONE2)),
    model_accounts:remove_phone_from_trace(?PHONE1),
    ?assertEqual(false, model_accounts:is_phone_traced(?PHONE1)),
    ok.


get_names_test() ->
    setup(),
    #{} = model_accounts:get_names([]),
    ok = model_accounts:create_account(?UID1, ?PHONE1, ?NAME1, ?USER_AGENT1, ?CAMPAIGN_ID, ?TS1),
    ok = model_accounts:create_account(?UID2, ?PHONE2, ?NAME2, ?USER_AGENT2, ?CAMPAIGN_ID, ?TS2),
    ResMap = #{?UID1 => ?NAME1, ?UID2 => ?NAME2},
    ResMap = model_accounts:get_names([?UID1, ?UID2]),
    ResMap = model_accounts:get_names([?UID1, ?UID2, ?UID3]),
    ok.


get_avatar_ids_test() ->
    setup(),
    #{} = model_accounts:get_avatar_ids([]),
    ok = model_accounts:create_account(?UID1, ?PHONE1, ?NAME1, ?USER_AGENT1, ?CAMPAIGN_ID, ?TS1),
    ok = model_accounts:set_avatar_id(?UID1, ?AVATAR_ID1),
    ok = model_accounts:create_account(?UID3, ?PHONE3, ?NAME3, ?USER_AGENT3, ?CAMPAIGN_ID, ?TS2),
    ok = model_accounts:set_avatar_id(?UID3, ?AVATAR_ID3),
    ResMap = #{?UID1 => ?AVATAR_ID1, ?UID3 => ?AVATAR_ID3},
    ResMap = model_accounts:get_avatar_ids([?UID1, ?UID3]),
    ResMap = model_accounts:get_avatar_ids([?UID1, ?UID2, ?UID3]),
    ok.


check_accounts_exists_test() ->
    setup(),
    ?assertEqual(ok, model_accounts:create_account(?UID1, ?PHONE1, ?NAME1, ?USER_AGENT1, ?CAMPAIGN_ID, ?TS1)),
    ?assertEqual(ok, model_accounts:create_account(?UID2, ?PHONE2, ?NAME2, ?USER_AGENT2, ?CAMPAIGN_ID, ?TS2)),
    ?assertEqual([?UID1, ?UID2], model_accounts:filter_nonexisting_uids([?UID1, ?UID3, ?UID2])),
    ok.

check_whisper_keys() ->
    setup(),
    ?assertEqual(ok, model_accounts:create_account(?UID1, ?PHONE1, ?NAME1, ?USER_AGENT1, ?CAMPAIGN_ID, ?TS1)),
    {?PHONE2, ok, undefined} = mod_invites:request_invite(?UID1, ?PHONE2),
    meck:new(dev_users),
    meck:expect(dev_users, is_dev_uid, fun(_) -> true end),
    ?assertEqual(ok, model_accounts:create_account(?UID2, ?PHONE2, ?NAME2, ?USER_AGENT2, ?CAMPAIGN_ID, ?TS2)),
    ?assertEqual(ok, model_accounts:create_account(?UID3, ?PHONE3, ?NAME3, ?USER_AGENT3, ?CAMPAIGN_ID, ?TS1)),
    ?assertEqual(ok, model_accounts:create_account(?UID4, ?PHONE4, ?NAME4, ?USER_AGENT4, ?CAMPAIGN_ID, ?TS2)),
    ?assertEqual(ok, model_accounts:create_account(?UID5, ?PHONE5, ?NAME5, ?USER_AGENT5, ?CAMPAIGN_ID, ?TS1)),
    ?assertEqual(ok, model_whisper_keys:set_keys(?UID1, ?IDENTITY_KEY1, ?SIGNED_KEY1,
            [?OTP1_KEY1, ?OTP1_KEY2, ?OTP1_KEY3, ?OTP1_KEY4, ?OTP1_KEY5])),
    ?assertEqual(ok, model_whisper_keys:set_keys(?UID2, ?IDENTITY_KEY2, ?SIGNED_KEY2,
            [?OTP2_KEY1, ?OTP2_KEY2, ?OTP2_KEY3])),
    ?assertEqual(ok, model_whisper_keys:set_keys(?UID3, ?IDENTITY_KEY3, ?SIGNED_KEY3,
            [?OTP3_KEY1, ?OTP3_KEY2, ?OTP3_KEY3])),
    redis_migrate:start_migration("Check whisper keys", redis_accounts, check_users_by_whisper_keys,
            [{dry_run, true}, {execute, sequential}]),
    %% Just so the above async range scan finish, we will wait for 5 seconds.
    timer:sleep(timer:seconds(5)),
    meck:validate(dev_users),
    meck:unload(dev_users),
    ok.

%% This test is simply for code coverage to avoid fixing silly mistakes in prod.
check_whisper_keys_test() ->
    {timeout, 10,
        fun check_whisper_keys/0}.

check_uid_to_delete_test() ->
    setup(),
    ?assertEqual(ok, model_accounts:create_account(?UID1, ?PHONE1, ?NAME1, ?USER_AGENT1, ?CAMPAIGN_ID, ?TS1)),
    ?assertEqual(ok, model_accounts:create_account(?UID2, ?PHONE2, ?NAME2, ?USER_AGENT2, ?CAMPAIGN_ID, ?TS2)),
    ?assertEqual(ok, model_accounts:create_account(?UID3, ?PHONE3, ?NAME3, ?USER_AGENT3, ?CAMPAIGN_ID, ?TS1)),
    ?assertEqual(ok, model_accounts:create_account(?UID4, ?PHONE4, ?NAME4, ?USER_AGENT4, ?CAMPAIGN_ID, ?TS2)),
    ?assertEqual(ok, model_accounts:create_account(?UID5, ?PHONE5, ?NAME5, ?USER_AGENT5, ?CAMPAIGN_ID, ?TS1)),
    ?assertEqual(0, model_accounts:count_uids_to_delete()),
    ?assertEqual(ok, model_accounts:add_uid_to_delete(?UID1)),
    ?assertEqual(1, model_accounts:count_uids_to_delete()),
    ?assertEqual(ok, model_accounts:add_uid_to_delete(?UID2)),
    ?assertEqual(2, model_accounts:count_uids_to_delete()),
    ?assertEqual(ok, model_accounts:cleanup_uids_to_delete_keys()),
    ?assertEqual(0, model_accounts:count_uids_to_delete()),
    ?assertEqual(ok, model_accounts:add_uid_to_delete(?UID1)),
    ?assertEqual(ok, model_accounts:add_uid_to_delete(?UID2)),
    ?assertEqual(ok, model_accounts:add_uid_to_delete(?UID3)),
    ?assertEqual(ok, model_accounts:add_uid_to_delete(?UID4)),
    ?assertEqual(ok, model_accounts:add_uid_to_delete(?UID5)),
    ?assertEqual(5, model_accounts:count_uids_to_delete()),
    All = lists:foldl(
        fun(Slot, Acc) ->
            {ok, Uids} = model_accounts:get_uids_to_delete(Slot),
            Acc ++ Uids
        end,
        [],
        lists:seq(0, ?NUM_SLOTS - 1)),
    ?assertEqual(sets:from_list(All), sets:from_list([?UID1, ?UID2, ?UID3, ?UID4, ?UID5])),
    %% TODO(vipin): uncomment the redis scan test.
    %% redis_migrate:start_migration("Check whisper keys", ecredis_accounts, find_inactive_accounts,
    %%        [{dry_run, false}, {execute, sequential}]),
    %% Just so the above async range scan finish, we will wait for 1 second.
    %% timer:sleep(timer:seconds(1)),
    %% ?assertEqual(0, model_accounts:count_uids_to_delete()),
    ?assertEqual(true, model_accounts:mark_inactive_uids_gen_start()),
    ?assertEqual(true, model_accounts:mark_inactive_uids_deletion_start()),
    ?assertEqual(true, model_accounts:mark_inactive_uids_check_start()),
    ?assertEqual(false, model_accounts:mark_inactive_uids_gen_start()),
    ?assertEqual(false, model_accounts:mark_inactive_uids_deletion_start()),
    ?assertEqual(false, model_accounts:mark_inactive_uids_check_start()),
    ok.

start_export_test() ->
    setup(),
    {ok, _Ts} = model_accounts:start_export(?UID1, util:random_str(20)),
    ?assertEqual({error, already_started}, model_accounts:start_export(?UID1, util:random_str(20))),
    ok.

get_export_test() ->
    setup(),
    ExportId = util:random_str(20),
    {ok, Ts} = model_accounts:start_export(?UID1, ExportId),
    {ok, Ts, ExportId, TTL} = model_accounts:get_export(?UID1),
    ?assertEqual("integer", util:type(TTL)),
    ok.

marketing_tag_test() ->
    setup(),
    {ok, []} = model_accounts:get_marketing_tags(?UID1),
    ok = model_accounts:add_marketing_tag(?UID1, ?MARKETING_TAG1),
    {ok, [{?MARKETING_TAG1, Ts1}]} = model_accounts:get_marketing_tags(?UID1),
    ok = model_accounts:add_marketing_tag(?UID1, ?MARKETING_TAG2),
    {ok, [{?MARKETING_TAG2, _Ts2}, {?MARKETING_TAG1, Ts1}]} = model_accounts:get_marketing_tags(?UID1),
    ok.

psa_tag_test() ->
    setup(),
    0 = model_accounts:count_psa_tagged_uids(?PSA_TAG1),
    lists:foreach(fun(Slot) ->
        {ok, []} = model_accounts:get_psa_tagged_uids(Slot, ?PSA_TAG1)
    end, lists:seq(0, ?NUM_SLOTS -1)),
    ok = model_accounts:add_uid_to_psa_tag(?UID1, ?PSA_TAG1),
    ok = model_accounts:add_uid_to_psa_tag(?UID2, ?PSA_TAG1),
    2 = model_accounts:count_psa_tagged_uids(?PSA_TAG1),
    UidsList = lists:foldl(fun(Slot, Acc) ->
        {ok, List} = model_accounts:get_psa_tagged_uids(Slot, ?PSA_TAG1),
        Acc ++ List
    end, [], lists:seq(0, ?NUM_SLOTS -1)),
    ?assertEqual(sets:from_list([?UID1, ?UID2]), sets:from_list(UidsList)),
    model_accounts:cleanup_psa_tagged_uids(?PSA_TAG1),
    0 = model_accounts:count_psa_tagged_uids(?PSA_TAG1),
    lists:foreach(fun(Slot) ->
        {ok, []} = model_accounts:get_psa_tagged_uids(Slot, ?PSA_TAG1)
    end, lists:seq(0, ?NUM_SLOTS -1)),
    true = model_accounts:mark_psa_post_sent(?UID1, ?POSTID1),
    false = model_accounts:mark_psa_post_sent(?UID1, ?POSTID1),
    ok.


% cleanup_perf_test() ->
%     tutil:perf(
%         100,
%         fun() -> setup() end,
%         fun() -> ok = model_accounts:cleanup_uids_to_delete_keys() end
%     ).


% unsubscribe_perf_test() ->
%     tutil:perf(
%         100,
%         fun() -> setup() end,
%         fun() -> ok = model_accounts:presence_unsubscribe_all(?UID1) end
%     ).

