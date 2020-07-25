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
-include("redis_keys.hrl").

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
    get_sms_code_ttl/1
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
-define(FIELD_RECEIPT, <<"rec">>).
-define(TTL_SMS_CODE, 86400).
-define(MAX_SLOTS, 8).


-spec add_sms_code(Phone :: binary(), Code :: binary(), Timestamp :: integer(),
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


-spec add_sms_code_receipt(Phone :: binary(), Receipt :: binary()) -> ok  | {error, any()}.
add_sms_code_receipt(Phone, Receipt) ->
    _Results = q(["HSET", code_key(Phone), ?FIELD_RECEIPT, Receipt]),
    ok.


-spec delete_sms_code(Phone :: binary()) -> ok  | {error, any()}.
delete_sms_code(Phone) ->
    {ok, _Res} = q(["DEL", code_key(Phone)]),
    ok.


-spec get_sms_code(Phone :: binary()) -> {ok, undefined | binary()} | {error, any()}.
get_sms_code(Phone) ->
    {ok, Res} = q(["HGET", code_key(Phone), ?FIELD_CODE]),
    {ok, Res}.


-spec get_sms_code_timestamp(Phone :: binary()) -> {ok, undefined | integer()} | {error, any()}.
get_sms_code_timestamp(Phone) ->
    {ok, Res} = q(["HGET" , code_key(Phone), ?FIELD_TIMESTAMP]),
    {ok, binary_to_integer(Res)}.


-spec get_sms_code_sender(Phone :: binary()) -> {ok, undefined | binary()} | {error, any()}.
get_sms_code_sender(Phone) ->
    {ok, Res} = q(["HGET" , code_key(Phone), ?FIELD_SENDER]),
    {ok, Res}.


-spec get_sms_code_receipt(Phone :: binary()) -> {ok, undefined | binary()} | {error, any()}.
get_sms_code_receipt(Phone) ->
    {ok, Res} = q(["HGET" , code_key(Phone), ?FIELD_RECEIPT]),
    {ok, Res}.


-spec get_sms_code_ttl(Phone :: binary()) -> {ok, undefined | integer()} | {error, any()}.
get_sms_code_ttl(Phone) ->
    {ok, Res} = q(["TTL" , code_key(Phone)]),
    {ok, binary_to_integer(Res)}.


-spec add_phone(Phone :: binary(), Uid :: binary()) -> ok  | {error, any()}.
add_phone(Phone, Uid) ->
    {ok, _Res} = q(["SET", phone_key(Phone), Uid]),
    ok.


-spec delete_phone(Phone :: binary()) -> ok  | {error, any()}.
delete_phone(Phone) ->
    {ok, _Res} = q(["DEL", phone_key(Phone)]),
    ok.


-spec get_uid(Phone :: binary()) -> {ok, undefined | binary()} | {error, any()}.
get_uid(Phone) ->
    {ok, Res} = q(["GET" , phone_key(Phone)]),
    {ok, Res}.


-spec get_uids(Phones :: [binary()]) -> {ok, [binary()]} | {error, any()}.
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


-spec order_phones_by_keys(Phones :: binary()) -> {[binary()], [binary()]}.
order_phones_by_keys(Phones) ->
    DefaultMap = get_default_slot_map(?MAX_SLOTS, #{}),
    order_phones_into_slots(Phones, DefaultMap).


-spec phone_key(Phone :: binary()) -> binary().
phone_key(Phone) ->
    Slot = get_slot(Phone),
    phone_key(Phone, Slot).


% TODO: migrate the data to make the keys take look like pho:{5}:1555555555
% TODO: also migrate to the crc16_redis
-spec phone_key(Phone :: binary(), Slot :: integer()) -> binary().
phone_key(Phone, Slot) ->
    <<?PHONE_KEY/binary, <<"{">>/binary, Slot/integer, <<"}:">>/binary, Phone/binary>>.


-spec order_phones_into_slots(Phones :: binary(), SlotsMap :: map()) -> {[binary()], [binary()]}.
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


-spec get_slot(Phone :: binary()) -> integer().
get_slot(Phone) ->
    crc16:crc16(binary_to_list(Phone)) rem ?MAX_SLOTS.


-spec get_default_slot_map(Slot :: integer(), Map :: map()) -> map().
get_default_slot_map(1, Map) ->
    Map#{0 => {[], []}};
get_default_slot_map(Num, Map) ->
    get_default_slot_map(Num - 1, Map#{Num - 1 => {[], []}}).


-spec code_key(Phone :: binary()) -> binary().
code_key(Phone) ->
    <<?PHONE_KEY/binary, <<"{">>/binary, Phone/binary, <<"}">>/binary>>.




