%%%------------------------------------------------------------------------------------
%%% File: model_phone.erl
%%% Copyright (C) 2020, HalloApp, Inc.
%%%
%%% This model handles all the redis db queries that are related with phone numbers.
%%%
%%%------------------------------------------------------------------------------------
-module(model_phone).
-author("murali").
-behavior(gen_server).
-behavior(gen_mod).

-include("logger.hrl").

%% Export all functions for unit tests
-ifdef(TEST).
-compile(export_all).
-endif.

-export([start_link/0]).
%% gen_mod callbacks
-export([start/2, stop/1, depends/2, mod_options/1]).
%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, terminate/2, handle_info/2, code_change/3]).


%% API
-export([
    add_sms_code/4,
    add_sms_code_receipt/2,
    delete_sms_code/1,
    get_sms_code/1,
    add_phone/2,
    delete_phone/1,
    get_uid/1,
    get_uids/1
]).

start_link() ->
    gen_server:start_link({local, get_proc()}, ?MODULE, [], []).

%%====================================================================
%% gen_mod callbacks
%%====================================================================

start(Host, Opts) ->
    gen_mod:start_child(?MODULE, Host, Opts, get_proc()).

stop(_Host) ->
    gen_mod:stop_child(get_proc()).

depends(_Host, _Opts) ->
    [{mod_redis, hard}].

mod_options(_Host) ->
    [].

get_proc() ->
    gen_mod:get_module_proc(global, ?MODULE).

%%====================================================================
%% API
%%====================================================================

-define(PHONE_KEY, <<"pho:">>).
-define(CODE_KEY, <<"cod:">>).
-define(FIELD_CODE, <<"cod">>).
-define(FIELD_TIMESTAMP, <<"ts">>).
-define(FIELD_SENDER, <<"sen">>).
-define(FIELD_RECEIPT, <<"rec">>).
-define(TTL_SMS_CODE, 86400).
-define(MAX_SLOTS, 8).


-spec add_sms_code(Phone :: binary(), Code :: binary(), Timestamp :: integer(),
                Sender :: binary()) -> ok  | {error, any()}.
add_sms_code(Phone, Code, Timestamp, Sender) ->
    gen_server:call(get_proc(), {add_sms_code, Phone, Code, Timestamp, Sender}).


-spec add_sms_code_receipt(Phone :: binary(), Receipt :: binary()) -> ok  | {error, any()}.
add_sms_code_receipt(Phone, Receipt) ->
    gen_server:call(get_proc(), {add_sms_code_receipt, Phone, Receipt}).


-spec delete_sms_code(Phone :: binary()) -> ok  | {error, any()}.
delete_sms_code(Phone) ->
    gen_server:call(get_proc(), {delete_sms_code, Phone}).


-spec add_phone(Phone :: binary(), Uid :: binary()) -> ok  | {error, any()}.
add_phone(Phone, Uid) ->
    gen_server:call(get_proc(), {add_phone, Phone, Uid}).


-spec delete_phone(Phone :: binary()) -> ok  | {error, any()}.
delete_phone(Phone) ->
    gen_server:call(get_proc(), {delete_phone, Phone}).


-spec get_sms_code(Phone :: binary()) -> {ok, undefined | binary()} | {error, any()}.
get_sms_code(Phone) ->
    gen_server:call(get_proc(), {get_sms_code, Phone}).


-spec get_sms_code_timestamp(Phone :: binary()) -> {ok, undefined | integer()} | {error, any()}.
get_sms_code_timestamp(Phone) ->
    gen_server:call(get_proc(), {get_sms_code_timestamp, Phone}).


-spec get_sms_code_sender(Phone :: binary()) -> {ok, undefined | binary()} | {error, any()}.
get_sms_code_sender(Phone) ->
    gen_server:call(get_proc(), {get_sms_code_sender, Phone}).


-spec get_sms_code_receipt(Phone :: binary()) -> {ok, undefined | binary()} | {error, any()}.
get_sms_code_receipt(Phone) ->
    gen_server:call(get_proc(), {get_sms_code_receipt, Phone}).


-spec get_sms_code_ttl(Phone :: binary()) -> {ok, undefined | integer()} | {error, any()}.
get_sms_code_ttl(Phone) ->
    gen_server:call(get_proc(), {get_sms_code_ttl, Phone}).


-spec get_uid(Phone :: binary()) -> {ok, undefined | binary()} | {error, any()}.
get_uid(Phone) ->
    gen_server:call(get_proc(), {get_uid, Phone}).


-spec get_uids(Phones :: [binary()]) -> {ok, [binary()]} | {error, any()}.
get_uids(Phones) ->
    gen_server:call(get_proc(), {get_uids, Phones}).


%%====================================================================
%% gen_server callbacks
%%====================================================================

init(_Stuff) ->
    process_flag(trap_exit, true),
    {ok, redis_phone_client}.


handle_call({add_sms_code, Phone, Code, Timestamp, Sender}, _From, Redis) ->
    _Results = q([["MULTI"],
                    ["HSET", code_key(Phone),
                    ?FIELD_CODE, Code,
                    ?FIELD_TIMESTAMP, integer_to_binary(Timestamp),
                    ?FIELD_SENDER, Sender],
                    ["EXPIRE", code_key(Phone), ?TTL_SMS_CODE],
                    ["EXEC"]]),
    {reply, ok, Redis};

handle_call({add_sms_code_receipt, Phone, Receipt}, _From, Redis) ->
    _Results = q(["HSET", code_key(Phone), ?FIELD_RECEIPT, Receipt]),
    {reply, ok, Redis};

handle_call({delete_sms_code, Phone}, _From, Redis) ->
    {ok, _Res} = q(["DEL", code_key(Phone)]),
    {reply, ok, Redis};

handle_call({get_sms_code, Phone}, _From, Redis) ->
    {ok, Res} = q(["HGET", code_key(Phone), ?FIELD_CODE]),
    {reply, {ok, Res}, Redis};

handle_call({get_sms_code_timestamp, Phone}, _From, Redis) ->
    {ok, Res} = q(["HGET" , code_key(Phone), ?FIELD_TIMESTAMP]),
    {reply, {ok, binary_to_integer(Res)}, Redis};

handle_call({get_sms_code_sender, Phone}, _From, Redis) ->
    {ok, Res} = q(["HGET" , code_key(Phone), ?FIELD_SENDER]),
    {reply, {ok, Res}, Redis};

handle_call({get_sms_code_receipt, Phone}, _From, Redis) ->
    {ok, Res} = q(["HGET" , code_key(Phone), ?FIELD_RECEIPT]),
    {reply, {ok, Res}, Redis};

handle_call({get_sms_code_ttl, Phone}, _From, Redis) ->
    {ok, Res} = q(["TTL" , code_key(Phone)]),
    {reply, {ok, binary_to_integer(Res)}, Redis};

handle_call({add_phone, Phone, Uid}, _From, Redis) ->
    {ok, _Res} = q(["SET", phone_key(Phone), Uid]),
    {reply, ok, Redis};

handle_call({delete_phone, Phone}, _From, Redis) ->
    {ok, _Res} = q(["DEL", phone_key(Phone)]),
    {reply, ok, Redis};

handle_call({get_uid, Phone}, _From, Redis) ->
    {ok, Res} = q(["GET" , phone_key(Phone)]),
    {reply, {ok, Res}, Redis};

handle_call({get_uids, Phones}, _From, Redis) ->
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
    {reply, {ok, PhonesUidsMap}, Redis}.


handle_cast(_Message, Redis) -> {noreply, Redis}.
handle_info(_Message, Redis) -> {noreply, Redis}.
terminate(_Reason, _Redis) -> ok.
code_change(_OldVersion, Redis, _Extra) -> {ok, Redis}.


q(Command) ->
    {ok, Result} = gen_server:call(redis_phone_client, {q, Command}),
    Result.


-spec order_phones_by_keys(Phones :: binary()) -> {[binary()], [binary()]}.
order_phones_by_keys(Phones) ->
    DefaultMap = get_default_slot_map(?MAX_SLOTS, #{}),
    order_phones_into_slots(Phones, DefaultMap).


-spec phone_key(Phone :: binary()) -> binary().
phone_key(Phone) ->
    Slot = get_slot(Phone),
    phone_key(Phone, Slot).


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




