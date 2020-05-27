%%%-------------------------------------------------------------------
%%% File: model_whisper_keys_tests.erl
%%% Copyright (C) 2020, Halloapp Inc.
%%%
%%%-------------------------------------------------------------------
-module(model_whisper_keys_tests).
-author('murali').

-include("whisper.hrl").
-include_lib("eunit/include/eunit.hrl").

-define(UID1, <<"1000000000376503286">>).
-define(UID2, <<"1000000000456112358">>).
-define(UID3, <<"1000000000751427741">>).

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

-define(UID1_KEY_SET1, #user_whisper_key_set{uid = ?UID1,
        identity_key = ?IDENTITY_KEY1, signed_key = ?SIGNED_KEY1, one_time_key = ?OTP1_KEY1}).
-define(UID1_KEY_SET2, #user_whisper_key_set{uid = ?UID1,
        identity_key = ?IDENTITY_KEY1, signed_key = ?SIGNED_KEY1, one_time_key = ?OTP1_KEY2}).
-define(UID1_KEY_SET3, #user_whisper_key_set{uid = ?UID1,
        identity_key = ?IDENTITY_KEY1, signed_key = ?SIGNED_KEY1, one_time_key = ?OTP1_KEY3}).
-define(UID1_KEY_SET4, #user_whisper_key_set{uid = ?UID1,
        identity_key = ?IDENTITY_KEY1, signed_key = ?SIGNED_KEY1, one_time_key = ?OTP1_KEY4}).
-define(UID1_KEY_SET5, #user_whisper_key_set{uid = ?UID1,
        identity_key = ?IDENTITY_KEY1, signed_key = ?SIGNED_KEY1, one_time_key = ?OTP1_KEY5}).
-define(UID1_KEY_SET6, #user_whisper_key_set{uid = ?UID1,
        identity_key = ?IDENTITY_KEY1, signed_key = ?SIGNED_KEY1, one_time_key = undefined}).

-define(UID2_KEY_SET1, #user_whisper_key_set{uid = ?UID2,
        identity_key = ?IDENTITY_KEY2, signed_key = ?SIGNED_KEY2, one_time_key = ?OTP2_KEY1}).
-define(UID2_KEY_SET2, #user_whisper_key_set{uid = ?UID2,
        identity_key = ?IDENTITY_KEY2, signed_key = ?SIGNED_KEY2, one_time_key = ?OTP2_KEY2}).
-define(UID2_KEY_SET3, #user_whisper_key_set{uid = ?UID2,
        identity_key = ?IDENTITY_KEY2, signed_key = ?SIGNED_KEY2, one_time_key = ?OTP2_KEY3}).
-define(UID2_KEY_SET4, #user_whisper_key_set{uid = ?UID2,
        identity_key = ?IDENTITY_KEY2, signed_key = ?SIGNED_KEY2, one_time_key = undefined}).


setup() ->
    redis_sup:start_link(),
    clear(),
    ok.


clear() ->
    ok = gen_server:cast(redis_whisper_client, flushdb).


key_test() ->
    ?assertEqual(<<"wk:{1}">>, model_whisper_keys:whisper_key(<<"1">>)),
    ?assertEqual(<<"wotp:{1}">>, model_whisper_keys:otp_key(<<"1">>)),
    ?assertEqual(<<"wsub:{1}">>, model_whisper_keys:subcribers_key(<<"1">>)).


setup_keys_test() ->
    setup(),
    ?assertEqual({ok, undefined}, model_whisper_keys:get_key_set(?UID1)),
    ?assertEqual(ok, model_whisper_keys:set_keys(?UID1, ?IDENTITY_KEY1, ?SIGNED_KEY1,
            [?OTP1_KEY1, ?OTP1_KEY2, ?OTP1_KEY3])),
    ?assertEqual({ok, ?UID1_KEY_SET1}, model_whisper_keys:get_key_set(?UID1)),
    ?assertEqual({ok, ?UID1_KEY_SET2}, model_whisper_keys:get_key_set(?UID1)),
    ?assertEqual({ok, ?UID1_KEY_SET3}, model_whisper_keys:get_key_set(?UID1)),
    ?assertEqual({ok, ?UID1_KEY_SET6}, model_whisper_keys:get_key_set(?UID1)),
    ?assertEqual(ok, model_whisper_keys:add_otp_keys(?UID1, [?OTP1_KEY4, ?OTP1_KEY5])),
    ?assertEqual({ok, ?UID1_KEY_SET4}, model_whisper_keys:get_key_set(?UID1)),
    ?assertEqual({ok, ?UID1_KEY_SET5}, model_whisper_keys:get_key_set(?UID1)),
    ?assertEqual({ok, ?UID1_KEY_SET6}, model_whisper_keys:get_key_set(?UID1)),

    ?assertEqual({ok, undefined}, model_whisper_keys:get_key_set(?UID2)),
    ?assertEqual(ok, model_whisper_keys:set_keys(?UID2, ?IDENTITY_KEY2, ?SIGNED_KEY2,
            [?OTP2_KEY1, ?OTP2_KEY2, ?OTP2_KEY3])),
    ?assertEqual({ok, ?UID2_KEY_SET1}, model_whisper_keys:get_key_set(?UID2)),
    ?assertEqual({ok, ?UID2_KEY_SET2}, model_whisper_keys:get_key_set(?UID2)),
    ?assertEqual({ok, ?UID2_KEY_SET3}, model_whisper_keys:get_key_set(?UID2)),
    ?assertEqual({ok, ?UID2_KEY_SET4}, model_whisper_keys:get_key_set(?UID2)).



count_otp_key_test() ->
    setup(),
    ?assertEqual({ok, 0}, model_whisper_keys:count_otp_keys(?UID1)),
    ?assertEqual(ok, model_whisper_keys:set_keys(?UID1, ?IDENTITY_KEY1, ?SIGNED_KEY1,
            [?OTP1_KEY1, ?OTP1_KEY2, ?OTP1_KEY3])),
    ?assertEqual({ok, 3}, model_whisper_keys:count_otp_keys(?UID1)),
    ?assertEqual({ok, ?UID1_KEY_SET1}, model_whisper_keys:get_key_set(?UID1)),
    ?assertEqual({ok, 2}, model_whisper_keys:count_otp_keys(?UID1)),
    ?assertEqual({ok, ?UID1_KEY_SET2}, model_whisper_keys:get_key_set(?UID1)),
    ?assertEqual({ok, 1}, model_whisper_keys:count_otp_keys(?UID1)),
    ?assertEqual({ok, ?UID1_KEY_SET3}, model_whisper_keys:get_key_set(?UID1)),
    ?assertEqual({ok, 0}, model_whisper_keys:count_otp_keys(?UID1)),
    ?assertEqual(ok, model_whisper_keys:add_otp_keys(?UID1, [?OTP1_KEY4, ?OTP1_KEY5])),
    ?assertEqual({ok, 2}, model_whisper_keys:count_otp_keys(?UID1)),
    ?assertEqual({ok, ?UID1_KEY_SET4}, model_whisper_keys:get_key_set(?UID1)),
    ?assertEqual({ok, 1}, model_whisper_keys:count_otp_keys(?UID1)),
    ?assertEqual({ok, ?UID1_KEY_SET5}, model_whisper_keys:get_key_set(?UID1)),
    ?assertEqual({ok, 0}, model_whisper_keys:count_otp_keys(?UID1)),
    ?assertEqual({ok, ?UID1_KEY_SET6}, model_whisper_keys:get_key_set(?UID1)).


count_otp_key2_test() ->
    setup(),
    ?assertEqual({ok, 0}, model_whisper_keys:count_otp_keys(?UID1)),
    ?assertEqual({ok, 0}, model_whisper_keys:count_otp_keys(?UID2)),
    ?assertEqual(ok, model_whisper_keys:set_keys(?UID1, ?IDENTITY_KEY1, ?SIGNED_KEY1,
            [?OTP1_KEY1, ?OTP1_KEY2, ?OTP1_KEY3])),
    ?assertEqual(ok, model_whisper_keys:set_keys(?UID2, ?IDENTITY_KEY2, ?SIGNED_KEY2,
            [?OTP2_KEY1, ?OTP2_KEY2])),
    ?assertEqual({ok, 3}, model_whisper_keys:count_otp_keys(?UID1)),
    ?assertEqual({ok, 2}, model_whisper_keys:count_otp_keys(?UID2)).


subscriber_key_test() ->
    setup(),
    ?assertEqual({ok, []}, model_whisper_keys:get_all_key_subscribers(?UID1)),
    ?assertEqual(ok, model_whisper_keys:add_key_subscriber(?UID1, ?UID2)),
    ?assertEqual({ok, [?UID2]}, model_whisper_keys:get_all_key_subscribers(?UID1)),
    ?assertEqual(ok, model_whisper_keys:remove_key_subscriber(?UID1, ?UID2)),
    ?assertEqual({ok, []}, model_whisper_keys:get_all_key_subscribers(?UID1)),

    ?assertEqual(ok, model_whisper_keys:add_key_subscriber(?UID1, ?UID2)),
    ?assertEqual(ok, model_whisper_keys:add_key_subscriber(?UID1, ?UID3)),
    {ok, Res} = model_whisper_keys:get_all_key_subscribers(?UID1),
    ?assertEqual(sets:from_list(Res), sets:from_list([?UID2, ?UID3])),
    ?assertEqual(ok, model_whisper_keys:remove_all_key_subscribers(?UID1)),
    ?assertEqual({ok, []}, model_whisper_keys:get_all_key_subscribers(?UID1)).




