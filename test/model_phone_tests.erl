%%%-------------------------------------------------------------------
%%% File: model_phone_tests.erl
%%% Copyright (C) 2020, Halloapp Inc.
%%%
%%%-------------------------------------------------------------------
-module(model_phone_tests).
-author("murali").

-include_lib("eunit/include/eunit.hrl").

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


setup() ->
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


delete_sms_code_test() ->
    setup(),
    %% Test cod:{phone}
    ok = model_phone:add_sms_code(?PHONE1, ?CODE1, ?TIME1, ?SENDER),
    {ok, ?CODE1} = model_phone:get_sms_code(?PHONE1),
    {ok, undefined} = model_phone:get_sms_code_receipt(?PHONE1),
    ok = model_phone:delete_sms_code(?PHONE1),
    {ok, undefined} = model_phone:get_sms_code(?PHONE1),
    {ok, undefined} = model_phone:get_sms_code_receipt(?PHONE1).


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

