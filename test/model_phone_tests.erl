%%%-------------------------------------------------------------------
%%% File: model_phone_tests.erl
%%% Copyright (C) 2020, Halloapp Inc.
%%%
%%%-------------------------------------------------------------------
-module(model_phone_tests).
-author("murali").

-include_lib("eunit/include/eunit.hrl").
-include_lib("sms.hrl").

-define(PHONE1, <<"14703381473">>).
-define(UID1, <<"1000000000376503286">>).
-define(PHONE2, <<"16504443079">>).
-define(UID2, <<"1000000000489601473">>).
-define(CODE1, <<"478146">>).
-define(TIME1, 1533626578).
-define(CODE2, <<"285789">>).
-define(TIME2, 1586907979).
-define(SENDER, <<"api.halloapp.net">>).
-define(RECEIPT, <<"{\"name\": \"value\"}">>).
-define(TTL_24HR_SEC, 86400).
-define(DELAY_SEC, 10).
-define(SMSID1, <<"smsid1">>).
-define(SMSID2, <<"smsid2">>).
-define(STATUS, sent).
-define(GATEWAY1, gw1).
-define(GATEWAY2, gw2).
-define(CALLBACK_STATUS1, delivered).
-define(CALLBACK_STATUS2, failed).
-define(PRICE1, 0.07).
-define(PRICE2, 0.005).
-define(CURRENCY1, <<"USD">>).
-define(CURRENCY2, <<"USD">>).


setup() ->
    tutil:setup(),
    redis_sup:start_link(),
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
        model_phone:phone_key(?PHONE1)),
    ?assertEqual(
        <<<<"pho:{">>/binary, 2/integer, <<"}:">>/binary, ?PHONE2/binary>>,
        model_phone:phone_key(?PHONE2)),
    ok.

add_sms_code_test() ->
    setup(),
    %% Test cod:{phone}
    {ok, undefined} = model_phone:get_sms_code(?PHONE1),
    ok = model_phone:add_sms_code(?PHONE1, ?CODE1, ?TIME1, ?SENDER),
    {ok, undefined} = model_phone:get_sms_code_receipt(?PHONE1),
    {ok, ?CODE1} = model_phone:get_sms_code(?PHONE1).


add_sms_details_test() ->
    setup(),
    %% Test cod:{phone}
    {ok, undefined} = model_phone:get_sms_code(?PHONE1),
    {ok, undefined} = model_phone:get_sms_code(?PHONE2),
    ok = model_phone:add_sms_code(?PHONE1, ?CODE1, ?TIME1, ?SENDER),
    ok = model_phone:add_sms_code(?PHONE2, ?CODE2, ?TIME2, ?SENDER),
    {ok, undefined} = model_phone:get_sms_code_receipt(?PHONE1),
    {ok, undefined} = model_phone:get_sms_code_receipt(?PHONE2),
    ok = model_phone:add_sms_code_receipt(?PHONE1, ?RECEIPT),
    ok = model_phone:add_sms_code_receipt(?PHONE2, ?RECEIPT),
    {ok, ?CODE1} = model_phone:get_sms_code(?PHONE1),
    {ok, ?CODE2} = model_phone:get_sms_code(?PHONE2),
    {ok, ?TIME1} = model_phone:get_sms_code_timestamp(?PHONE1),
    {ok, ?TIME2} = model_phone:get_sms_code_timestamp(?PHONE2),
    {ok, ?SENDER} = model_phone:get_sms_code_sender(?PHONE1),
    {ok, ?SENDER} = model_phone:get_sms_code_sender(?PHONE2),
    {ok, ?RECEIPT} = model_phone:get_sms_code_receipt(?PHONE1),
    {ok, ?RECEIPT} = model_phone:get_sms_code_receipt(?PHONE2),
    {ok, TTL1} = model_phone:get_sms_code_ttl(?PHONE1),
    {ok, TTL2} = model_phone:get_sms_code_ttl(?PHONE2),
    true = TTL1 =< ?TTL_24HR_SEC andalso TTL1 > ?TTL_24HR_SEC - ?DELAY_SEC,
    true = TTL2 =< ?TTL_24HR_SEC andalso TTL2 > ?TTL_24HR_SEC - ?DELAY_SEC.


add_sms_gateway_response_test() ->
    setup(),
    {ok, []} = model_phone:get_verification_attempt_list(?PHONE1),
    {ok, []} = model_phone:get_all_sms_codes(?PHONE1),
    {ok, AttemptId} = model_phone:add_sms_code2(?PHONE1, ?CODE1),
    ok = model_phone:add_gateway_response(?PHONE1, AttemptId,
        #sms_response{gateway=?GATEWAY1, sms_id=?SMSID1, status=?STATUS, response=?RECEIPT}),
    {ok, ?CODE1} = model_phone:get_sms_code2(?PHONE1, AttemptId),
    {ok, [AttemptId]} = model_phone:get_verification_attempt_list(?PHONE1),
    %% Sleep for 1 seconds just so the timestamp for Attempt1 and Attemp2 is different.
    timer:sleep(timer:seconds(1)),
    {ok, AttemptId2} = model_phone:add_sms_code2(?PHONE1, ?CODE2),
    {ok, [AttemptId, AttemptId2]} = model_phone:get_verification_attempt_list(?PHONE1),
    ok = model_phone:add_gateway_response(?PHONE1, AttemptId2,
        #sms_response{gateway=?GATEWAY2, sms_id=?SMSID2, status=?STATUS, response=?RECEIPT}),
    {ok, ?CODE1} = model_phone:get_sms_code2(?PHONE1, AttemptId),
    {ok, ?CODE2} = model_phone:get_sms_code2(?PHONE1, AttemptId2),
    {ok, [{?CODE1, AttemptId}, {?CODE2, AttemptId2}]} = model_phone:get_all_sms_codes(?PHONE1),
    ok = model_phone:add_gateway_callback_info(
        #sms_response{gateway=?GATEWAY1, sms_id=?SMSID1, status=?CALLBACK_STATUS1,
            price=?PRICE1, currency=?CURRENCY1}),
    %% Sleep for 1 seconds just so the timestamp for Attempt1 and Attemp2 is different.
    timer:sleep(timer:seconds(1)),
    ok = model_phone:add_gateway_callback_info(
        #sms_response{gateway=?GATEWAY2, sms_id=?SMSID2, status=?CALLBACK_STATUS2,
            price=?PRICE2, currency=?CURRENCY2}),
    {ok, ?CALLBACK_STATUS1} = model_phone:get_gateway_response_status(?PHONE1, AttemptId),
    {ok, ?CALLBACK_STATUS2} = model_phone:get_gateway_response_status(?PHONE1, AttemptId2),
    AllResponses = [#sms_response{gateway=?GATEWAY1, status=?CALLBACK_STATUS1},
                    #sms_response{gateway=?GATEWAY2, status=?CALLBACK_STATUS2}],
    {ok, []} = model_phone:get_all_gateway_responses(?PHONE2),
    {ok, AllResponses} = model_phone:get_all_gateway_responses(?PHONE1),
    ok = model_phone:add_verification_success(?PHONE1, AttemptId),
    true = model_phone:get_verification_success(?PHONE1, AttemptId),
    false = model_phone:get_verification_success(?PHONE1, AttemptId2),
    #sms_response{gateway=?GATEWAY2, status=?CALLBACK_STATUS2, verified=false} =
          model_phone:get_verification_attempt_summary(?PHONE1, AttemptId2),
    ok = model_phone:add_verification_success(?PHONE1, AttemptId2),
    true = model_phone:get_verification_success(?PHONE1, AttemptId2),
    #sms_response{gateway=?GATEWAY2, status=?CALLBACK_STATUS2, verified=true} =
          model_phone:get_verification_attempt_summary(?PHONE1, AttemptId2).

delete_sms_code_test() ->
    setup(),
    %% Test cod:{phone}
    ok = model_phone:add_sms_code(?PHONE1, ?CODE1, ?TIME1, ?SENDER),
    {ok, ?CODE1} = model_phone:get_sms_code(?PHONE1),
    {ok, undefined} = model_phone:get_sms_code_receipt(?PHONE1),
    ok = model_phone:delete_sms_code(?PHONE1),
    {ok, undefined} = model_phone:get_sms_code(?PHONE1),
    {ok, undefined} = model_phone:get_sms_code_receipt(?PHONE1).


delete_sms_code2_test() ->
    setup(),
    {ok, []} = model_phone:get_verification_attempt_list(?PHONE1),
    {ok, []} = model_phone:get_all_sms_codes(?PHONE1),
    {ok, _} = model_phone:add_sms_code2(?PHONE1, ?CODE1),
    {ok, _} = model_phone:add_sms_code2(?PHONE1, ?CODE2),
    ok = model_phone:delete_sms_code2(?PHONE1),
    {ok, []} = model_phone:get_verification_attempt_list(?PHONE1),
    {ok, []} = model_phone:get_all_sms_codes(?PHONE1).


add_phone_test() ->
    setup(),
    %% Test pho:{phone}
    ok = model_phone:add_phone(?PHONE1, ?UID1),
    ok = model_phone:add_phone(?PHONE2, ?UID2),
    {ok, ?UID1} = model_phone:get_uid(?PHONE1),
    {ok, ?UID2} = model_phone:get_uid(?PHONE2),
    ResMap = #{?PHONE1 => ?UID1, ?PHONE2 => ?UID2},
    {ok, ResMap} = model_phone:get_uids([?PHONE1, ?PHONE2]),
    {ok, ResMap} = model_phone:get_uids([?PHONE2, ?PHONE1]).


delete_phone_test() ->
    setup(),
    %% Test pho:{phone}
    ok = model_phone:add_phone(?PHONE1, ?UID1),
    ok = model_phone:add_phone(?PHONE2, ?UID2),
    Res1Map = #{?PHONE1 => ?UID1, ?PHONE2 => ?UID2},
    {ok, Res1Map} = model_phone:get_uids([?PHONE1, ?PHONE2]),
    ok = model_phone:delete_phone(?PHONE1),
    Res2Map = #{?PHONE1 => undefined, ?PHONE2 => ?UID2},
    {ok, Res2Map} = model_phone:get_uids([?PHONE1, ?PHONE2]).


while(0, _F) -> ok;
while(N, F) ->
  erlang:apply(F, [N]),
  while(N -1, F).

perf_test() ->
  setup(),
  N = 10, %% Set to N=100000 to do
  while(N, fun(X) ->
            ok = model_phone:add_phone(integer_to_binary(X), integer_to_binary(X))
        end),
  Phones = [integer_to_binary(X) || X <- lists:seq(1,N,1)],
  PhonesUidsList = [{integer_to_binary(X), integer_to_binary(X)} || X <- lists:seq(1,N,1)],
  PhonesUidsMap = maps:from_list(PhonesUidsList),
  StartTime = os:system_time(microsecond),
  {ok, PhonesUidsMap} = model_phone:get_uids(Phones),
  EndTime = os:system_time(microsecond),
  T = EndTime - StartTime,
  io:format("~w operations took ~w ms => ~f ops ", [N, T, N / (T / 1000000)]),
  {ok, T}.

