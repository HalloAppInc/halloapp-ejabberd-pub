%%%------------------------------------------------------------------------------------
%%% File: model_phone.erl
%%% Copyright (C) 2020, HalloApp, Inc.
%%%
%%% This model handles all the redis db queries that are related with phone numbers.
%%%
%%%------------------------------------------------------------------------------------
-module(model_phone).
-author("murali").
-behavior(gen_mod).

-include("logger.hrl").
-include("ha_types.hrl").
-include("redis_keys.hrl").
-include("sms.hrl").


%% Export all functions for unit tests
-ifdef(TEST).
-compile(export_all).
-endif.

%% gen_mod callbacks
-export([start/2, stop/1, depends/2, mod_options/1]).


%% API
-export([
    add_sms_code/4,
    add_sms_code_receipt/2,
    delete_sms_code/1,
    get_sms_code/1,
    add_phone/2,
    delete_phone/1,
    get_uid/1,
    get_uids/1,
    get_sms_code_sender/1,
    get_sms_code_timestamp/1,
    get_sms_code_receipt/1,
    get_sms_code_ttl/1,
    add_sms_code2/2,
    get_sms_code2/2,
    add_gateway_response/6,
    get_verification_attempt_list/1,
    add_gateway_callback_info/3,
    get_gateway_response_status/2
]).


%%====================================================================
%% gen_mod callbacks
%%====================================================================

start(_Host, _Opts) ->
    ok.

stop(_Host) ->
    ok.

depends(_Host, _Opts) ->
    [{mod_redis, hard}].

mod_options(_Host) ->
    [].

%%====================================================================
%% API
%%====================================================================


-define(FIELD_CODE, <<"cod">>).
-define(FIELD_TIMESTAMP, <<"ts">>).
-define(FIELD_SENDER, <<"sen">>).
-define(FIELD_STATUS, <<"sts">>).
-define(FIELD_RECEIPT, <<"rec">>).
-define(FIELD_RESPONSE, <<"res">>).
-define(FIELD_VERIFICATION_ATTEMPT, <<"fva">>).
-define(TTL_SMS_CODE, 86400).
-define(MAX_SLOTS, 8).

-define(TTL_VERIFICATION_ATTEMPTS, 30 * 86400).  %% 30 days


-spec add_sms_code(Phone :: phone(), Code :: binary(), Timestamp :: integer(),
                Sender :: binary()) -> ok  | {error, any()}.
add_sms_code(Phone, Code, Timestamp, Sender) ->
    _Results = q([["MULTI"],
                    ["HSET", code_key(Phone),
                    ?FIELD_CODE, Code,
                    ?FIELD_TIMESTAMP, integer_to_binary(Timestamp),
                    ?FIELD_SENDER, Sender],
                    ["EXPIRE", code_key(Phone), ?TTL_SMS_CODE],
                    ["EXEC"]]),
    ok.


-spec add_sms_code_receipt(Phone :: phone(), Receipt :: binary()) -> ok  | {error, any()}.
add_sms_code_receipt(Phone, Receipt) ->
    _Results = q(["HSET", code_key(Phone), ?FIELD_RECEIPT, Receipt]),
    ok.


-spec delete_sms_code(Phone :: phone()) -> ok  | {error, any()}.
delete_sms_code(Phone) ->
    {ok, _Res} = q(["DEL", code_key(Phone)]),
    ok.


-spec get_sms_code(Phone :: phone()) -> {ok, maybe(binary())} | {error, any()}.
get_sms_code(Phone) ->
    {ok, Res} = q(["HGET", code_key(Phone), ?FIELD_CODE]),
    {ok, Res}.


-spec get_sms_code_timestamp(Phone :: phone()) -> {ok, maybe(integer())} | {error, any()}.
get_sms_code_timestamp(Phone) ->
    {ok, Res} = q(["HGET" , code_key(Phone), ?FIELD_TIMESTAMP]),
    {ok, util_redis:decode_ts(Res)}.


-spec get_sms_code_sender(Phone :: phone()) -> {ok, maybe(binary())} | {error, any()}.
get_sms_code_sender(Phone) ->
    {ok, Res} = q(["HGET" , code_key(Phone), ?FIELD_SENDER]),
    {ok, Res}.


-spec get_sms_code_receipt(Phone :: phone()) -> {ok, maybe(binary())} | {error, any()}.
get_sms_code_receipt(Phone) ->
    {ok, Res} = q(["HGET" , code_key(Phone), ?FIELD_RECEIPT]),
    {ok, Res}.


% -1 means key does not have TTL set.
% -2 means key does not exist.
-spec get_sms_code_ttl(Phone :: phone()) -> {ok, integer()} | {error, any()}.
get_sms_code_ttl(Phone) ->
    {ok, Res} = q(["TTL" , code_key(Phone)]),
    {ok, binary_to_integer(Res)}.


-spec add_sms_code2(Phone :: phone(), Code :: binary()) -> {ok, binary()}  | {error, any()}.
add_sms_code2(Phone, Code) ->
    %% TODO(vipin): Need to clean verification attempt list when SMS code expire.
    AttemptId = generate_attempt_id(),
    Timestamp = util:now(),
    VerificationAttemptListKey = verification_attempt_list_key(Phone),
    VerificationAttemptKey = verification_attempt_key(Phone, AttemptId),
    _Results = q([["MULTI"],
                   ["ZADD", VerificationAttemptListKey, Timestamp, AttemptId],
                   ["EXPIRE", VerificationAttemptListKey, ?TTL_VERIFICATION_ATTEMPTS],
                   ["HSET", VerificationAttemptKey, ?FIELD_CODE, Code],
                   ["EXPIRE", VerificationAttemptKey, ?TTL_VERIFICATION_ATTEMPTS],
                   ["EXEC"]]),

    %% TODO(vipin): Need to remove the following code a few days after the upgrade.
    add_sms_code(Phone, Code, Timestamp, ?TWILIO),
    {ok, AttemptId}.

-spec get_sms_code2(Phone :: phone(), AttemptId :: binary()) -> [binary()].
get_sms_code2(Phone, AttemptId) ->
  VerificationAttemptKey = verification_attempt_key(Phone, AttemptId),
  {ok, Res} = q(["HGET", VerificationAttemptKey, ?FIELD_CODE]),
  {ok, Res}.


-spec get_verification_attempt_list(Phone :: phone()) -> {ok, [binary()]} | {error, any()}.
get_verification_attempt_list(Phone) ->
    Deadline = util:now() - ?TTL_SMS_CODE,
    {ok, VerificationAttemptList} = q(["ZRANGEBYSCORE", verification_attempt_list_key(Phone),
          integer_to_binary(Deadline), "+inf"]),

    %% NOTE: We have chosen to not insert SMS Gateway tracked using 'add_sms_code_receipt(...)'.
    %% As a result this method returns partial result during the upgrade.
    {ok, VerificationAttemptList}.


-spec add_gateway_response(Phone :: phone(), AttemptId :: binary(), Gateway :: binary(),
        SMSId :: binary(), Status :: binary(), Response :: binary()) -> ok | {error, any()}.
add_gateway_response(Phone, AttemptId, Gateway, SMSId, Status, Response) ->
    GatewayResponseKey = gateway_response_key(Gateway, SMSId),
    VerificationAttemptKey = verification_attempt_key(Phone, AttemptId),
    _Result1 = q([["MULTI"],
                   ["HSET", GatewayResponseKey, ?FIELD_VERIFICATION_ATTEMPT, VerificationAttemptKey],
                   ["EXPIRE", GatewayResponseKey, ?TTL_VERIFICATION_ATTEMPTS],
                   ["EXEC"]]),
    ?DEBUG("Adding mapping from GWRK: ~p, to VAK: ~p", [GatewayResponseKey, VerificationAttemptKey]),
    _Result2 = q([["MULTI"],
                   ["HSET", VerificationAttemptKey, ?FIELD_SENDER, Gateway, ?FIELD_STATUS, Status,
                       ?FIELD_RESPONSE, Response],
                   ["EXPIRE", VerificationAttemptKey, ?TTL_VERIFICATION_ATTEMPTS],
                   ["EXEC"]]),
    ?DEBUG("Adding Response for VAK: ~p, status: ~p, response: ~p", [VerificationAttemptKey, Status, Response]),

    %% TODO(vipin): The following calls are temporary and will not be needed once we start tracking
    %% SMS Gateway using 'add_gateway_response(...)' instead of 'add_sms_code(...).
    _Res2 = q(["HSET", code_key(Phone), ?FIELD_SENDER, Gateway]),
    add_sms_code_receipt(Phone, Response),
    ok.


%% TODO(vipin): Add more fields from the callback response and add those fields in this call.
%% Example additional field: Cost
-spec add_gateway_callback_info(Gateway :: binary(), SMSId :: binary(), Status :: binary())
    -> ok | {error, any()}.
add_gateway_callback_info(Gateway, SMSId, Status) ->
    GatewayResponseKey = gateway_response_key(Gateway, SMSId),
    {ok, VerificationAttemptKey} = q(["HGET", GatewayResponseKey, ?FIELD_VERIFICATION_ATTEMPT]),
    _Result = q(["HSET", VerificationAttemptKey, ?FIELD_STATUS, Status]),
    ok.

-spec get_gateway_response_status(Phone :: phone(), AttemptId :: binary())
    -> {ok, maybe(binary())} | {error, any()}.
get_gateway_response_status(Phone, AttemptId) ->
    VerificationAttemptKey = verification_attempt_key(Phone, AttemptId),
    {ok, Res} = q(["HGET", VerificationAttemptKey, ?FIELD_STATUS]),
    {ok, Res}.


-spec add_phone(Phone :: phone(), Uid :: uid()) -> ok  | {error, any()}.
add_phone(Phone, Uid) ->
    {ok, _Res} = q(["SET", phone_key(Phone), Uid]),
    ok.


-spec delete_phone(Phone :: phone()) -> ok  | {error, any()}.
delete_phone(Phone) ->
    {ok, _Res} = q(["DEL", phone_key(Phone)]),
    ok.


-spec get_uid(Phone :: phone()) -> {ok, maybe(binary())} | {error, any()}.
get_uid(Phone) ->
    {ok, Res} = q(["GET" , phone_key(Phone)]),
    {ok, Res}.


-spec get_uids(Phones :: [binary()]) -> {ok, map()} | {error, any()}.
get_uids(Phones) ->
    {PhoneKeysList, PhonesList} = order_phones_by_keys(Phones),
    UidsList = lists:map(
            fun(PhoneKeys) ->
                case PhoneKeys of
                    [] -> [];
                    _ ->
                        {ok, Result} = q(["MGET" | PhoneKeys]),
                        Result
                end
            end, PhoneKeysList),
    Result = lists:zip(lists:flatten(PhonesList), lists:flatten(UidsList)),
    PhonesUidsMap = maps:from_list(Result),
    {ok, PhonesUidsMap}.


q(Command) -> ecredis:q(ecredis_phone, Command).


-spec order_phones_by_keys(Phones :: [binary()]) -> {[binary()], [binary()]}.
order_phones_by_keys(Phones) ->
    DefaultMap = get_default_slot_map(?MAX_SLOTS, #{}),
    order_phones_into_slots(Phones, DefaultMap).


-spec phone_key(Phone :: phone()) -> binary().
phone_key(Phone) ->
    Slot = get_slot(Phone),
    phone_key(Phone, Slot).


-spec generate_attempt_id() -> binary().
generate_attempt_id() ->
    base64url:encode(crypto:strong_rand_bytes(12)).


% TODO: migrate the data to make the keys take look like pho:{5}:1555555555
% TODO: also migrate to the crc16_redis
-spec phone_key(Phone :: phone(), Slot :: integer()) -> binary().
phone_key(Phone, Slot) ->
    <<?PHONE_KEY/binary, <<"{">>/binary, Slot/integer, <<"}:">>/binary, Phone/binary>>.


-spec order_phones_into_slots(Phones :: [binary()], SlotsMap :: map()) -> {[binary()], [binary()]}.
order_phones_into_slots(Phones, SlotsMap) ->
    SlotsPhoneMap = lists:foldl(fun(Phone, SMap) ->
                                    Slot = get_slot(Phone),
                                    PhoneKey = phone_key(Phone, Slot),
                                    {PhoneKeyList, PhoneList} = maps:get(Slot, SMap),
                                    NewPhoneKeyList = [PhoneKey | PhoneKeyList],
                                    NewPhoneList = [Phone | PhoneList],
                                    SMap#{Slot => {NewPhoneKeyList, NewPhoneList}}
                                end, SlotsMap, Phones),
    lists:unzip(maps:values(SlotsPhoneMap)).


-spec get_slot(Phone :: phone()) -> integer().
get_slot(Phone) ->
    crc16:crc16(binary_to_list(Phone)) rem ?MAX_SLOTS.


-spec get_default_slot_map(Slot :: integer(), Map :: map()) -> map().
get_default_slot_map(1, Map) ->
    Map#{0 => {[], []}};
get_default_slot_map(Num, Map) ->
    get_default_slot_map(Num - 1, Map#{Num - 1 => {[], []}}).


%% TODO(vipin): It should be CODE_KEY instead of PHONE_KEY.
-spec code_key(Phone :: phone()) -> binary().
code_key(Phone) ->
    <<?PHONE_KEY/binary, <<"{">>/binary, Phone/binary, <<"}">>/binary>>.

-spec verification_attempt_list_key(Phone :: phone()) -> binary().
verification_attempt_list_key(Phone) ->
    <<?VERIFICATION_ATTEMPT_LIST_KEY/binary, <<"{">>/binary, Phone/binary, <<"}">>/binary>>.

-spec verification_attempt_key(Phone :: phone(), AttemptId :: binary()) -> binary().
verification_attempt_key(Phone, AttemptId) ->
    <<?VERIFICATION_ATTEMPT_ID_KEY/binary, <<"{">>/binary, Phone/binary, <<"}:">>/binary, AttemptId/binary>>.


-spec gateway_response_key(Gateway :: binary(), SMSId :: binary()) -> binary().
gateway_response_key(Gateway, SMSId) ->
    <<?GATEWAY_RESPONSE_ID_KEY/binary, <<"{">>/binary, Gateway/binary, <<":">>/binary, SMSId/binary, <<"}">>/binary>>.


