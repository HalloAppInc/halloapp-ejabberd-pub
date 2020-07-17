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

setup() ->
    mod_redis:start(undefined, []),
%%  redis_sup:start_link(),
    clear(),
    ok.

clear() ->
  {ok, ok} = gen_server:call(redis_accounts_client, flushdb).

-define(UID1, <<"1">>).
-define(PHONE1, <<"16505551111">>).
-define(NAME1, <<"Name1">>).
-define(USER_AGENT1, <<"HalloApp/Android1.0">>).
-define(TS1, 1500000000001).
-define(AS1, available).
-define(AVATAR_ID1, <<"CwlRWoG4TduL93Zyrz30Uw">>).
-define(PUSH_TOKEN_OS1, <<"android">>).
-define(PUSH_TOKEN1, <<"eXh2yYFZShGXzpobZEc5kg">>).
-define(PUSH_TOKEN_TIMESTAMP1, 1589300000082).
-define(PUSH_INFO1, #push_info{uid = ?UID1, os = ?PUSH_TOKEN_OS1,
        token = ?PUSH_TOKEN1, timestamp_ms = ?PUSH_TOKEN_TIMESTAMP1}).

-define(UID2, <<"2">>).
-define(PHONE2, <<"16505552222">>).
-define(NAME2, <<"Name2">>).
-define(USER_AGENT2, <<"HalloApp/iPhone1.0">>).
-define(TS2, 1500000000002).
-define(AVATAR_ID2, <<>>).
-define(PUSH_TOKEN_OS2, <<"ios">>).
-define(PUSH_TOKEN2, <<"pu7YCnjPQpa4yHm0gJRJ1g">>).
-define(PUSH_TOKEN_TIMESTAMP2, 1570300000148).
-define(PUSH_INFO2, #push_info{uid = ?UID2, os = ?PUSH_TOKEN_OS2,
        token = ?PUSH_TOKEN2, timestamp_ms = ?PUSH_TOKEN_TIMESTAMP2}).

-define(UID3, <<"3">>).


empty_test() ->
    ok.


key_test() ->
    ?assertEqual(<<"acc:{1}">>, model_accounts:key(?UID1)).


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


create_account_test() ->
    setup(),
    false = model_accounts:account_exists(?UID1),
    false = model_accounts:is_account_deleted(?UID1),
    ok = model_accounts:create_account(?UID1, ?PHONE1, ?NAME1, ?USER_AGENT1, ?TS1),
    {error, exists} = model_accounts:create_account(?UID1, ?PHONE1, ?NAME1, ?USER_AGENT1, ?TS1),
    true = model_accounts:account_exists(?UID1),
    false = model_accounts:is_account_deleted(?UID1),
    ok.


delete_account_test() ->
    setup(),
    ok = model_accounts:create_account(?UID1, ?PHONE1, ?NAME1, ?USER_AGENT1, ?TS1),
    ?assertEqual(true, model_accounts:account_exists(?UID1)),
    ?assertEqual(false, model_accounts:is_account_deleted(?UID1)),
    ok = model_accounts:delete_account(?UID1),
    ?assertEqual(false, model_accounts:account_exists(?UID1)),
    ?assertEqual(true, model_accounts:is_account_deleted(?UID1)),
    {error, deleted} = model_accounts:create_account(?UID1, ?PHONE1, ?NAME1, ?USER_AGENT1).


create_account2_test() ->
    setup(),
    ok = model_accounts:create_account(?UID1, ?PHONE1, ?NAME1, ?USER_AGENT1, ?TS1),
    ?assertEqual({ok, ?PHONE1}, model_accounts:get_phone(?UID1)),
    ?assertEqual({ok, ?NAME1}, model_accounts:get_name(?UID1)),
    ?assertEqual({ok, ?USER_AGENT1}, model_accounts:get_signup_user_agent(?UID1)),
    ?assertEqual({ok, ?TS1}, model_accounts:get_creation_ts_ms(?UID1)).


get_account_test() ->
    setup(),
    ok = model_accounts:create_account(?UID1, ?PHONE1, ?NAME1, ?USER_AGENT1, ?TS1),
    {ok, Account} = model_accounts:get_account(?UID1),
    ?assertEqual(?PHONE1, Account#account.phone),
    ?assertEqual(?NAME1, Account#account.name),
    ?assertEqual(?USER_AGENT1, Account#account.signup_user_agent),
    ?assertEqual(?TS1, Account#account.creation_ts_ms),
    ok.


get_signup_user_agent_test() ->
    setup(),
    ok = model_accounts:create_account(?UID1, ?PHONE1, ?NAME1, ?USER_AGENT1),
    ?assertEqual({ok, ?USER_AGENT1}, model_accounts:get_signup_user_agent(?UID1)),
    ok = model_accounts:set_user_agent(?UID1, ?USER_AGENT2),
    ?assertEqual({ok, ?USER_AGENT2}, model_accounts:get_signup_user_agent(?UID1)).


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
    ok = model_accounts:create_account(?UID1, ?PHONE1, ?NAME1, ?USER_AGENT1, ?TS1),
    {ok, ?PHONE1} = model_accounts:get_phone(?UID1),
    {error, missing} = model_accounts:get_phone(?UID2).


get_user_agent_test() ->
    setup(),
    ok = model_accounts:create_account(?UID1, ?PHONE1, ?NAME1, ?USER_AGENT1, ?TS1),
    {ok, ?USER_AGENT1} = model_accounts:get_signup_user_agent(?UID1),
    {error, missing} = model_accounts:get_signup_user_agent(?UID2).


last_activity_test() ->
    setup(),
    ok = model_accounts:create_account(?UID1, ?PHONE1, ?NAME1, ?USER_AGENT1, ?TS1),
    {ok, LastActivity} = model_accounts:get_last_activity(?UID1),
    ?assertEqual(?UID1, LastActivity#activity.uid),
    ?assertEqual(undefined, LastActivity#activity.last_activity_ts_ms),
    ?assertEqual(undefined, LastActivity#activity.status),
    Now = util:now_ms(),
    ok = model_accounts:set_last_activity(?UID1, Now, ?AS1),
    {ok, NewLastActivity} = model_accounts:get_last_activity(?UID1),
    ?assertEqual(?UID1, NewLastActivity#activity.uid),
    ?assertEqual(Now, NewLastActivity#activity.last_activity_ts_ms),
    ?assertEqual(?AS1, NewLastActivity#activity.status).


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
    ?assertEqual({ok, undefined}, model_accounts:get_push_info(?UID1)),
    ?assertEqual(ok, model_accounts:set_push_info(?UID1, ?PUSH_TOKEN_OS1,
            ?PUSH_TOKEN1, ?PUSH_TOKEN_TIMESTAMP1)),
    ?assertEqual({ok, ?PUSH_INFO1}, model_accounts:get_push_info(?UID1)),
    ?assertEqual(ok, model_accounts:remove_push_info(?UID1)),
    ?assertEqual({ok, undefined}, model_accounts:get_push_info(?UID1)),

    ?assertEqual({ok, undefined}, model_accounts:get_push_info(?UID2)),
    ?assertEqual(ok, model_accounts:set_push_info(?PUSH_INFO2)),
    ?assertEqual({ok, ?PUSH_INFO2}, model_accounts:get_push_info(?UID2)).


count_test() ->
    setup(),
    Slot = eredis_cluster_hash:hash(binary_to_list(?UID1)),
    ?assertEqual(0, model_accounts:count_accounts(Slot)),
    ?assertEqual(0, model_accounts:count_registrations(Slot)),
    ?assertEqual(ok, model_accounts:create_account(?UID1, ?PHONE1, ?NAME1, ?USER_AGENT1, ?TS1)),
    ?assertEqual(1, model_accounts:count_accounts(Slot)),
    ?assertEqual(1, model_accounts:count_registrations(Slot)),
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
    ?assertEqual(ok, model_accounts:create_account(?UID1, ?PHONE1, ?NAME1, ?USER_AGENT1, ?TS1)),
    ?assertEqual(ok, model_accounts:create_account(?UID2, ?PHONE2, ?NAME2, ?USER_AGENT2, ?TS2)),
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
    ?assertEqual(ok, model_accounts:create_account(?UID1, ?PHONE1, ?NAME1, ?USER_AGENT1, ?TS1)),
    ?assertEqual(ok, model_accounts:create_account(?UID2, ?PHONE2, ?NAME2, ?USER_AGENT2, ?TS2)),
    ProfilesMap = model_accounts:get_names([?UID1, ?UID2, ?UID3]),
    ?assertEqual(2, maps:size(ProfilesMap)),
    ?assertEqual(?NAME1, maps:get(?UID1, ProfilesMap)),
    ?assertEqual(?NAME2, maps:get(?UID2, ProfilesMap)),
    ok.


check_accounts_exists_test() ->
    setup(),
    ?assertEqual(ok, model_accounts:create_account(?UID1, ?PHONE1, ?NAME1, ?USER_AGENT1, ?TS1)),
    ?assertEqual(ok, model_accounts:create_account(?UID2, ?PHONE2, ?NAME2, ?USER_AGENT2, ?TS2)),
    ?assertEqual([?UID1, ?UID2], model_accounts:filter_nonexisting_uids([?UID1, ?UID3, ?UID2])),
    ok.

