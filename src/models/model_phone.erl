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
-include_lib("eunit/include/eunit.hrl").


%% Export all functions for unit tests
-ifdef(TEST).
-export([phone_key/1]).
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
    get_incremental_attempt_list/1,
    delete_sms_code2/1,
    get_sms_code2/2,
    get_all_sms_codes/1,
    add_gateway_response/3,
    get_all_gateway_responses/1,
    get_verification_attempt_list/1,
    add_gateway_callback_info/1,
    get_gateway_response_status/2,
    add_verification_success/2,
    get_verification_success/2,
    get_verification_attempt_summary/2
]).


%%====================================================================
%% gen_mod callbacks
%%====================================================================

start(_Host, _Opts) ->
    ok.

stop(_Host) ->
    ok.

depends(_Host, _Opts) ->
    [].

mod_options(_Host) ->
    [].

%%====================================================================
%% API
%%====================================================================


-define(FIELD_CODE, <<"cod">>).
-define(FIELD_TIMESTAMP, <<"ts">>).
-define(FIELD_SENDER, <<"sen">>).
-define(FIELD_METHOD, <<"met">>).
-define(FIELD_STATUS, <<"sts">>).
-define(FIELD_PRICE, <<"prc">>).
-define(FIELD_CURRENCY, <<"cur">>).
-define(FIELD_RECEIPT, <<"rec">>).
-define(FIELD_RESPONSE, <<"res">>).
-define(FIELD_VERIFICATION_ATTEMPT, <<"fva">>).
-define(FIELD_VERIFICATION_SUCCESS, <<"suc">>).
-define(TTL_SMS_CODE, 86400).
-define(MAX_SLOTS, 8).

%% TTL for SMS reg data: 1 day, in case the background task does not run for 1 day
-define(TTL_INCREMENTAL_TIMESTAMP, 86400).

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

    %% Store Phone in a set determined by the timestamp increment (15 mins). We want to make sure
    %% that there is a corresponding registration within safe distance of timestamp increment, e.g.
    %% (1/2 hour).
    IncrementalTimestamp = Timestamp div ?SMS_REG_TIMESTAMP_INCREMENT,
    IncrementalTimestampKey = incremental_timestamp_key(IncrementalTimestamp),
    ?DEBUG("Added at: ~p, Key: ~p", [IncrementalTimestamp, IncrementalTimestampKey]),
    _Result2 = qp([["SADD", IncrementalTimestampKey, term_to_binary({Phone, AttemptId})],
                   ["EXPIRE", IncrementalTimestampKey, ?TTL_INCREMENTAL_TIMESTAMP]]),
    {ok, AttemptId}.


%% TODO(vipin): Add unit test.
-spec get_incremental_attempt_list(IncrementalTimestamp :: integer()) -> [{phone(), binary()}].
get_incremental_attempt_list(IncrementalTimestamp) ->
    Key = incremental_timestamp_key(IncrementalTimestamp),
    {ok, List} = q(["SMEMBERS", Key]),
    [binary_to_term(Elem) || Elem <- List].


-spec delete_sms_code2(Phone :: phone()) -> ok  | {error, any()}.
delete_sms_code2(Phone) ->
    {ok, VerificationAttemptList} = get_verification_attempt_list(Phone),
    RedisCommands = lists:map(
        fun(AttemptId) ->
            ["DEL", verification_attempt_key(Phone, AttemptId)]
        end, VerificationAttemptList),
    case RedisCommands of
        [] ->
            ok;
        _ ->
            RedisCommands2 = RedisCommands ++ [["DEL", verification_attempt_list_key(Phone)]],
            qp(RedisCommands2)
    end,
    ok.


-spec get_all_sms_codes(Phone :: phone()) -> {ok, [{binary(), binary()}]} | {error, any()}.
get_all_sms_codes(Phone) ->
    {ok, VerificationAttemptList} = get_verification_attempt_list(Phone),
    RedisCommands = lists:map(
        fun(AttemptId) ->
            ["HGET", verification_attempt_key(Phone, AttemptId), ?FIELD_CODE]
        end, VerificationAttemptList),
    SMSCodeList = case RedisCommands of
        [] -> [];
        _ -> qp(RedisCommands)
    end,
    CombinedList = lists:zipwith(
        fun(YY, ZZ) ->
            {ok, Code} = YY,
            {Code, ZZ}
        end, SMSCodeList, VerificationAttemptList),
    {ok, CombinedList}. 


-spec get_sms_code2(Phone :: phone(), AttemptId :: binary()) -> {ok, binary()} | {error, any()}.
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


-spec add_gateway_response(Phone :: phone(), AttemptId :: binary(), SMSResponse :: gateway_response())
      -> ok | {error, any()}.
add_gateway_response(Phone, AttemptId, SMSResponse) ->
    #gateway_response{
        gateway_id = GatewayId,
        gateway = Gateway,
        method = Method,
        status = Status,
        response = Response
    } = SMSResponse,
    GatewayResponseKey = gateway_response_key(Gateway, GatewayId),
    VerificationAttemptKey = verification_attempt_key(Phone, AttemptId),
    _Result1 = q([["MULTI"],
                   ["HSET", GatewayResponseKey, ?FIELD_VERIFICATION_ATTEMPT, VerificationAttemptKey],
                   ["EXPIRE", GatewayResponseKey, ?TTL_VERIFICATION_ATTEMPTS],
                   ["EXEC"]]),
    GatewayBin = util:to_binary(Gateway),
    MethodBin = encode_method(Method),
    StatusBin = util:to_binary(Status),
    _Result2 = q([["MULTI"],
                   ["HSET", VerificationAttemptKey, ?FIELD_SENDER, GatewayBin,
                       ?FIELD_METHOD, MethodBin, ?FIELD_STATUS, StatusBin,
                       ?FIELD_RESPONSE, Response],
                   ["EXPIRE", VerificationAttemptKey, ?TTL_VERIFICATION_ATTEMPTS],
                   ["EXEC"]]),
    ok.


-spec get_all_gateway_responses(Phone :: phone()) -> {ok, [gateway_response()]} | {error, any()}.
get_all_gateway_responses(Phone) ->
    {ok, VerificationAttemptList} = get_verification_attempt_list(Phone),
    RedisCommands = lists:map(
        fun(AttemptId) ->
            ["HMGET", verification_attempt_key(Phone, AttemptId), ?FIELD_SENDER, ?FIELD_METHOD,
                ?FIELD_STATUS]
        end, VerificationAttemptList),
    ResponseList = case RedisCommands of
        [] -> [];
        _ -> qp(RedisCommands)
    end,
    SMSResponseList = lists:map(
        fun({ok, [Sender, Method, Status]}) ->
            #gateway_response{
                gateway = util:to_atom(Sender),
                method = decode_method(Method),
                status = util:to_atom(Status)
            }
        end, ResponseList),
    {ok, SMSResponseList}.


-spec add_gateway_callback_info(GatewayResponse :: gateway_response()) -> ok | {error, any()}.
add_gateway_callback_info(GatewayResponse) ->
    #gateway_response{
        gateway_id = GatewayId,
        gateway = Gateway,
        status = Status,
        price = Price,
        currency = Currency
    } = GatewayResponse,
    GatewayResponseKey = gateway_response_key(Gateway, GatewayId),
    {ok, VerificationAttemptKey} = q(["HGET", GatewayResponseKey, ?FIELD_VERIFICATION_ATTEMPT]),
    ?assertNotEqual(undefined, Status),
    StatusBin = util:to_binary(Status),
    StatusCommand = ["HSET", VerificationAttemptKey, ?FIELD_STATUS, StatusBin],
    PriceCommands = case Price of
        undefined -> [];
        _ ->
            ?assertNotEqual(undefined, Currency),
            PriceBin = util:to_binary(Price),
            [["HSET", VerificationAttemptKey, ?FIELD_PRICE, PriceBin],
             ["HSET", VerificationAttemptKey, ?FIELD_CURRENCY, Currency]]
    end,
    RedisCommands = case PriceCommands of
        [] -> [StatusCommand];
        _ -> [StatusCommand] ++ PriceCommands
    end,
    _Result = qp(RedisCommands),
    ok.

-spec get_gateway_response_status(Phone :: phone(), AttemptId :: binary())
    -> {ok, atom()} | {error, any()}.
get_gateway_response_status(Phone, AttemptId) ->
    VerificationAttemptKey = verification_attempt_key(Phone, AttemptId),
    {ok, Res} = q(["HGET", VerificationAttemptKey, ?FIELD_STATUS]),
    {ok, util:to_atom(Res)}.


-spec add_verification_success(Phone :: phone(), AttemptId :: binary()) -> ok | {error, any()}.
add_verification_success(Phone, AttemptId) ->
    VerificationAttemptKey = verification_attempt_key(Phone, AttemptId),
    _Res = q(["HSET", VerificationAttemptKey, ?FIELD_VERIFICATION_SUCCESS, "1"]),
    ok.


-spec get_verification_success(Phone :: phone(), AttemptId :: binary()) -> boolean().
get_verification_success(Phone, AttemptId) ->
    VerificationAttemptKey = verification_attempt_key(Phone, AttemptId),
    {ok, Res} = q(["HGET", VerificationAttemptKey, ?FIELD_VERIFICATION_SUCCESS]),
    util_redis:decode_boolean(Res, false).


-spec get_verification_attempt_summary(Phone :: phone(), AttemptId :: binary()) -> gateway_response().
get_verification_attempt_summary(Phone, AttemptId) ->
    {ok, Res} = q(["HMGET", verification_attempt_key(Phone, AttemptId), ?FIELD_SENDER, ?FIELD_METHOD,
        ?FIELD_STATUS, ?FIELD_VERIFICATION_SUCCESS]),
    [Sender, Method, Status, Success] = Res,
    case {Sender, Method, Status, Success} of
        {undefined, _, _, _} -> #gateway_response{};
        {_, _, _, _} ->
                #gateway_response{
                    gateway = util:to_atom(Sender),
                    method = decode_method(Method),
                    status = util:to_atom(Status),
                    verified = util_redis:decode_boolean(Success, false)
                }
    end.
 

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


-spec get_uids(Phones :: [binary()]) -> map() | {error, any()}.
get_uids([]) -> #{};
get_uids(Phones) ->
    Commands = lists:map(fun(Phone) -> ["GET" , phone_key(Phone)] end, Phones),
    Res = qmn(Commands),
    Result = lists:foldl(
        fun({Phone, {ok, Uid}}, Acc) ->
            case Uid of
                undefined -> Acc;
                _ -> Acc#{Phone => Uid}
            end
        end, #{}, lists:zip(Phones, Res)),
    Result.


q(Command) -> ecredis:q(ecredis_phone, Command).
qp(Commands) -> ecredis:qp(ecredis_phone, Commands).
qmn(Commands) -> ecredis:qmn(ecredis_phone, Commands).


-spec encode_method(Method :: sms | voice_call | undefined) -> binary().
encode_method(Method) ->
    Method2 = case Method of
        undefined -> sms;
        _ -> Method
    end,
    util:to_binary(Method2).


-spec decode_method(Method :: maybe(binary())) -> sms | voice_call.
decode_method(Method) ->
    Method2 = case Method of
        undefined -> <<"sms">>;
        _ -> Method
    end,
    util:to_atom(Method2).


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

-spec incremental_timestamp_key(IncrementalTS :: integer()) -> binary().
incremental_timestamp_key(IncrementalTS) ->
    TSBin = util:to_binary(IncrementalTS),
    <<?INCREMENTAL_TS_KEY/binary, <<"{">>/binary, TSBin/binary, <<"}">>/binary>>.


-spec gateway_response_key(Gateway :: atom(), GatewayId :: binary()) -> binary().
gateway_response_key(Gateway, GatewayId) ->
    GatewayBin = util:to_binary(Gateway),
    <<?GATEWAY_RESPONSE_ID_KEY/binary, <<"{">>/binary, GatewayBin/binary, <<":">>/binary,
        GatewayId/binary, <<"}">>/binary>>.


