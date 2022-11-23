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
-include("ha_types.hrl").
-include_lib("eunit/include/eunit.hrl").

-define(UID1, <<"1">>).
-define(UID2, <<"2">>).
-define(UID3, <<"3">>).

-define(PHONE1, <<"123">>).
-define(PHONE2, <<"456">>).
-define(PHONE3, <<"789">>).

-define(ALL, all).
-define(EXCEPT, except).
-define(ONLY, only).


setup() ->
    tutil:setup(),
    ha_redis:start(),
    clear(),
    model_phone:add_phone(?PHONE1, ?HALLOAPP, ?UID1),
    model_phone:add_phone(?PHONE2, ?HALLOAPP, ?UID2),
    ok.

clear() ->
  tutil:cleardb(redis_accounts),
  tutil:cleardb(redis_phone).


only_key_test() ->
    ?assertEqual(<<"onl:{1}">>, model_privacy:only_key(?UID1)),
    ?assertEqual(<<"onp:{1}">>, model_privacy:only_phone_key(?UID1)).


except_key_test() ->
    ?assertEqual(<<"exc:{1}">>, model_privacy:except_key(?UID1)),
    ?assertEqual(<<"exp:{1}">>, model_privacy:except_phone_key(?UID1)).


mute_key_test() ->
    ?assertEqual(<<"mut:{1}">>, model_privacy:mute_key(?UID1)),
    ?assertEqual(<<"mup:{1}">>, model_privacy:mute_phone_key(?UID1)).


block_key_test() ->
    ?assertEqual(<<"blo:{1}">>, model_privacy:block_key(?UID1)),
    ?assertEqual(<<"blp:{1}">>, model_privacy:block_phone_key(?UID1)),
    ?assertEqual(<<"bli:{1}">>, model_privacy:block_uid_key(?UID1)).


reverse_block_key_test() ->
    ?assertEqual(<<"rbl:{1}">>, model_privacy:reverse_block_key(?UID1)),
    ?assertEqual(<<"rbp:{123}">>, model_privacy:reverse_block_phone_key(?PHONE1)),
    ?assertEqual(<<"rbi:{1}">>, model_privacy:reverse_block_uid_key(?UID1)).


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

    ?assertEqual(ok, model_privacy:remove_user(?UID1, ?PHONE1)),
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

    ?assertEqual(ok, model_privacy:remove_user(?UID1, ?PHONE1)),
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

    ?assertEqual(ok, model_privacy:remove_user(?UID1, ?PHONE1)),
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

    ?assertEqual(ok, model_privacy:remove_user(?UID1, ?PHONE1)),
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

    ?assertEqual(ok, model_privacy:remove_user(?UID1, ?PHONE1)),
    ?assertEqual({ok, []}, model_privacy:get_blocked_uids(?UID1)).


only_list_phone_test() ->
    setup(),
    ?assertEqual(ok, model_privacy:add_only_uid(?UID1, ?UID2)),
    ?assertEqual({ok, [?UID2]}, model_privacy:get_only_uids(?UID1)),
    ?assertEqual({ok, []}, model_privacy:get_only_phones(?UID1)),
    ?assertEqual(false, model_privacy:is_only_phone(?UID1, ?PHONE2)),
    ?assertEqual(ok, model_privacy:add_only_phone(?UID1, ?PHONE2)),
    ?assertEqual({ok, [?PHONE2]}, model_privacy:get_only_phones(?UID1)),
    ?assertEqual(true, model_privacy:is_only_phone(?UID1, ?PHONE2)),
    ?assertEqual(ok, model_privacy:remove_only_phone(?UID1, ?PHONE2)),
    ?assertEqual({ok, []}, model_privacy:get_only_phones(?UID1)),
    %% Setting phones: should clear uids list.
    ?assertEqual({ok, []}, model_privacy:get_only_uids(?UID1)),

    ?assertEqual(ok, model_privacy:add_only_phones(?UID1, [])),
    ?assertEqual(ok, model_privacy:add_only_phones(?UID1, [?PHONE2, ?PHONE3])),
    ?assertEqual({ok, [?PHONE2, ?PHONE3]}, model_privacy:get_only_phones(?UID1)),
    ?assertEqual(true, model_privacy:is_only_phone(?UID1, ?PHONE2)),
    ?assertEqual(true, model_privacy:is_only_phone(?UID1, ?PHONE3)),

    ?assertEqual(ok, model_privacy:remove_user(?UID1, ?PHONE1)),
    ?assertEqual({ok, []}, model_privacy:get_only_phones(?UID1)).


except_list_phone_test() ->
    setup(),
    ?assertEqual(ok, model_privacy:add_except_uid(?UID1, ?UID2)),
    ?assertEqual({ok, [?UID2]}, model_privacy:get_except_uids(?UID1)),
    ?assertEqual({ok, []}, model_privacy:get_except_phones(?UID1)),
    ?assertEqual(false, model_privacy:is_except_phone(?UID1, ?PHONE2)),
    ?assertEqual(ok, model_privacy:add_except_phone(?UID1, ?PHONE2)),
    ?assertEqual({ok, [?PHONE2]}, model_privacy:get_except_phones(?UID1)),
    ?assertEqual(true, model_privacy:is_except_phone(?UID1, ?PHONE2)),
    ?assertEqual(ok, model_privacy:remove_except_phone(?UID1, ?PHONE2)),
    ?assertEqual({ok, []}, model_privacy:get_except_phones(?UID1)),
    %% Setting phones: should clear uids list.
    ?assertEqual({ok, []}, model_privacy:get_except_phones(?UID1)),

    ?assertEqual(ok, model_privacy:add_except_phones(?UID1, [])),
    ?assertEqual(ok, model_privacy:add_except_phones(?UID1, [?PHONE2, ?PHONE3])),
    ?assertEqual({ok, [?PHONE2, ?PHONE3]}, model_privacy:get_except_phones(?UID1)),
    ?assertEqual(true, model_privacy:is_except_phone(?UID1, ?PHONE2)),
    ?assertEqual(true, model_privacy:is_except_phone(?UID1, ?PHONE3)),

    ?assertEqual(ok, model_privacy:remove_user(?UID1, ?PHONE1)),
    ?assertEqual({ok, []}, model_privacy:get_except_phones(?UID1)).


mute_phone_test() ->
    setup(),
    ?assertEqual(ok, model_privacy:mute_uid(?UID1, ?UID2)),
    ?assertEqual({ok, [?UID2]}, model_privacy:get_mutelist_uids(?UID1)),
    ?assertEqual({ok, []}, model_privacy:get_mutelist_phones(?UID1)),
    ?assertEqual(ok, model_privacy:mute_phone(?UID1, ?PHONE2)),
    ?assertEqual({ok, [?PHONE2]}, model_privacy:get_mutelist_phones(?UID1)),
    ?assertEqual(ok, model_privacy:unmute_phone(?UID1, ?PHONE2)),
    ?assertEqual({ok, []}, model_privacy:get_mutelist_phones(?UID1)),
    %% Setting phones: should clear uids list.
    ?assertEqual({ok, []}, model_privacy:get_mutelist_uids(?UID1)),

    ?assertEqual(ok, model_privacy:mute_phones(?UID1, [])),
    ?assertEqual(ok, model_privacy:mute_phones(?UID1, [?PHONE2, ?PHONE3])),
    ?assertEqual({ok, [?PHONE2, ?PHONE3]}, model_privacy:get_mutelist_phones(?UID1)),

    ?assertEqual(ok, model_privacy:remove_user(?UID1, ?PHONE1)),
    ?assertEqual({ok, []}, model_privacy:get_mutelist_phones(?UID1)).


block_phone1_test() ->
    setup(),
    ?assertEqual(ok, model_privacy:block_uid(?UID1, ?UID2)),
    ?assertEqual(ok, model_privacy:block_uid(?UID2, ?UID1)),
    ?assertEqual({ok, [?UID2]}, model_privacy:get_blocked_uids(?UID1)),
    ?assertEqual({ok, [?UID1]}, model_privacy:get_blocked_uids(?UID2)),
    ?assertEqual({ok, [?UID2]}, model_privacy:get_blocked_by_uids(?UID1)),
    ?assertEqual({ok, [?UID1]}, model_privacy:get_blocked_by_uids(?UID2)),
    %% New keys for old users should work fine.
    ?assertEqual({ok, [?UID2]}, model_privacy:get_blocked_uids2(?UID1)),
    ?assertEqual({ok, [?UID1]}, model_privacy:get_blocked_by_uids2(?UID2)),
    ?assertEqual({ok, [?UID1]}, model_privacy:get_blocked_uids2(?UID2)),
    ?assertEqual({ok, [?UID2]}, model_privacy:get_blocked_by_uids2(?UID1)),
    ?assertEqual(true, model_privacy:is_blocked2(?UID1, ?UID2)),
    ?assertEqual(true, model_privacy:is_blocked_by2(?UID2, ?UID1)),

    ?assertEqual(ok, model_privacy:unblock_uid(?UID1, ?UID2)),
    ?assertEqual({ok, []}, model_privacy:get_blocked_uids2(?UID1)),
    ?assertEqual(false, model_privacy:is_blocked2(?UID1, ?UID2)),
    ?assertEqual(false, model_privacy:is_blocked_by2(?UID2, ?UID1)),
    ?assertEqual(ok, model_privacy:block_phone(?UID1, ?PHONE2)),
    ?assertEqual({ok, [?PHONE2]}, model_privacy:get_blocked_phones(?UID1)),
    ?assertEqual({ok, [?UID2]}, model_privacy:get_blocked_uids2(?UID1)),
    ?assertEqual(true, model_privacy:is_blocked2(?UID1, ?UID2)),
    ?assertEqual(true, model_privacy:is_blocked_by2(?UID2, ?UID1)),
    %% Old keys should return empty
    ?assertEqual({ok, []}, model_privacy:get_blocked_uids(?UID1)),
    ?assertEqual({ok, []}, model_privacy:get_blocked_by_uids(?UID2)),
    %% New keys should work fine
    ?assertEqual({ok, [?UID2]}, model_privacy:get_blocked_uids2(?UID1)),
    ?assertEqual({ok, [?UID1]}, model_privacy:get_blocked_by_uids2(?UID2)),
    %% New keys for old users should also work fine.
    ?assertEqual({ok, [?UID1]}, model_privacy:get_blocked_uids2(?UID2)),
    ?assertEqual({ok, [?UID2]}, model_privacy:get_blocked_by_uids2(?UID1)),

    ?assertEqual(ok, model_privacy:unblock_phone(?UID1, ?PHONE2)),
    ?assertEqual({ok, []}, model_privacy:get_blocked_phones(?UID1)),
    ?assertEqual({ok, []}, model_privacy:get_blocked_uids2(?UID1)),
    ?assertEqual({ok, []}, model_privacy:get_blocked_by_uids2(?UID2)),
    ?assertEqual({ok, []}, model_privacy:get_blocked_by_uids_phone(?PHONE2)),

    ?assertEqual(ok, model_privacy:block_phones(?UID1, [])),
    ?assertEqual(ok, model_privacy:block_phones(?UID1, [?PHONE2, ?PHONE3])),
    ?assertEqual({ok, [?PHONE2, ?PHONE3]}, model_privacy:get_blocked_phones(?UID1)),
    ?assertEqual({ok, [?UID2]}, model_privacy:get_blocked_uids2(?UID1)),
    ?assertEqual({ok, [?UID1]}, model_privacy:get_blocked_by_uids2(?UID2)),

    ?assertEqual(true, model_privacy:is_blocked2(?UID1, ?UID2)),
    ?assertEqual(true, model_privacy:is_blocked_by2(?UID2, ?UID1)),

    ?assertEqual(ok, model_privacy:remove_user(?UID2, ?PHONE2)),
    ?assertEqual({ok, []}, model_privacy:get_blocked_uids2(?UID1)),
    ?assertEqual({ok, [?PHONE2, ?PHONE3]}, model_privacy:get_blocked_phones(?UID1)),
    ok.


block_phone2_test() ->
    setup(),
    ?assertEqual(ok, model_privacy:block_phones(?UID1, [])),
    ?assertEqual(ok, model_privacy:block_phones(?UID1, [?PHONE2, ?PHONE3])),
    ?assertEqual({ok, [?PHONE2, ?PHONE3]}, model_privacy:get_blocked_phones(?UID1)),
    ?assertEqual({ok, [?UID2]}, model_privacy:get_blocked_uids2(?UID1)),
    ?assertEqual({ok, [?UID1]}, model_privacy:get_blocked_by_uids2(?UID2)),

    ok = model_phone:add_phone(?UID3, ?HALLOAPP, ?PHONE3),
    ?assertEqual(ok, model_privacy:register_user(?UID3, ?PHONE3)),
    ?assertEqual({ok, [?UID2, ?UID3]}, model_privacy:get_blocked_uids2(?UID1)),
    ?assertEqual({ok, [?UID1]}, model_privacy:get_blocked_by_uids2(?UID3)),

    ?assertEqual(true, model_privacy:is_blocked2(?UID1, ?UID2)),
    ?assertEqual(true, model_privacy:is_blocked_by2(?UID2, ?UID1)),
    ?assertEqual(true, model_privacy:is_blocked2(?UID1, ?UID3)),
    ?assertEqual(true, model_privacy:is_blocked_by2(?UID3, ?UID1)),

    ?assertEqual(ok, model_privacy:remove_user(?UID2, ?PHONE2)),
    ?assertEqual({ok, [?UID3]}, model_privacy:get_blocked_uids2(?UID1)),
    ?assertEqual({ok, [?PHONE2, ?PHONE3]}, model_privacy:get_blocked_phones(?UID1)),
    ok.


% block_perf_test() ->
%     tutil:perf(
%         1000,
%         fun() -> setup() end,
%         fun() -> ok = model_privacy:block_uids(?UID1, [?UID2, ?UID2, ?UID2, ?UID3, ?UID3]) end
%     ).


% unblock_perf_test() ->
%     tutil:perf(
%         1000,
%         fun() -> setup() end, 
%         fun() -> ok = model_privacy:unblock_uids(?UID1, [?UID2, ?UID2, ?UID2, ?UID3, ?UID3]) end
%     ).

