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
  tutil:cleardb(redis_accounts).

-define(UID1, <<"1">>).
-define(UID2, <<"2">>).
-define(UID3, <<"3">>).

-define(ALL, all).
-define(EXCEPT, except).
-define(ONLY, only).


only_key_test() ->
    ?assertEqual(<<"onl:{1}">>, model_privacy:only_key(?UID1)).


except_key_test() ->
    ?assertEqual(<<"exc:{1}">>, model_privacy:except_key(?UID1)).


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


only_list_test() ->
    setup(),
    ?assertEqual({ok, []}, model_privacy:get_only_uids(?UID1)),
    ?assertEqual(false, model_privacy:is_only_uid(?UID1, ?UID2)),
    ?assertEqual(ok, model_privacy:add_only_uid(?UID1, ?UID2)),
    ?assertEqual({ok, [?UID2]}, model_privacy:get_only_uids(?UID1)),
    ?assertEqual(true, model_privacy:is_only_uid(?UID1, ?UID2)),
    ?assertEqual(ok, model_privacy:remove_only_uid(?UID1, ?UID2)),
    ?assertEqual({ok, []}, model_privacy:get_only_uids(?UID1)),

    ?assertEqual(ok, model_privacy:add_only_uids(?UID1, [])),
    ?assertEqual(ok, model_privacy:add_only_uids(?UID1, [?UID2, ?UID3])),
    ?assertEqual({ok, [?UID2, ?UID3]}, model_privacy:get_only_uids(?UID1)),
    ?assertEqual(true, model_privacy:is_only_uid(?UID1, ?UID2)),
    ?assertEqual(true, model_privacy:is_only_uid(?UID1, ?UID3)),

    ?assertEqual(ok, model_privacy:remove_user(?UID1)),
    ?assertEqual({ok, []}, model_privacy:get_only_uids(?UID1)).


except_list_test_test() ->
    setup(),
    ?assertEqual({ok, []}, model_privacy:get_except_uids(?UID1)),
    ?assertEqual(false, model_privacy:is_except_uid(?UID1, ?UID2)),
    ?assertEqual(ok, model_privacy:add_except_uid(?UID1, ?UID2)),
    ?assertEqual({ok, [?UID2]}, model_privacy:get_except_uids(?UID1)),
    ?assertEqual(true, model_privacy:is_except_uid(?UID1, ?UID2)),
    ?assertEqual(ok, model_privacy:remove_except_uid(?UID1, ?UID2)),
    ?assertEqual({ok, []}, model_privacy:get_except_uids(?UID1)),

    ?assertEqual(ok, model_privacy:add_except_uids(?UID1, [])),
    ?assertEqual(ok, model_privacy:add_except_uids(?UID1, [?UID2, ?UID3])),
    ?assertEqual({ok, [?UID2, ?UID3]}, model_privacy:get_except_uids(?UID1)),
    ?assertEqual(true, model_privacy:is_except_uid(?UID1, ?UID2)),
    ?assertEqual(true, model_privacy:is_except_uid(?UID1, ?UID3)),

    ?assertEqual(ok, model_privacy:remove_user(?UID1)),
    ?assertEqual({ok, []}, model_privacy:get_except_uids(?UID1)).


mute_test() ->
    setup(),
    ?assertEqual({ok, []}, model_privacy:get_mutelist_uids(?UID1)),
    ?assertEqual(ok, model_privacy:mute_uid(?UID1, ?UID2)),
    ?assertEqual({ok, [?UID2]}, model_privacy:get_mutelist_uids(?UID1)),
    ?assertEqual(ok, model_privacy:unmute_uid(?UID1, ?UID2)),
    ?assertEqual({ok, []}, model_privacy:get_mutelist_uids(?UID1)),

    ?assertEqual(ok, model_privacy:mute_uids(?UID1, [])),
    ?assertEqual(ok, model_privacy:mute_uids(?UID1, [?UID2, ?UID3])),
    ?assertEqual({ok, [?UID2, ?UID3]}, model_privacy:get_mutelist_uids(?UID1)),

    ?assertEqual(ok, model_privacy:remove_user(?UID1)),
    ?assertEqual({ok, []}, model_privacy:get_mutelist_uids(?UID1)).


block_test() ->
    setup(),
    ?assertEqual({ok, []}, model_privacy:get_blocked_uids(?UID1)),
    ?assertEqual(false, model_privacy:is_blocked(?UID1, ?UID2)),
    ?assertEqual(false, model_privacy:is_blocked_by(?UID2, ?UID1)),
    ?assertEqual(ok, model_privacy:block_uid(?UID1, ?UID2)),
    ?assertEqual({ok, [?UID2]}, model_privacy:get_blocked_uids(?UID1)),
    ?assertEqual(true, model_privacy:is_blocked(?UID1, ?UID2)),
    ?assertEqual(true, model_privacy:is_blocked_by(?UID2, ?UID1)),
    ?assertEqual(ok, model_privacy:unblock_uid(?UID1, ?UID2)),
    ?assertEqual({ok, []}, model_privacy:get_blocked_uids(?UID1)),

    ?assertEqual(ok, model_privacy:block_uids(?UID1, [])),
    ?assertEqual(ok, model_privacy:block_uids(?UID1, [?UID2, ?UID3])),
    ?assertEqual({ok, [?UID2, ?UID3]}, model_privacy:get_blocked_uids(?UID1)),
    ?assertEqual({ok, [?UID1]}, model_privacy:get_blocked_by_uids(?UID2)),
    ?assertEqual({ok, [?UID1]}, model_privacy:get_blocked_by_uids(?UID3)),
    ?assertEqual(true, model_privacy:is_blocked(?UID1, ?UID2)),
    ?assertEqual(true, model_privacy:is_blocked_by(?UID2, ?UID1)),
    ?assertEqual(true, model_privacy:is_blocked(?UID1, ?UID3)),
    ?assertEqual(true, model_privacy:is_blocked_by(?UID3, ?UID1)),

    ?assertEqual(ok, model_privacy:remove_user(?UID1)),
    ?assertEqual({ok, []}, model_privacy:get_blocked_uids(?UID1)).


is_blocked_test() ->
    setup(),
    ?assertEqual({ok, []}, model_privacy:get_blocked_uids(?UID1)),
    ?assertEqual(false, model_privacy:is_blocked_any(?UID1, ?UID2)),
    ?assertEqual(ok, model_privacy:block_uid(?UID1, ?UID2)),
    ?assertEqual(true, model_privacy:is_blocked_any(?UID1, ?UID2)),

    ?assertEqual(ok, model_privacy:unblock_uid(?UID1, ?UID2)),
    ?assertEqual(false, model_privacy:is_blocked_any(?UID1, ?UID2)),
    ?assertEqual(ok, model_privacy:block_uid(?UID2, ?UID1)),
    ?assertEqual(true, model_privacy:is_blocked_any(?UID1, ?UID2)),

    ?assertEqual(ok, model_privacy:remove_user(?UID1)),
    ?assertEqual({ok, []}, model_privacy:get_blocked_uids(?UID1)).

