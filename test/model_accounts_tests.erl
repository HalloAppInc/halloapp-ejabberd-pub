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

setup() ->
  redis_sup:start_link(),
  clear(),
  model_accounts:start_link(),
  ok.

clear() ->
  ok = gen_server:cast(redis_accounts_client, flushdb).

-define(UID1, <<"1">>).
-define(PHONE1, <<"16505551111">>).
-define(NAME1, <<"Name1">>).
-define(USER_AGENT1, <<"HalloApp/Android1.0">>).
-define(TS1, 1500000000001).
-define(AS1, available).

-define(UID2, <<"2">>).
-define(PHONE2, <<"16505552222">>).
-define(NAME2, <<"Name2">>).
-define(USER_AGENT2, <<"HalloApp/iPhone1.0">>).
-define(TS2, 1500000000002).

-define(UID3, <<"3">>).


empty_test() ->
    ok.


key_test() ->
    ?assertEqual(<<"acc:{1}">>, model_accounts:key(<<"1">>)).


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
    true = model_accounts:presence_subscribe(?UID1, ?UID2),
    false = model_accounts:presence_subscribe(?UID1, ?UID2),
    {ok, [?UID2]} = model_accounts:get_subscribed_uids(?UID1),
    {ok, [?UID1]} = model_accounts:get_broadcast_uids(?UID2).


unsubscribe_test() ->
    setup(),
    true = model_accounts:presence_subscribe(?UID1, ?UID2),
    true = model_accounts:presence_subscribe(?UID1, ?UID3),
    {ok, [?UID2, ?UID3]} = model_accounts:get_subscribed_uids(?UID1),
    {ok, [?UID1]} = model_accounts:get_broadcast_uids(?UID2),
    {ok, [?UID1]} = model_accounts:get_broadcast_uids(?UID3),
    true = model_accounts:presence_unsubscribe(?UID1, ?UID2),
    {ok, []} = model_accounts:get_broadcast_uids(?UID2),
    {ok, [?UID1]} = model_accounts:get_broadcast_uids(?UID3),
    ok.


clear_subscriptions_test() ->
    setup(),
    true = model_accounts:presence_subscribe(?UID1, ?UID2),
    true = model_accounts:presence_subscribe(?UID1, ?UID3),
    {ok, [?UID2, ?UID3]} = model_accounts:get_subscribed_uids(?UID1),
    {ok, [?UID1]} = model_accounts:get_broadcast_uids(?UID2),
    {ok, [?UID1]} = model_accounts:get_broadcast_uids(?UID3),
    ok = model_accounts:presence_unsubscribe_all(?UID1),
    {ok, []} = model_accounts:get_subscribed_uids(?UID1),
    {ok, []} = model_accounts:get_broadcast_uids(?UID2),
    {ok, []} = model_accounts:get_broadcast_uids(?UID3),
    ok.