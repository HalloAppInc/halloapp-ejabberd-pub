%%%-------------------------------------------------------------------
%%% File: model_phone_tests.erl
%%% Copyright (C) 2020, Halloapp Inc.
%%%
%%%-------------------------------------------------------------------
-module(model_phone_tests).
-author("murali").

-include_lib("eunit/include/eunit.hrl").
-include_lib("sms.hrl").
-include("monitor.hrl").
-include("ha_types.hrl").

-define(PHONE1, <<"14703381473">>).
-define(UID1, <<"1000000000376503286">>).
-define(PHONE2, <<"16504443079">>).
-define(UID2, <<"1000000000489601473">>).
-define(CODE1, <<"478146">>).
-define(TIME1, 1533626578).
-define(CODE2, <<"285789">>).
-define(TIME2, 1586907979).
-define(CODE3, <<"538213">>).
-define(SENDER, <<"api.halloapp.net">>).
-define(RECEIPT, <<"{\"name\": \"value\"}">>).
-define(TTL_24HR_SEC, 86400).
-define(DELAY_SEC, 10).
-define(SMSID1, <<"smsid1">>).
-define(SMSID2, <<"smsid2">>).
-define(SMSID3, <<"smsid3">>).
-define(STATUS, sent).
-define(GATEWAY1, gw1).
-define(GATEWAY2, gw2).
-define(GATEWAY3, twilio_verify).
-define(CALLBACK_STATUS1, delivered).
-define(CALLBACK_STATUS2, failed).
-define(PRICE1, 0.07).
-define(PRICE2, 0.005).
-define(CURRENCY1, <<"USD">>).
-define(CURRENCY2, <<"USD">>).

-define(PHONE_PATTERN1, <<"147033814">>).
-define(PHONE_PATTERN2, <<"165044430">>).

-define(STATIC_KEY1, <<"1static_key1">>).
-define(STATIC_KEY2, <<"2static_key2">>).

-define(PHONE_CC1, <<"NI">>).
-define(PHONE_CC2, <<"ID">>).

-define(HASHCASH_CHALLENGE1, <<"hashcash1">>).
-define(HASHCASH_CHALLENGE2, <<"hashcash2">>).

setup() ->
    tutil:setup(),
    ha_redis:start(),
    clear(),
    ok.


clear() ->
    tutil:cleardb(redis_phone).


phone_key_test() ->
    setup(),
    % TODO: This is what we wanted
%%    ?assertEqual(
%%        <<<<"pho:{5}">>/binary, ?PHONE1/binary>>,
%%        model_phone:phone_key(?PHONE1)),
    ?assertEqual(
        <<<<"pho:{">>/binary, 5/integer, <<"}:">>/binary, ?PHONE1/binary>>,
        model_phone:phone_key(?PHONE1, ?HALLOAPP)),
    ?assertEqual(
        <<<<"pho:{">>/binary, 2/integer, <<"}:">>/binary, ?PHONE2/binary>>,
        model_phone:phone_key(?PHONE2, ?HALLOAPP)),
    ?assertEqual(
        <<<<"phka:{">>/binary, 5/integer, <<"}:">>/binary, ?PHONE1/binary>>,
        model_phone:phone_key(?PHONE1, ?KATCHUP)),
    ?assertEqual(
        <<<<"phka:{">>/binary, 2/integer, <<"}:">>/binary, ?PHONE2/binary>>,
        model_phone:phone_key(?PHONE2, ?KATCHUP)),
    ok.


add_sms_gateway_response_test() ->
    setup(),
    {ok, []} = model_phone:get_verification_attempt_list(?PHONE1, ?HALLOAPP),
    {ok, []} = model_phone:get_all_verification_info(?PHONE1, ?HALLOAPP),
    {ok, AttemptId, _} = model_phone:add_sms_code2(?PHONE1, ?HALLOAPP, ?CODE1),
    ok = model_phone:add_gateway_response(?PHONE1, ?HALLOAPP, AttemptId,
        #gateway_response{gateway=?GATEWAY1, gateway_id=?SMSID1, status=?STATUS, response=?RECEIPT}),
    {ok, ?CODE1} = model_phone:get_sms_code2(?PHONE1, ?HALLOAPP, AttemptId),
    {ok, [{AttemptId, Ts}]} = model_phone:get_verification_attempt_list(?PHONE1, ?HALLOAPP),
    %% Sleep for 1 seconds just so the timestamp for Attempt1 and Attemp2 is different.
    timer:sleep(timer:seconds(1)),
    {ok, AttemptId2, _} = model_phone:add_sms_code2(?PHONE1, ?HALLOAPP, ?CODE2),
    {ok, [{AttemptId, Ts}, {AttemptId2, Ts2}]} = model_phone:get_verification_attempt_list(?PHONE1, ?HALLOAPP),
    ok = model_phone:add_gateway_response(?PHONE1, ?HALLOAPP, AttemptId2,
        #gateway_response{gateway=?GATEWAY2, gateway_id=?SMSID2, status=?STATUS, response=?RECEIPT}),
    timer:sleep(timer:seconds(1)),
    {ok, AttemptId3, _} = model_phone:add_sms_code2(?PHONE1, ?HALLOAPP, ?CODE3),
    {ok, [{AttemptId, Ts}, {AttemptId2, Ts2}, {AttemptId3, Ts3}]} = model_phone:get_verification_attempt_list(?PHONE1, ?HALLOAPP),
    ok = model_phone:add_gateway_response(?PHONE1, ?HALLOAPP, AttemptId3,
        #gateway_response{gateway=?GATEWAY3, gateway_id=?SMSID3, status=?STATUS, response=?RECEIPT}),
    {ok, ?CODE1} = model_phone:get_sms_code2(?PHONE1, ?HALLOAPP, AttemptId),
    {ok, ?CODE2} = model_phone:get_sms_code2(?PHONE1, ?HALLOAPP, AttemptId2),
    {ok, ?CODE3} = model_phone:get_sms_code2(?PHONE1, ?HALLOAPP, AttemptId3),
    {ok, [#verification_info{attempt_id = AttemptId, code = ?CODE1, sid = ?SMSID1},
        #verification_info{attempt_id = AttemptId2, code = ?CODE2, sid = ?SMSID2},
        #verification_info{attempt_id = AttemptId3, code = ?CODE3, sid = ?SMSID3}]}
            = model_phone:get_all_verification_info(?PHONE1, ?HALLOAPP),
    ok = model_phone:add_gateway_callback_info(
        #gateway_response{gateway=?GATEWAY1, gateway_id=?SMSID1, status=?CALLBACK_STATUS1,
            price=?PRICE1, currency=?CURRENCY1}),
    %% Sleep for 1 seconds just so the timestamp for Attempt1 and Attemp2 is different.
    timer:sleep(timer:seconds(1)),
    ok = model_phone:add_gateway_callback_info(
        #gateway_response{gateway=?GATEWAY2, gateway_id=?SMSID2, status=?CALLBACK_STATUS2,
            price=?PRICE2, currency=?CURRENCY2}),
    timer:sleep(timer:seconds(1)),
    ok = model_phone:add_gateway_callback_info(
        #gateway_response{gateway=?GATEWAY3, gateway_id=?SMSID3, status=?CALLBACK_STATUS1,
            price=?PRICE2}),
    {ok, ?CALLBACK_STATUS1} = model_phone:get_gateway_response_status(?PHONE1, ?HALLOAPP, AttemptId),
    {ok, ?CALLBACK_STATUS2} = model_phone:get_gateway_response_status(?PHONE1, ?HALLOAPP, AttemptId2),
    {ok, ?CALLBACK_STATUS1} = model_phone:get_gateway_response_status(?PHONE1, ?HALLOAPP, AttemptId3),
    AllResponses = [#gateway_response{gateway=?GATEWAY1, method=sms, status=?CALLBACK_STATUS1,
                                      verified=false, attempt_id=AttemptId, attempt_ts=Ts, valid = true},
                    #gateway_response{gateway=?GATEWAY2, method=sms, status=?CALLBACK_STATUS2,
                                      verified=false, attempt_id=AttemptId2, attempt_ts=Ts2, valid = true},
                    #gateway_response{gateway=?GATEWAY3, method=sms, status=?CALLBACK_STATUS1,
                                        verified=false, attempt_id=AttemptId3, attempt_ts=Ts3, valid = true}],
    {ok, []} = model_phone:get_all_gateway_responses(?PHONE2, ?HALLOAPP),
    {ok, AllResponses} = model_phone:get_all_gateway_responses(?PHONE1, ?HALLOAPP),
    ok = model_phone:add_verification_success(?PHONE1, ?HALLOAPP, AttemptId),
    true = model_phone:get_verification_success(?PHONE1, ?HALLOAPP, AttemptId),
    false = model_phone:get_verification_success(?PHONE1, ?HALLOAPP, AttemptId2),
    false = model_phone:get_verification_success(?PHONE1, ?HALLOAPP, AttemptId3),
    #gateway_response{gateway=?GATEWAY2, method=sms, status=?CALLBACK_STATUS2, verified=false} =
          model_phone:get_verification_attempt_summary(?PHONE1, ?HALLOAPP, AttemptId2),
    ok = model_phone:add_verification_success(?PHONE1, ?HALLOAPP, AttemptId2),
    true = model_phone:get_verification_success(?PHONE1, ?HALLOAPP, AttemptId2),
    #gateway_response{gateway=?GATEWAY2, method=sms, status=?CALLBACK_STATUS2, verified=true} =
          model_phone:get_verification_attempt_summary(?PHONE1, ?HALLOAPP, AttemptId2),
    ok = model_phone:add_verification_success(?PHONE1, ?HALLOAPP, AttemptId3),
    true = model_phone:get_verification_success(?PHONE1, ?HALLOAPP, AttemptId3),
    #gateway_response{gateway=?GATEWAY3, method=sms, status=?CALLBACK_STATUS1, verified=true} =  
        model_phone:get_verification_attempt_summary(?PHONE1, ?HALLOAPP, AttemptId3).


delete_sms_code2_test() ->
    setup(),
    {ok, []} = model_phone:get_verification_attempt_list(?PHONE1, ?KATCHUP),
    {ok, []} = model_phone:get_all_verification_info(?PHONE1, ?KATCHUP),
    {ok, _, _} = model_phone:add_sms_code2(?PHONE1, ?KATCHUP, ?CODE1),
    {ok, _, _} = model_phone:add_sms_code2(?PHONE1, ?KATCHUP, ?CODE2),
    ok = model_phone:delete_sms_code2(?PHONE1, ?KATCHUP),
    {ok, []} = model_phone:get_verification_attempt_list(?PHONE1, ?KATCHUP),
    {ok, []} = model_phone:get_all_verification_info(?PHONE1, ?KATCHUP).


add_phone_test() ->
    setup(),
    %% Test pho:{phone}
    #{} = model_phone:get_uids([], ?KATCHUP),
    ok = model_phone:add_phone(?PHONE1, ?KATCHUP, ?UID1),
    ok = model_phone:add_phone(?PHONE2, ?KATCHUP, ?UID2),
    {ok, ?UID1} = model_phone:get_uid(?PHONE1, ?KATCHUP),
    {ok, ?UID2} = model_phone:get_uid(?PHONE2, ?KATCHUP),
    ResMap = #{?PHONE1 => ?UID1, ?PHONE2 => ?UID2},
    ResMap = model_phone:get_uids([?PHONE1, ?PHONE2], ?KATCHUP),
    ResMap = model_phone:get_uids([?PHONE2, ?PHONE1], ?KATCHUP),
    #{} = model_phone:get_uids([?PHONE1, ?PHONE2], ?HALLOAPP).


delete_phone_test() ->
    setup(),
    %% Test pho:{phone}
    ok = model_phone:add_phone(?PHONE1, ?KATCHUP, ?UID1),
    ok = model_phone:add_phone(?PHONE2, ?KATCHUP, ?UID2),
    Res1Map = #{?PHONE1 => ?UID1, ?PHONE2 => ?UID2},
    Res1Map = model_phone:get_uids([?PHONE1, ?PHONE2], ?KATCHUP),
    ok = model_phone:delete_phone(?PHONE1, ?KATCHUP),
    Res2Map = #{?PHONE2 => ?UID2},
    Res2Map = model_phone:get_uids([?PHONE1, ?PHONE2], ?KATCHUP).

phone_pattern_test() ->
    setup(),
    ok = model_phone:delete_phone_pattern(?PHONE_PATTERN1),
    ok = model_phone:delete_phone_pattern(?PHONE_PATTERN2),
    {ok, {undefined, undefined}} = model_phone:get_phone_pattern_info(?PHONE_PATTERN1),
    {ok, {undefined, undefined}} = model_phone:get_phone_pattern_info(?PHONE_PATTERN2),
    ok = model_phone:add_phone_pattern(?PHONE_PATTERN1, ?TIME1),
    {ok, {1, ?TIME1}} = model_phone:get_phone_pattern_info(?PHONE_PATTERN1),
    {ok, {undefined, undefined}} = model_phone:get_phone_pattern_info(?PHONE_PATTERN2),
    ok = model_phone:add_phone_pattern(?PHONE_PATTERN1, ?TIME2),
    {ok, {2, ?TIME2}} = model_phone:get_phone_pattern_info(?PHONE_PATTERN1),
    ok = model_phone:add_phone_pattern(?PHONE_PATTERN2, ?TIME1),
    {ok, {1, ?TIME1}} = model_phone:get_phone_pattern_info(?PHONE_PATTERN2),
    ok = model_phone:add_phone_pattern(?PHONE_PATTERN2, ?TIME2),
    {ok, {2, ?TIME2}} = model_phone:get_phone_pattern_info(?PHONE_PATTERN2),
    ok = model_phone:delete_phone_pattern(?PHONE_PATTERN1),
    ok = model_phone:delete_phone_pattern(?PHONE_PATTERN2),
    {ok, {undefined, undefined}} = model_phone:get_phone_pattern_info(?PHONE_PATTERN1),
    {ok, {undefined, undefined}} = model_phone:get_phone_pattern_info(?PHONE_PATTERN2).

remote_static_key_test() ->
    setup(),
    ok = model_phone:delete_static_key(?STATIC_KEY1),
    ok = model_phone:delete_static_key(?STATIC_KEY2),
    {ok, {undefined, undefined}} = model_phone:get_static_key_info(?STATIC_KEY1),
    {ok, {undefined, undefined}} = model_phone:get_static_key_info(?STATIC_KEY2),
    ok = model_phone:add_static_key(?STATIC_KEY1, ?TIME1),
    {ok, {1, ?TIME1}} = model_phone:get_static_key_info(?STATIC_KEY1),
    {ok, {undefined, undefined}} = model_phone:get_static_key_info(?STATIC_KEY2),
    ok = model_phone:add_static_key(?STATIC_KEY1, ?TIME2),
    {ok, {2, ?TIME2}} = model_phone:get_static_key_info(?STATIC_KEY1),
    ok = model_phone:add_static_key(?STATIC_KEY2, ?TIME1),
    {ok, {1, ?TIME1}} = model_phone:get_static_key_info(?STATIC_KEY2),
    ok = model_phone:add_static_key(?STATIC_KEY2, ?TIME2),
    {ok, {2, ?TIME2}} = model_phone:get_static_key_info(?STATIC_KEY2),
    ok = model_phone:delete_static_key(?STATIC_KEY1),
    ok = model_phone:delete_static_key(?STATIC_KEY2),
    {ok, {undefined, undefined}} = model_phone:get_static_key_info(?STATIC_KEY1),
    {ok, {undefined, undefined}} = model_phone:get_static_key_info(?STATIC_KEY2).

phone_cc_test() ->
    setup(),
    ok = model_phone:delete_phone_cc(?PHONE_CC1),
    ok = model_phone:delete_phone_cc(?PHONE_CC2),
    {ok, {undefined, undefined}} = model_phone:get_phone_cc_info(?PHONE_CC1),
    {ok, {undefined, undefined}} = model_phone:get_phone_cc_info(?PHONE_CC2),
    ok = model_phone:add_phone_cc(?PHONE_CC1, ?TIME1),
    {ok, {1, ?TIME1}} = model_phone:get_phone_cc_info(?PHONE_CC1),
    {ok, {undefined, undefined}} = model_phone:get_phone_cc_info(?PHONE_CC2),
    ok = model_phone:add_phone_cc(?PHONE_CC1, ?TIME2),
    {ok, {2, ?TIME2}} = model_phone:get_phone_cc_info(?PHONE_CC1),
    ok = model_phone:add_phone_cc(?PHONE_CC2, ?TIME1),
    {ok, {1, ?TIME1}} = model_phone:get_phone_cc_info(?PHONE_CC2),
    ok = model_phone:add_phone_cc(?PHONE_CC2, ?TIME2),
    {ok, {2, ?TIME2}} = model_phone:get_phone_cc_info(?PHONE_CC2),
    ok = model_phone:delete_phone_cc(?PHONE_CC1),
    ok = model_phone:delete_phone_cc(?PHONE_CC2),
    {ok, {undefined, undefined}} = model_phone:get_phone_cc_info(?PHONE_CC1),
    {ok, {undefined, undefined}} = model_phone:get_phone_cc_info(?PHONE_CC2).

hashcash_challenge_test() ->
    setup(),
    not_found = model_phone:delete_hashcash_challenge(?HASHCASH_CHALLENGE1),
    not_found = model_phone:delete_hashcash_challenge(?HASHCASH_CHALLENGE2),
    ok = model_phone:add_hashcash_challenge(?HASHCASH_CHALLENGE1),
    not_found = model_phone:delete_hashcash_challenge(?HASHCASH_CHALLENGE2),
    ok = model_phone:add_hashcash_challenge(?HASHCASH_CHALLENGE2),
    ok = model_phone:delete_hashcash_challenge(?HASHCASH_CHALLENGE1),
    ok = model_phone:delete_hashcash_challenge(?HASHCASH_CHALLENGE2).

phone_attempt_test() ->
    setup(),
    Now = util:now(),
    ?assertEqual(0, model_phone:get_phone_code_attempts(?PHONE1, ?KATCHUP, Now)),
    ?assertEqual(1, model_phone:add_phone_code_attempt(?PHONE1, ?KATCHUP, Now)),
    ?assertEqual(2, model_phone:add_phone_code_attempt(?PHONE1, ?KATCHUP, Now)),
    ?assertEqual(3, model_phone:add_phone_code_attempt(?PHONE1, ?KATCHUP, Now)),
    ?assertEqual(0, model_phone:get_phone_code_attempts(?PHONE1, ?HALLOAPP, Now)),
    ?assertEqual(0, model_phone:get_phone_code_attempts(?PHONE2, ?HALLOAPP, Now)),
    ?assertEqual(0, model_phone:get_phone_code_attempts(?PHONE2, ?KATCHUP, Now)),

    % check things are expiring
    {ok, TTLBin} = model_phone:q(["TTL", model_phone:phone_attempt_key(?PHONE1, ?KATCHUP, Now)]),
    TTL = util_redis:decode_int(TTLBin),
    ?assertEqual(true, TTL > 0),
    % check things are expiring
    {ok, TTLBin2} = model_phone:q(["TTL", model_phone:phone_attempt_key(?PHONE1, ?HALLOAPP, Now)]),
    TTL2 = util_redis:decode_int(TTLBin2),
    ?assertEqual(true, TTL2 < 0),
    ok.

verify_ttl_test() ->
    % ensure that monitor phone correctly gets much shorter ttl than another phone.
    setup(),
    {ok, AttemptId1, _Timestamp1} = model_phone:add_sms_code2(?PHONE1, ?HALLOAPP, ?CODE1),
    {ok, AttemptId2, _Timestamp2} = model_phone:add_sms_code2(?MONITOR_PHONE, ?HALLOAPP, ?CODE1),
    [{ok, TTLBin1}, {ok, TTLBin2}] = model_phone:qmn([
        ["TTL", model_phone:verification_attempt_key(?PHONE1, ?HALLOAPP, AttemptId1)],
        ["TTL", model_phone:verification_attempt_key(?MONITOR_PHONE, ?HALLOAPP, AttemptId2)]]),
    TTL1 = util_redis:decode_int(TTLBin1),
    TTL2 = util_redis:decode_int(TTLBin2),
    ?assert(TTL1 > 10*TTL2),
    ok.


while(0, _F) -> ok;
while(N, F) ->
  erlang:apply(F, [N]),
  while(N -1, F).

perf_test() ->
  setup(),
  N = 10, %% Set to N=100000 to do
  while(N, fun(X) ->
            ok = model_phone:add_phone(integer_to_binary(X), ?HALLOAPP, integer_to_binary(X))
        end),
  Phones = [integer_to_binary(X) || X <- lists:seq(1,N,1)],
  PhonesUidsList = [{integer_to_binary(X), integer_to_binary(X)} || X <- lists:seq(1,N,1)],
  PhonesUidsMap = maps:from_list(PhonesUidsList),
  StartTime = os:system_time(microsecond),
  PhonesUidsMap = model_phone:get_uids(Phones, ?HALLOAPP),
  EndTime = os:system_time(microsecond),
  T = EndTime - StartTime,
  io:format("~w operations took ~w ms => ~f ops ", [N, T, N / (T / 1000000)]),
  {ok, T}.

