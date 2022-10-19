%%%------------------------------------------------------------------------------------
%%% File: model_phone.erl
%%% Copyright (C) 2020, HalloApp, Inc.
%%%
%%% This model handles all the redis db queries that are related with phone numbers.
%%%
%%%------------------------------------------------------------------------------------
-module(model_phone).
-author("murali").

-include("logger.hrl").
-include("ha_types.hrl").
-include("redis_keys.hrl").
-include("sms.hrl").
-include("time.hrl").
-include("monitor.hrl").
-include_lib("stdlib/include/assert.hrl").


%% Export all functions for unit tests
-ifdef(TEST).
-export([
    q/1, qmn/1,
    verification_attempt_key/2
]).
-endif.


%% API
-export([
    phone_key/1,
    add_phone/2,
    delete_phone/1,
    get_uid/1,
    get_uids/1,
    add_sms_code2/2,
    add_sms_code2/3,
    get_incremental_attempt_list/1,
    delete_sms_code2/1,
    update_sms_code/3,
    get_sms_code2/2,
    get_all_verification_info/1,
    add_gateway_response/3,
    get_all_gateway_responses/1,
    get_verification_attempt_list/1,
    add_gateway_callback_info/1,
    get_verification_attempt_key/1,
    get_gateway_response_status/2,
    add_verification_success/2,
    get_verification_success/2,
    get_verification_attempt_summary/2,
    add_phone_pattern/2,
    get_phone_pattern_info/1,
    delete_phone_pattern/1,
    invalidate_old_attempts/1,
    add_static_key/2,
    get_static_key_info/1,
    delete_static_key/1,
    add_phone_cc/2,
    get_phone_cc_info/1,
    delete_phone_cc/1,
    add_hashcash_challenge/1,
    delete_hashcash_challenge/1,
    add_phone_code_attempt/2,
    get_phone_code_attempts/2,
    phone_attempt_key/2
]).

%%====================================================================
%% API
%%====================================================================


-define(FIELD_CODE, <<"cod">>).
-define(FIELD_LANGID, <<"lid">>).
-define(FIELD_COUNT, <<"ct">>).
-define(FIELD_TIMESTAMP, <<"ts">>).
-define(FIELD_SENDER, <<"sen">>).
-define(FIELD_METHOD, <<"met">>).
-define(FIELD_STATUS, <<"sts">>).
-define(FIELD_PRICE, <<"prc">>).
-define(FIELD_CURRENCY, <<"cur">>).
-define(FIELD_RECEIPT, <<"rec">>).
-define(FIELD_RESPONSE, <<"res">>).
-define(FIELD_SID, <<"sid">>).
-define(FIELD_VERIFICATION_ATTEMPT, <<"fva">>).
-define(FIELD_VERIFICATION_SUCCESS, <<"suc">>).
-define(FIELD_VALID, <<"val">>).
-define(FIELD_CAMPAIGN_ID, <<"cmp">>).
-define(TTL_SMS_CODE, 86400).
-define(MAX_SLOTS, 8).

%% TTL for SMS reg data: 7 1/2 days, in case the background task does not run for a period
-define(TTL_INCREMENTAL_TIMESTAMP, 7 * ?DAYS + 12 * ?HOURS).

-define(TTL_VERIFICATION_ATTEMPTS, 30 * 86400).  %% 30 days

-define(MONITOR_VERIFICATION_TTL, 60).

%% TTL for phone pattern data: 24 hour.
-define(TTL_PHONE_PATTERN, 86400).

%% TTL for remote static key: 24 hour.
-define(TTL_REMOTE_STATIC_KEY, 86400).

-define(TRUNC_STATIC_KEY_LENGTH, 8).

%% TTL for phone cc: 24 hour.
-define(TTL_PHONE_CC, 86400).

%% TTL for hashcash cc: 6 hour.
-define(TTL_HASHCASH, 6 * ?HOURS).

%% TTL for phone code guessing attempt counter
-define(TTL_PHONE_ATTEMPT, 7 * ?DAYS).

-spec add_sms_code2(Phone :: phone(), Code :: binary()) -> {ok, binary(), non_neg_integer()}  | {error, any()}.
add_sms_code2(Phone, Code) ->
    add_sms_code2(Phone, Code, <<>>).

-spec add_sms_code2(Phone :: phone(), Code :: binary(), CampaignId :: binary()) -> {ok, binary(), non_neg_integer()}  | {error, any()}.
add_sms_code2(Phone, Code, CampaignId) ->
    %% TODO(vipin): Need to clean verification attempt list when SMS code expire.
    AttemptId = generate_attempt_id(),
    Timestamp = util:now(),
    VerificationAttemptListKey = verification_attempt_list_key(Phone),
    VerificationAttemptKey = verification_attempt_key(Phone, AttemptId),
    TTL = case util:is_monitor_phone(Phone) of
        true -> ?MONITOR_VERIFICATION_TTL;
        false -> ?TTL_VERIFICATION_ATTEMPTS
    end,
    _Results = qp([["MULTI"],
                   ["ZADD", VerificationAttemptListKey, Timestamp, AttemptId],
                   ["ZREMRANGEBYSCORE", VerificationAttemptListKey, "-inf", Timestamp - TTL],
                   ["EXPIRE", VerificationAttemptListKey, TTL],
                   ["HSET", VerificationAttemptKey, ?FIELD_CODE, Code, ?FIELD_VALID, "1", ?FIELD_CAMPAIGN_ID, CampaignId],
                   ["EXPIRE", VerificationAttemptKey, TTL],
                   ["EXEC"]]),

    %% Store Phone in a set determined by the timestamp increment (15 mins). We want to make sure
    %% that there is a corresponding registration within safe distance of timestamp increment, e.g.
    %% (1/2 hour).
    IncrementalTimestamp = Timestamp div ?SMS_REG_TIMESTAMP_INCREMENT,
    IncrementalTimestampKey = incremental_timestamp_key(IncrementalTimestamp),
    ?DEBUG("Added at: ~p, Key: ~p", [IncrementalTimestamp, IncrementalTimestampKey]),
    _Result2 = qp([["SADD", IncrementalTimestampKey, term_to_binary({Phone, AttemptId})],
                   ["EXPIRE", IncrementalTimestampKey, ?TTL_INCREMENTAL_TIMESTAMP]]),
    {ok, AttemptId, Timestamp}.


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
        fun({AttemptId, _TS}) ->
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


-spec get_all_verification_info(Phone :: phone()) -> {ok, [verification_info()]} | {error, any()}.
get_all_verification_info(Phone) ->
    {ok, VerificationAttemptList} = get_verification_attempt_list(Phone),
    RedisCommands = lists:map(
        fun({AttemptId, _TS}) ->
            ["HMGET", verification_attempt_key(Phone, AttemptId),
                ?FIELD_CODE, ?FIELD_SENDER, ?FIELD_SID, ?FIELD_STATUS, ?FIELD_VALID]
        end, VerificationAttemptList),
    VerifyInfoList = qp(RedisCommands),
    CombinedList = lists:zipwith(
        fun(VerifyInfo, VerificationAttempt) ->
            {ok, [Code, Gateway, Sid, Status, Validity]} = VerifyInfo,
            {Attempt, TS} = VerificationAttempt,
            #verification_info{
                gateway = Gateway,
                attempt_id = Attempt,
                code = Code,
                sid = Sid,
                ts = binary_to_integer(TS),
                status = Status,
                valid = util_redis:decode_boolean(Validity, false)
            }
        end, VerifyInfoList, VerificationAttemptList),
    %% Filter and return only valid attempts.
    FinalVerificationInfo = lists:filter(
        fun (#verification_info{valid = Validity}) -> Validity end, CombinedList),
    {ok, FinalVerificationInfo}.


-spec get_sms_code2(Phone :: phone(), AttemptId :: binary()) -> {ok, binary()} | {error, any()}.
get_sms_code2(Phone, AttemptId) ->
  VerificationAttemptKey = verification_attempt_key(Phone, AttemptId),
  {ok, Res} = q(["HGET", VerificationAttemptKey, ?FIELD_CODE]),
  {ok, Res}.


% Mbird_verify has a default code of <<"999999">>. In approved attempts, we want
% to update the code so that it can be used to verify again (up to 24hrs).
-spec update_sms_code(Phone :: phone(), Code :: binary(), AttemptId :: binary()) -> ok.
update_sms_code(Phone, Code, AttemptId) ->
    VerificationAttemptKey = verification_attempt_key(Phone, AttemptId),
    _Res = q(["HSET", VerificationAttemptKey, ?FIELD_CODE, Code]),
    ok.


-spec get_verification_attempt_list(Phone :: phone()) -> {ok, [{binary(), binary()}]} | {error, any()}.
get_verification_attempt_list(Phone) ->
    Deadline = util:now() - ?TTL_SMS_CODE,
    {ok, Res} = q(["ZRANGEBYSCORE", verification_attempt_list_key(Phone),
          integer_to_binary(Deadline), "+inf", "WITHSCORES"]),
    {ok, util_redis:parse_zrange_with_scores(Res)}.


-spec add_gateway_response(Phone :: phone(), AttemptId :: binary(), SMSResponse :: gateway_response())
      -> ok | {error, any()}.
add_gateway_response(Phone, AttemptId, SMSResponse) ->
    #gateway_response{
        gateway_id = GatewayId,
        gateway = Gateway,
        method = Method,
        status = Status,
        response = Response,
        lang_id = LangId
    } = SMSResponse,
    GatewayResponseKey = gateway_response_key(Gateway, GatewayId),
    VerificationAttemptKey = verification_attempt_key(Phone, AttemptId),
    _Result1 = qp([["MULTI"],
                   ["HSET", GatewayResponseKey, ?FIELD_VERIFICATION_ATTEMPT, VerificationAttemptKey],
                   ["EXPIRE", GatewayResponseKey, ?TTL_VERIFICATION_ATTEMPTS],
                   ["EXEC"]]),
    GatewayBin = util:to_binary(Gateway),
    MethodBin = encode_method(Method),
    StatusBin = util:to_binary(Status),
    SidBin = util:to_binary(GatewayId),
    _Result2 = qp([["MULTI"],
                   ["HSET", VerificationAttemptKey, ?FIELD_SENDER, GatewayBin,
                       ?FIELD_METHOD, MethodBin, ?FIELD_STATUS, StatusBin,
                       ?FIELD_RESPONSE, Response, ?FIELD_SID, SidBin,
                       ?FIELD_LANGID, LangId],
                   ["EXPIRE", VerificationAttemptKey, ?TTL_VERIFICATION_ATTEMPTS],
                   ["EXEC"]]),
    ok.


-spec get_all_gateway_responses(Phone :: phone()) -> {ok, [gateway_response()]} | {error, any()}.
get_all_gateway_responses(Phone) ->
    {ok, VerificationAttemptList} = get_verification_attempt_list(Phone),
    RedisCommands = lists:map(
        fun({AttemptId, _TS}) ->
            ["HMGET", verification_attempt_key(Phone, AttemptId), ?FIELD_SENDER, ?FIELD_METHOD,
                ?FIELD_STATUS, ?FIELD_VERIFICATION_SUCCESS, ?FIELD_LANGID, ?FIELD_VALID]
        end, VerificationAttemptList),
    ResponseList = qp(RedisCommands),
    SMSResponseList = lists:zipwith(
        fun({AttemptId, AttemptTS}, {ok, [Sender, Method, Status, Success, LangId, Validity]}) ->
            #gateway_response{
                gateway = util:to_atom(Sender),
                method = decode_method(Method),
                status = util:to_atom(Status),
                verified = util_redis:decode_boolean(Success, false),
                attempt_id = AttemptId,
                attempt_ts = AttemptTS,
                lang_id = util_redis:decode_binary(LangId),
                valid = util_redis:decode_boolean(Validity, false)
            }
        end, VerificationAttemptList, ResponseList),
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
    PriceCommand = case Price of
        undefined -> [];
        _ ->
            PriceBin = util:to_binary(Price),
            ["HSET", VerificationAttemptKey, ?FIELD_PRICE, PriceBin]
    end,
    CurrencyCommand = case Currency of
        undefined -> [];
        _ -> ["HSET", VerificationAttemptKey, ?FIELD_CURRENCY, Currency]
    end, 
    RedisCommands = case {PriceCommand, CurrencyCommand} of
        {[],_} -> [StatusCommand];
        {_, []} -> [StatusCommand] ++ [PriceCommand];
        {_, _} -> [StatusCommand] ++ [PriceCommand] ++ [CurrencyCommand]
    end,
    _Result = qp(RedisCommands),
    ok.


-spec get_verification_attempt_key(GatewayResponse :: gateway_response()) ->
    {ok, maybe(binary())} | {error, any()}.
get_verification_attempt_key(GatewayResponse) ->
    #gateway_response{
        gateway_id = GatewayId,
        gateway = Gateway
    } = GatewayResponse,
    GatewayResponseKey = gateway_response_key(Gateway, GatewayId),
    {ok, VerificationAttemptKey} = q(["HGET", GatewayResponseKey, ?FIELD_VERIFICATION_ATTEMPT]),
    {ok, VerificationAttemptKey}.


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


-spec invalidate_old_attempts(Phone :: phone()) -> ok | {error, any()}.
invalidate_old_attempts(Phone) ->
    {ok, VerificationAttemptList} = get_verification_attempt_list(Phone),
    RedisCommands = lists:map(
        fun({AttId, _TS}) ->
            ["HSET", verification_attempt_key(Phone, AttId), ?FIELD_VALID, "0"]
        end, VerificationAttemptList),
    qp(RedisCommands),
    ok.


-spec get_verification_success(Phone :: phone(), AttemptId :: binary()) -> boolean().
get_verification_success(Phone, AttemptId) ->
    VerificationAttemptKey = verification_attempt_key(Phone, AttemptId),
    {ok, Res} = q(["HGET", VerificationAttemptKey, ?FIELD_VERIFICATION_SUCCESS]),
    util_redis:decode_boolean(Res, false).


-spec get_verification_attempt_summary(Phone :: phone(), AttemptId :: binary()) -> gateway_response().
get_verification_attempt_summary(Phone, AttemptId) ->
    {ok, Res} = q(["HMGET", verification_attempt_key(Phone, AttemptId), ?FIELD_SENDER, ?FIELD_METHOD,
        ?FIELD_STATUS, ?FIELD_VERIFICATION_SUCCESS, ?FIELD_LANGID]),
    [Sender, Method, Status, Success, LangId] = Res,
    case {Sender, Method, Status, Success, LangId} of
        {undefined, _, _, _, _} -> #gateway_response{};
        {_, _, _, _, _} ->
                #gateway_response{
                    gateway = util:to_atom(Sender),
                    method = decode_method(Method),
                    status = util:to_atom(Status),
                    verified = util_redis:decode_boolean(Success, false),
                    lang_id = LangId
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
    q(["GET" , phone_key(Phone)]).


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

-spec add_phone_pattern(PhonePattern :: binary(), Timestamp :: integer()) -> ok  | {error, any()}.
add_phone_pattern(PhonePattern, Timestamp) ->
    _Results = qp([
        ["MULTI"],
        ["HINCRBY", phone_pattern_key(PhonePattern), ?FIELD_COUNT, 1],
        ["HSET", phone_pattern_key(PhonePattern), ?FIELD_TIMESTAMP, util:to_binary(Timestamp)],
        ["EXPIRE", phone_pattern_key(PhonePattern), ?TTL_PHONE_PATTERN],
        ["EXEC"]
    ]),
    ok.


-spec get_phone_pattern_info(PhonePattern :: binary()) -> {ok, {maybe(integer()), maybe(integer())}}  | {error, any()}.
get_phone_pattern_info(PhonePattern) ->
    {ok, [Count, Timestamp]} = q(["HMGET", phone_pattern_key(PhonePattern), ?FIELD_COUNT, ?FIELD_TIMESTAMP]),
    {ok, {util_redis:decode_int(Count), util_redis:decode_ts(Timestamp)}}.


-spec delete_phone_pattern(PhonePattern :: binary()) -> ok  | {error, any()}.
delete_phone_pattern(PhonePattern) ->
    _Results = q(["DEL", phone_pattern_key(PhonePattern)]),
    ok.


-spec add_static_key(StaticKey :: binary(), Timestamp :: integer()) -> ok  | {error, any()}.
add_static_key(StaticKey, Timestamp) ->
    Trunc = truncate_static_key(StaticKey),
    _Results = qp([
        ["MULTI"],
        ["HINCRBY", remote_static_key(Trunc), ?FIELD_COUNT, 1],
        ["HSET", remote_static_key(Trunc), ?FIELD_TIMESTAMP, util:to_binary(Timestamp)],
        ["EXPIRE", remote_static_key(Trunc), ?TTL_REMOTE_STATIC_KEY],
        ["EXEC"]
    ]),
    ok.


-spec get_static_key_info(StaticKey :: binary()) -> {ok, {maybe(integer()), maybe(integer())}}  | {error, any()}.
get_static_key_info(StaticKey) ->
    Trunc = truncate_static_key(StaticKey),
    {ok, [Count, Timestamp]} = q(["HMGET", remote_static_key(Trunc), ?FIELD_COUNT, ?FIELD_TIMESTAMP]),
    {ok, {util_redis:decode_int(Count), util_redis:decode_ts(Timestamp)}}.


-spec delete_static_key(StaticKey :: binary()) -> ok  | {error, any()}.
delete_static_key(StaticKey) ->
    Trunc = truncate_static_key(StaticKey),
    _Results = q(["DEL", remote_static_key(Trunc)]),
    ok.

-spec add_phone_cc(CC :: binary(), Timestamp :: integer()) -> ok  | {error, any()}.
add_phone_cc(CC, Timestamp) ->
    _Results = qp([
        ["MULTI"],
        ["HINCRBY", phone_cc_key(CC), ?FIELD_COUNT, 1],
        ["HSET", phone_cc_key(CC), ?FIELD_TIMESTAMP, util:to_binary(Timestamp)],
        ["EXPIRE", phone_cc_key(CC), ?TTL_PHONE_CC],
        ["EXEC"]
    ]),
    ok.


-spec get_phone_cc_info(CC :: binary()) -> {ok, {maybe(integer()), maybe(integer())}}  | {error, any()}.
get_phone_cc_info(CC) ->
    {ok, [Count, Timestamp]} = q(["HMGET", phone_cc_key(CC), ?FIELD_COUNT, ?FIELD_TIMESTAMP]),
    {ok, {util_redis:decode_int(Count), util_redis:decode_ts(Timestamp)}}.


-spec delete_phone_cc(CC :: binary()) -> ok  | {error, any()}.
delete_phone_cc(CC) ->
    _Results = q(["DEL", phone_cc_key(CC)]),
    ok.


-spec add_hashcash_challenge(Challenge :: binary()) -> ok  | {error, any()}.
add_hashcash_challenge(Challenge) ->
    _Results = q(["SET", hashcash_key(Challenge), "1", "EX", ?TTL_HASHCASH]),
    ok.


-spec delete_hashcash_challenge(Challenge :: binary()) -> ok  | not_found.
delete_hashcash_challenge(Challenge) ->
    case q(["DEL", hashcash_key(Challenge)]) of
        {ok, <<"0">>} -> not_found;
        {ok, <<"1">>} -> ok
    end.


-spec add_phone_code_attempt(Phone :: binary(), Timestamp :: integer()) -> integer().
add_phone_code_attempt(Phone, Timestamp) ->
    Key = phone_attempt_key(Phone, Timestamp),
    {ok, [Res, _]} = multi_exec([
        ["INCR", Key],
        ["EXPIRE", Key, ?TTL_PHONE_ATTEMPT]
    ]),
    util_redis:decode_int(Res).

-spec get_phone_code_attempts(Phone :: binary(), Timestamp :: integer()) -> maybe(integer()).
get_phone_code_attempts(Phone, Timestamp) ->
    Key = phone_attempt_key(Phone, Timestamp),
    {ok, Res} = q(["GET", Key]),
    case Res of
        undefined -> 0;
        Res -> util:to_integer(Res)
    end.

truncate_static_key(StaticKey) ->
    <<Trunc:?TRUNC_STATIC_KEY_LENGTH/binary, _Rem/binary>> = StaticKey,
    Trunc.

q(Command) -> ecredis:q(ecredis_phone, Command).
qp(Commands) -> ecredis:qp(ecredis_phone, Commands).
qmn(Commands) -> ecredis:qmn(ecredis_phone, Commands).

% TODO(nikola): this is the same as model_groups. We should move this in the ecredis
multi_exec(Commands) ->
    WrappedCommands = lists:append([[["MULTI"]], Commands, [["EXEC"]]]),
    Results = qp(WrappedCommands),
    [ExecResult | _Rest] = lists:reverse(Results),
    ExecResult.

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


-spec phone_pattern_key(PhonePattern :: binary()) -> binary().
phone_pattern_key(PhonePattern) ->
    <<?PHONE_PATTERN_KEY/binary, <<"{">>/binary, PhonePattern/binary, <<"}">>/binary>>.


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

-spec remote_static_key(StaticKey :: binary()) -> binary().
remote_static_key(StaticKey) ->
    <<?REMOTE_STATIC_KEY/binary, "{", StaticKey/binary, "}:">>.


-spec phone_cc_key(CC :: binary()) -> binary().
phone_cc_key(CC) ->
    <<?PHONE_CC_KEY/binary, "{", CC/binary, "}:">>.


-spec hashcash_key(Challenge :: binary()) -> binary().
hashcash_key(Challenge) ->
    <<?HASHCASH_KEY/binary, "{", Challenge/binary, "}:">>.

-spec phone_attempt_key(Phone :: binary(), Timestamp :: integer() ) -> binary().
phone_attempt_key(Phone, Timestamp) ->
    Day = util:to_binary(util:to_integer(Timestamp / ?DAYS)),
    <<?PHONE_ATTEMPT_KEY/binary, "{", Phone/binary, "}:", Day/binary>>.


