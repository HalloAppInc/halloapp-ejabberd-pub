%%%-----------------------------------------------------------------------------------
%%% File    : model_privacy_tests.erl
%%%
%%% Copyright (C) 2020 halloappinc.
%%%
%%%
%%%-----------------------------------------------------------------------------------
-module(model_privacy_tests).
-author('murali').

-include("account.hrl").
-include_lib("eunit/include/eunit.hrl").

setup() ->
    mod_redis:start(undefined, []),
    clear(),
    ok.

clear() ->
  ok = gen_server:cast(redis_accounts_client, flushdb).

-define(UID1, <<"1">>).
-define(UID2, <<"2">>).
-define(UID3, <<"3">>).

-define(ALL, all).
-define(EXCEPT, except).
-define(ONLY, only).


whitelist_key_test() ->
    ?assertEqual(<<"whi:{1}">>, model_privacy:whitelist_key(?UID1)).


blacklist_key_test() ->
    ?assertEqual(<<"bla:{1}">>, model_privacy:blacklist_key(?UID1)).


mute_key_test() ->
    ?assertEqual(<<"mut:{1}">>, model_privacy:mute_key(?UID1)).


block_key_test() ->
    ?assertEqual(<<"blo:{1}">>, model_privacy:block_key(?UID1)).


reverse_block_key_test() ->
    ?assertEqual(<<"rbl:{1}">>, model_privacy:reverse_block_key(?UID1)).


privacy_type_test() ->
    setup(),
    ?assertEqual({ok, ?ALL}, model_privacy:get_privacy_type(?UID1)),
    ?assertEqual(?ALL, model_privacy:get_privacy_type_atom(?UID1)),
    ?assertEqual(ok, model_privacy:set_privacy_type(?UID1, ?EXCEPT)),
    ?assertEqual(?EXCEPT, model_privacy:get_privacy_type_atom(?UID1)),

    ?assertEqual(?ALL, model_privacy:get_privacy_type_atom(?UID2)),
    ?assertEqual(ok, model_privacy:set_privacy_type(?UID2, ?ONLY)),
    ?assertEqual(?ONLY, model_privacy:get_privacy_type_atom(?UID2)),

    ?assertEqual(?ALL, model_privacy:get_privacy_type_atom(?UID3)),
    ?assertEqual(ok, model_privacy:set_privacy_type(?UID3, ?ALL)),
    ?assertEqual(?ALL, model_privacy:get_privacy_type_atom(?UID3)).


whitelist_test() ->
    setup(),
    ?assertEqual({ok, []}, model_privacy:get_whitelist_uids(?UID1)),
    ?assertEqual(false, model_privacy:is_uid_whitelisted(?UID1, ?UID2)),
    ?assertEqual(ok, model_privacy:whitelist_uid(?UID1, ?UID2)),
    ?assertEqual({ok, [?UID2]}, model_privacy:get_whitelist_uids(?UID1)),
    ?assertEqual(true, model_privacy:is_uid_whitelisted(?UID1, ?UID2)),
    ?assertEqual(ok, model_privacy:unwhitelist_uid(?UID1, ?UID2)),
    ?assertEqual({ok, []}, model_privacy:get_whitelist_uids(?UID1)),

    ?assertEqual(ok, model_privacy:whitelist_uids(?UID1, [])),
    ?assertEqual(ok, model_privacy:whitelist_uids(?UID1, [?UID2, ?UID3])),
    ?assertEqual({ok, [?UID2, ?UID3]}, model_privacy:get_whitelist_uids(?UID1)),
    ?assertEqual(true, model_privacy:is_uid_whitelisted(?UID1, ?UID2)),
    ?assertEqual(true, model_privacy:is_uid_whitelisted(?UID1, ?UID3)).


blacklist_test() ->
    setup(),
    ?assertEqual({ok, []}, model_privacy:get_blacklist_uids(?UID1)),
    ?assertEqual(false, model_privacy:is_uid_blacklisted(?UID1, ?UID2)),
    ?assertEqual(ok, model_privacy:blacklist_uid(?UID1, ?UID2)),
    ?assertEqual({ok, [?UID2]}, model_privacy:get_blacklist_uids(?UID1)),
    ?assertEqual(true, model_privacy:is_uid_blacklisted(?UID1, ?UID2)),
    ?assertEqual(ok, model_privacy:unblacklist_uid(?UID1, ?UID2)),
    ?assertEqual({ok, []}, model_privacy:get_blacklist_uids(?UID1)),

    ?assertEqual(ok, model_privacy:blacklist_uids(?UID1, [])),
    ?assertEqual(ok, model_privacy:blacklist_uids(?UID1, [?UID2, ?UID3])),
    ?assertEqual({ok, [?UID2, ?UID3]}, model_privacy:get_blacklist_uids(?UID1)),
    ?assertEqual(true, model_privacy:is_uid_blacklisted(?UID1, ?UID2)),
    ?assertEqual(true, model_privacy:is_uid_blacklisted(?UID1, ?UID3)).


mute_test() ->
    setup(),
    ?assertEqual({ok, []}, model_privacy:get_mutelist_uids(?UID1)),
    ?assertEqual(ok, model_privacy:mute_uid(?UID1, ?UID2)),
    ?assertEqual({ok, [?UID2]}, model_privacy:get_mutelist_uids(?UID1)),
    ?assertEqual(ok, model_privacy:unmute_uid(?UID1, ?UID2)),
    ?assertEqual({ok, []}, model_privacy:get_mutelist_uids(?UID1)),

    ?assertEqual(ok, model_privacy:mute_uids(?UID1, [])),
    ?assertEqual(ok, model_privacy:mute_uids(?UID1, [?UID2, ?UID3])),
    ?assertEqual({ok, [?UID2, ?UID3]}, model_privacy:get_mutelist_uids(?UID1)).


block_test() ->
    setup(),
    ?assertEqual({ok, []}, model_privacy:get_blocked_uids(?UID1)),
    ?assertEqual(false, model_privacy:is_uid_blocked(?UID1, ?UID2)),
    ?assertEqual(false, model_privacy:is_uid_blocked_by(?UID2, ?UID1)),
    ?assertEqual(ok, model_privacy:block_uid(?UID1, ?UID2)),
    ?assertEqual({ok, [?UID2]}, model_privacy:get_blocked_uids(?UID1)),
    ?assertEqual(true, model_privacy:is_uid_blocked(?UID1, ?UID2)),
    ?assertEqual(true, model_privacy:is_uid_blocked_by(?UID2, ?UID1)),
    ?assertEqual(ok, model_privacy:unblock_uid(?UID1, ?UID2)),
    ?assertEqual({ok, []}, model_privacy:get_blocked_uids(?UID1)),

    ?assertEqual(ok, model_privacy:block_uids(?UID1, [])),
    ?assertEqual(ok, model_privacy:block_uids(?UID1, [?UID2, ?UID3])),
    ?assertEqual({ok, [?UID2, ?UID3]}, model_privacy:get_blocked_uids(?UID1)),
    ?assertEqual({ok, [?UID1]}, model_privacy:get_blocked_by_uids(?UID2)),
    ?assertEqual({ok, [?UID1]}, model_privacy:get_blocked_by_uids(?UID3)),
    ?assertEqual(true, model_privacy:is_uid_blocked(?UID1, ?UID2)),
    ?assertEqual(true, model_privacy:is_uid_blocked_by(?UID2, ?UID1)),
    ?assertEqual(true, model_privacy:is_uid_blocked(?UID1, ?UID3)),
    ?assertEqual(true, model_privacy:is_uid_blocked_by(?UID3, ?UID1)).


is_blocked_test() ->
    setup(),
    ?assertEqual({ok, []}, model_privacy:get_blocked_uids(?UID1)),
    ?assertEqual(false, model_privacy:is_blocked(?UID1, ?UID2)),
    ?assertEqual(ok, model_privacy:block_uid(?UID1, ?UID2)),
    ?assertEqual(true, model_privacy:is_blocked(?UID1, ?UID2)),

    ?assertEqual(ok, model_privacy:unblock_uid(?UID1, ?UID2)),
    ?assertEqual(false, model_privacy:is_blocked(?UID1, ?UID2)),
    ?assertEqual(ok, model_privacy:block_uid(?UID2, ?UID1)),
    ?assertEqual(true, model_privacy:is_blocked(?UID1, ?UID2)).

