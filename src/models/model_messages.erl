%%%------------------------------------------------------------------------------------
%%% File: model_messages.erl
%%% Copyright (C) 2020, HalloApp, Inc.
%%%
%%% This model handles all the redis db queries that are related with user-messages.
%%%
%%%------------------------------------------------------------------------------------
-module(model_messages).
-author('murali').
-behavior(gen_mod).

-include("logger.hrl").
-include("xmpp.hrl").
-include("offline_message.hrl").
-include("redis_keys.hrl").
-include("ha_types.hrl").
-include("time.hrl").
-include("expiration.hrl").

%% Export all functions for unit tests
-ifdef(TEST).
-compile(export_all).
-endif.

%% gen_mod callbacks
-export([start/2, stop/1, depends/2, mod_options/1]).


%% API
-export([
    store_message/1,
    ack_message/2,
    withhold_message/2,
    remove_all_user_messages/1,
    count_user_messages/1,
    get_message/2,
    increment_retry_count/2,
    increment_retry_counts/2,
    get_retry_count/2,
    get_all_user_messages/1,
    get_user_messages/3,
    record_push_sent/2
]).


%%====================================================================
%% gen_mod callbacks
%%====================================================================


start(_Host, _Opts) ->
    _Res = get_store_message_script(),
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

-define(LUA_SCRIPT, <<"store_message.lua">>).
-define(FIELD_TO, <<"tuid">>).
-define(FIELD_FROM, <<"fuid">>).
-define(FIELD_MESSAGE, <<"m">>).
-define(FIELD_ORDER, <<"ord">>).
-define(FIELD_CONTENT_TYPE, <<"ct">>).
-define(FIELD_RETRY_COUNT, <<"rc">>).
-define(FIELD_PROTOBUF, <<"pb">>).

-spec store_message(Message :: message()) -> ok | {error, any()}.
store_message(Message) ->
    #jid{user = ToUid} = Message#message.to,
    #jid{user = FromUid} = Message#message.from,
    MsgId = Message#message.id,
    ContentType = util:get_payload_type(Message),
    store_message(ToUid, FromUid, MsgId, ContentType, Message).


store_message(ToUid, FromUid, MsgId, ContentType, Message) when is_record(Message, message) ->
    IsDevUser = dev_users:is_dev_uid(ToUid),
    {IsInPbFormat, MessageBin} = case IsDevUser of
        true ->
            case enif_protobuf:encode(packet_parser:xmpp_to_proto(Message)) of
                {error, Reason} ->
                    ?ERROR("failed encoding packet: ~p, reason: ~p", [Message, Reason]),
                    {false, fxml:element_to_binary(xmpp:encode(Message))};
                PbBin ->
                    {true, PbBin}
            end;
        false ->
            {false, fxml:element_to_binary(xmpp:encode(Message))}
    end,
    store_message(ToUid, FromUid, MsgId, ContentType, MessageBin, IsInPbFormat);

store_message(ToUid, FromUid, MsgId, ContentType, Message) when is_binary(Message) ->
    store_message(ToUid, FromUid, MsgId, ContentType, Message, false).

store_message(ToUid, FromUid, MsgId, ContentType, Message, IsInPbFormat) when is_binary(Message) ->
    %% we also cleanup reverse index of messages.
    MessageOrderKey = binary_to_list(message_order_key(ToUid)),
    MessageKey = binary_to_list(message_key(ToUid, MsgId)),
    MessageQueueKey = binary_to_list(message_queue_key(ToUid)),
    Script = get_store_message_script(),
    PbValue = util_redis:encode_boolean(IsInPbFormat),
    {ok, _Res} = q(["EVAL", Script, 3, MessageOrderKey, MessageKey, MessageQueueKey,
            ToUid, Message, ContentType, FromUid, MsgId, ?MSG_EXPIRATION, PbValue]),
    ok;

store_message(_ToUid, _FromUid, _MsgId, _ContentType, Message, _IsDevUser) ->
    ?ERROR("Invalid message format: ~p: use binary format", [Message]).


-spec increment_retry_count(Uid :: uid(), MsgId :: binary()) -> {ok, integer()} | {error, any()}.
increment_retry_count(Uid, MsgId) ->
    {ok, RetryCount} = q(["HINCRBY", message_key(Uid, MsgId), ?FIELD_RETRY_COUNT, 1]),
    {ok, binary_to_integer(RetryCount)}.


-spec increment_retry_counts(Uid :: uid(), MsgIds :: [binary()]) -> ok.
increment_retry_counts(_Uid, []) -> ok;
increment_retry_counts(Uid, MsgIds) ->
    Commands = [["HINCRBY", message_key(Uid, MsgId), ?FIELD_RETRY_COUNT, 1] || MsgId <- MsgIds],
    _Results = qp(Commands),
    ok.


-spec get_retry_count(Uid :: uid(), MsgId :: binary()) -> {ok, integer()} | {error, any()}.
get_retry_count(Uid, MsgId) ->
    {ok, RetryCount} = q(["HGET", message_key(Uid, MsgId), ?FIELD_RETRY_COUNT]),
    Res = case RetryCount of
        undefined -> undefined;
        _ -> binary_to_integer(RetryCount)
    end,
    {ok, Res}.


-spec get_message(Uid :: uid(), MsgId :: binary()) -> {ok, offline_message()} | {error, any()}.
get_message(Uid, MsgId) ->
    Result = q(["HGETALL", message_key(Uid, MsgId)]),
    OfflineMessage = parse_result({MsgId, Result}),
    {ok, OfflineMessage}.


-spec ack_message(Uid :: uid(), MsgId :: binary()) -> ok | {error, any()}.
ack_message(Uid, MsgId) ->
    _Results = qp(
            [["MULTI"],
            ["ZREM", message_queue_key(Uid), MsgId],
            ["DEL", message_key(Uid, MsgId)],
            ["EXEC"]]),
    ok.


-spec withhold_message(Uid :: uid(), MsgId :: binary()) -> ok | {error, any()}.
withhold_message(Uid, MsgId) ->
    [{ok, _}, Result] = qp([
        ["ZREM", message_queue_key(Uid), MsgId],
        ["RENAME", message_key(Uid, MsgId), withhold_message_key(Uid, MsgId)]]),
    case Result of
        {ok, _} -> ok;
        {error, _} = Err -> Err
    end.


%%TODO(murali@): Update this to use a lua script.
-spec remove_all_user_messages(Uid :: uid()) -> ok | {error, any()}.
remove_all_user_messages(Uid) ->
    {ok, MsgIds} = q(["ZRANGEBYLEX", message_queue_key(Uid), "-", "+"]),
    MessageKeys = message_keys(Uid, MsgIds),
    case MessageKeys of
        [] -> ok;
        _ -> {ok, _MRes} = q(["DEL" | MessageKeys])
    end,
    {ok, _QRes} = q(["DEL", message_queue_key(Uid)]),
    ok.


-spec count_user_messages(Uid :: uid()) -> {ok, integer()} | {error, any()}.
count_user_messages(Uid) ->
    {ok, Res} = q(["ZCARD", message_queue_key(Uid)]),
    {ok, binary_to_integer(Res)}.


-spec get_all_user_messages(Uid :: uid()) -> {ok, [message()]} | {error, any()}.
get_all_user_messages(Uid) ->
    {ok, MsgIds} = q(["ZRANGEBYLEX", message_queue_key(Uid), "-", "+"]),
    Messages = get_all_user_messages(Uid, MsgIds),
    {ok, Messages}.


-spec get_user_messages(Uid :: uid(), MinOrderId :: integer(),
        Limit :: maybe(integer())) -> {ok, [message()]} | {error, any()}.
get_user_messages(Uid, MinOrderId, Limit) ->
    Part1 = ["ZRANGEBYSCORE", message_queue_key(Uid), MinOrderId, "+inf"],
    Part2 = case Limit of
        undefined -> [];
        _ -> ["LIMIT", 0, Limit]
    end,
    Command = Part1 ++ Part2,
    {ok, MsgIds} = q(Command),
    Messages = get_all_user_messages(Uid, MsgIds),
    {ok, Messages}.


-spec get_all_user_messages(Uid :: uid(), MsgIds :: [binary()]) -> [maybe(offline_message())].
get_all_user_messages(_Uid, []) ->
    [];
get_all_user_messages(Uid, MsgIds) ->
    MessageKeys = message_keys(Uid, MsgIds),
    Commands = get_message_commands(MessageKeys, []),
    MessageResults = qp(Commands),
    MsgIdsAndResults = lists:zip(MsgIds, MessageResults),
    OfflineMessages = lists:map(fun parse_result/1, MsgIdsAndResults),
    EmptyMessageIds = [MsgId || {MsgId, Result} <- MsgIdsAndResults, Result =:= {ok, []}],
    delete_empty_messages(Uid, EmptyMessageIds),
    OfflineMessages.


delete_empty_messages(_Uid, []) -> ok;
delete_empty_messages(Uid, MsgIds) -> {ok, _} = q(["ZREM", message_queue_key(Uid) | MsgIds]).


-spec record_push_sent(Uid :: uid(), ContentId :: binary()) -> boolean().
record_push_sent(Uid, ContentId) ->
    [{ok, Res}, _Result] = qp([["SETNX", push_sent_key(Uid, ContentId), util:now()],
        ["EXPIRE", push_sent_key(Uid, ContentId), ?PUSH_EXPIRATION]]),
    binary_to_integer(Res) == 1.


get_message_commands([], Commands) ->
   lists:reverse(Commands);
get_message_commands([MessageKey | Rest], Commands) ->
    Command = ["HGETALL", MessageKey],
    get_message_commands(Rest, [Command | Commands]).


%% TODO: passing the empty offline_message record makes dialyzer think that all its fields
%% should be defined as maybe()
-spec parse_result({binary(), {ok, [binary()]}}) -> maybe(offline_message()).
parse_result({MsgId, {ok, FieldValuesList}}) ->
    parse_fields(MsgId, FieldValuesList).


-spec parse_fields(MsgId :: binary(), [binary()]) -> maybe(offline_message()).
parse_fields(_MsgId, []) ->
    undefined;
parse_fields(MsgId, FieldValuesList) ->
    MsgDataMap = util:list_to_map(FieldValuesList),
    Message = maps:get(?FIELD_MESSAGE, MsgDataMap, undefined),
    PbValue = maps:get(?FIELD_PROTOBUF, MsgDataMap, undefined),
    IsInPbFormat = util_redis:decode_boolean(PbValue, false),
    case Message of
        undefined -> undefined;
        _ ->
            RetryCount = binary_to_integer(maps:get(?FIELD_RETRY_COUNT, MsgDataMap)),
            ToUid = maps:get(?FIELD_TO, MsgDataMap),
            #offline_message{
                msg_id = MsgId,
                message = Message,
                to_uid = ToUid,
                from_uid = maps:get(?FIELD_FROM, MsgDataMap, undefined),
                content_type = maps:get(?FIELD_CONTENT_TYPE, MsgDataMap),
                retry_count = RetryCount,
                order_id = binary_to_integer(maps:get(?FIELD_ORDER, MsgDataMap)),
                protobuf = IsInPbFormat
            }
    end.


-spec get_store_message_script() -> binary().
get_store_message_script() ->
    Script = persistent_term:get(?LUA_SCRIPT, default),
    case Script of
        default ->
            {ok, Script2} = read_lua(),
            ok = persistent_term:put(?LUA_SCRIPT, Script2),
            Script2;
        _ ->
            Script
    end.

-spec read_lua() -> {ok, binary()} | {error, file:posix()}.
read_lua() ->
    FileName = filename:join(misc:lua_dir(), ?LUA_SCRIPT),
    file:read_file(FileName).


q(Command) -> ecredis:q(ecredis_messages, Command).
qp(Commands) -> ecredis:qp(ecredis_messages, Commands).


-spec message_keys(Uid :: uid(), MsgIds :: [binary()]) -> [binary()].
message_keys(Uid, MsgIds) ->
    [message_key(Uid, MsgId) || MsgId <- MsgIds].


-spec message_key(Uid :: uid(), MsgId :: binary()) -> binary().
message_key(Uid, MsgId) ->
    <<?MESSAGE_KEY/binary, <<"{">>/binary, Uid/binary, <<"}:">>/binary, MsgId/binary>>.


-spec withhold_message_key(Uid :: uid(), MsgId :: binary()) -> binary().
withhold_message_key(Uid, MsgId) ->
    <<?WITHHOLD_MESSAGE_KEY/binary, <<"{">>/binary, Uid/binary, <<"}:">>/binary, MsgId/binary>>.


-spec message_queue_key(Uid :: uid()) -> binary().
message_queue_key(Uid) ->
    <<?MESSAGE_QUEUE_KEY/binary, <<"{">>/binary, Uid/binary, <<"}">>/binary>>.


-spec message_order_key(Uid :: uid()) -> binary().
message_order_key(Uid) ->
    <<?MESSAGE_ORDER_KEY/binary, <<"{">>/binary, Uid/binary, <<"}">>/binary>>.

-spec push_sent_key(Uid :: uid(), ContentId :: binary()) -> binary().
push_sent_key(Uid, ContentId) ->
    <<?PUSH_SENT_KEY/binary, <<"{">>/binary, Uid/binary, <<"}:">>/binary, ContentId/binary>>.


