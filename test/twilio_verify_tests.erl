%%%-------------------------------------------------------------------
%%% File: twilio_verify_tests.erl
%%% Copyright (C) 2021, Halloapp Inc.
%%%
%%%-------------------------------------------------------------------
-module(twilio_verify_tests).
-author("michelle").

-include_lib("eunit/include/eunit.hrl").
-include("sms.hrl").

-define(PHONE, <<"14703381473">>).
-define(CODE1, <<"478146">>).
-define(CODE2, <<"285789">>).
-define(CODE3, <<"538213">>).
-define(GATEWAY1, gw1).
-define(GATEWAY2, twilio_verify).
-define(SMSID1, <<"smsid1">>).
-define(SMSID2, <<"smsid2">>).
-define(SMSID3, <<"smsid3">>).


setup() ->
    tutil:setup(),
    ha_redis:start(),
    clear(),
    ok.


clear() ->
    tutil:cleardb(redis_phone).


get_latest_twilio_verify_test() ->
    setup(),
    {ok, AttemptId, _} = model_phone:add_sms_code2(?PHONE, ?CODE1),
    ok = model_phone:add_gateway_response(?PHONE, AttemptId,
        #gateway_response{gateway=?GATEWAY1, gateway_id=?SMSID1}),
    {ok, VerifyList} = model_phone:get_all_verification_info(?PHONE),
    [] = twilio_verify:get_latest_verify_info(VerifyList),
    timer:sleep(timer:seconds(1)),
    {ok, AttemptId2, _} = model_phone:add_sms_code2(?PHONE, ?CODE2),
    ok = model_phone:add_gateway_response(?PHONE, AttemptId2,
        #gateway_response{gateway=?GATEWAY2, gateway_id=?SMSID2}),
    timer:sleep(timer:seconds(1)),
    {ok, AttemptId3, _} = model_phone:add_sms_code2(?PHONE, ?CODE3),
    ok = model_phone:add_gateway_response(?PHONE, AttemptId3,
        #gateway_response{gateway=?GATEWAY2, gateway_id=?SMSID3}),
    {ok, VerifyList2} = model_phone:get_all_verification_info(?PHONE),
    [AttemptId3, ?SMSID3] = twilio_verify:get_latest_verify_info(VerifyList2).

