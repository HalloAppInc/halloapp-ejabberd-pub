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
    remove_all_user_messages/1,
    count_user_messages/1,
    get_message/2,
    increment_retry_count/2,
    get_retry_count/2,
    get_all_user_messages/1
]).


%%====================================================================
%% gen_mod callbacks
%%====================================================================


start(_Host, _Opts) ->
    _Res = get_script(),
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


-spec store_message(Message :: message()) -> ok | {error, any()}.
store_message(Message) ->
    #jid{user = ToUid} = Message#message.to,
    #jid{user = FromUid} = Message#message.from,
    MsgId = Message#message.id,
    ContentType = get_content_type(Message),
    store_message(ToUid, FromUid, MsgId, ContentType, Message).


-spec store_message(ToUid :: binary(), FromUid :: undefined | binary(), MsgId :: binary(),
                    ContentType :: binary(), Message :: message()) -> ok | {error, any()}.
store_message(ToUid, FromUid, MsgId, ContentType, Message) when is_record(Message, message) ->
    store_message(ToUid, FromUid, MsgId, ContentType, fxml:element_to_binary(xmpp:encode(Message)));

store_message(ToUid, FromUid, MsgId, ContentType, Message) when is_binary(Message)->
    MessageOrderKey = binary_to_list(message_order_key(ToUid)),
    MessageKey = binary_to_list(message_key(ToUid, MsgId)),
    MessageQueueKey = binary_to_list(message_queue_key(ToUid)),
    Script = get_script(),
    {ok, _Res} = q(["EVAL", Script, 3, MessageOrderKey, MessageKey, MessageQueueKey,
            ToUid, Message, ContentType, FromUid, MsgId]),
    ok;

store_message(_ToUid, _FromUid, _MsgId, _ContentType, Message) ->
    ?ERROR_MSG("Invalid message format: ~p: use binary format", [Message]).


-spec increment_retry_count(Uid :: binary(), MsgId :: binary()) -> {ok, integer()} | {error, any()}.
increment_retry_count(Uid, MsgId) ->
    {ok, RetryCount} = q(["HINCRBY", message_key(Uid, MsgId), ?FIELD_RETRY_COUNT, 1]),
    {ok, binary_to_integer(RetryCount)}.


-spec get_retry_count(Uid :: binary(), MsgId :: binary()) -> {ok, integer()} | {error, any()}.
get_retry_count(Uid, MsgId) ->
    {ok, RetryCount} = q(["HGET", message_key(Uid, MsgId), ?FIELD_RETRY_COUNT]),
    Res = case RetryCount of
        undefined -> undefined;
        _ -> binary_to_integer(RetryCount)
    end,
    {ok, Res}.


-spec get_message(Uid :: binary(), MsgId :: binary()) -> {ok, message()} | {error, any()}.
get_message(Uid, MsgId) ->
    Result = q(["HGETALL", message_key(Uid, MsgId)]),
    OfflineMessage = parse_result(Result),
    {ok, OfflineMessage}.


-spec get_all_user_messages(Uid :: binary()) -> {ok, [message()]} | {error, any()}.
get_all_user_messages(Uid) ->
    {ok, MsgIds} = q(["ZRANGEBYLEX", message_queue_key(Uid), "-", "+"]),
    Messages = get_all_user_messages(Uid, MsgIds),
    {ok, Messages}.


-spec ack_message(Uid :: binary(), MsgId :: binary()) -> ok | {error, any()}.
ack_message(Uid, MsgId) ->
    _Results = qp(
            [["MULTI"],
            ["ZREM", message_queue_key(Uid), MsgId],
            ["DEL", message_key(Uid, MsgId)],
            ["EXEC"]]),
    ok.


%%TODO(murali@): Update this to use a lua script.
-spec remove_all_user_messages(Uid :: binary()) -> ok | {error, any()}.
remove_all_user_messages(Uid) ->
    {ok, MsgIds} = q(["ZRANGEBYLEX", message_queue_key(Uid), "-", "+"]),
    MessageKeys = message_keys(Uid, MsgIds),
    case MessageKeys of
        [] -> ok;
        _ -> {ok, _MRes} = q(["DEL" | MessageKeys])
    end,
    {ok, _QRes} = q(["DEL", message_queue_key(Uid)]),
    ok.


-spec count_user_messages(Uid :: binary()) -> {ok, integer()} | {error, any()}.
count_user_messages(Uid) ->
    {ok, Res} = q(["ZCARD", message_queue_key(Uid)]),
    {ok, binary_to_integer(Res)}.


-spec get_all_user_messages(Uid :: binary(), MsgIds :: [binary()]) -> [binary()].
get_all_user_messages(_Uid, []) ->
    [];
get_all_user_messages(Uid, MsgIds) ->
    MessageKeys = message_keys(Uid, MsgIds),
    Commands = get_message_commands(MessageKeys, []),
    MessageResults = qp(Commands),
    lists:map(fun parse_result/1, MessageResults).


get_message_commands([], Commands) ->
   lists:reverse(Commands);
get_message_commands([MessageKey | Rest], Commands) ->
    Command = ["HGETALL", MessageKey],
    get_message_commands(Rest, [Command | Commands]).


-spec parse_result({ok, [binary()]}) -> offline_message().
parse_result({ok, FieldValuesList}) ->
    parse_fields(FieldValuesList, #offline_message{}).


-spec parse_fields([binary()],
        OfflineMessage :: offline_message()) -> undefined | offline_message().
parse_fields([], OfflineMessage) ->
    case OfflineMessage#offline_message.message of
        undefined -> undefined;
        _ -> OfflineMessage
    end;
parse_fields([<<"0">>], _OfflineMessage) ->
    undefined;
parse_fields(FieldValuesList, OfflineMessage) ->
    MsgDataMap = util:list_to_map(FieldValuesList),
    Message = maps:get(?FIELD_MESSAGE, MsgDataMap),
    case Message of
        undefined -> undefined;
        _ ->
            OfflineMessage#offline_message{
                message = Message,
                to_uid = maps:get(?FIELD_TO, MsgDataMap),
                from_uid = maps:get(?FIELD_FROM, MsgDataMap, undefined),
                content_type = maps:get(?FIELD_CONTENT_TYPE, MsgDataMap),
                retry_count = binary_to_integer(maps:get(?FIELD_RETRY_COUNT, MsgDataMap))}
    end.


-spec get_content_type(message()) -> binary().
get_content_type(#message{sub_els = SubEls}) ->
    lists:foldl(
        fun(ChildEl, Acc) ->
            case Acc of
                <<>> -> xmpp:get_name(ChildEl);
                _ -> Acc
            end
        end, <<>>, SubEls).


-spec get_script() -> binary().
get_script() ->
    Script = persistent_term:get(?LUA_SCRIPT, default),
    case Script of
        default ->
            {ok, Script2} = misc:read_lua("store_message.lua"),
            ok = persistent_term:put(?LUA_SCRIPT, Script2),
            Script2;
        _ ->
            Script
    end.


q(Command) ->
    {ok, Result} = gen_server:call(redis_messages_client, {q, Command}),
    Result.

qp(Commands) ->
    {ok, Results} = gen_server:call(redis_messages_client, {qp, Commands}),
    Results.


-spec message_keys(Uid :: binary(), MsgIds :: [binary()]) -> [binary()].
message_keys(Uid, MsgIds) ->
    message_keys(Uid, MsgIds, []).


-spec message_keys(Uid :: binary(), MsgIds :: [binary()], Results :: [binary()]) -> [binary()].
message_keys(_Uid, [], Results) ->
    lists:reverse(Results);
message_keys(Uid, [MsgId | Rest], Results) ->
    message_keys(Uid, Rest, [message_key(Uid, MsgId) | Results]).


-spec message_key(Uid :: binary(), MsgId :: binary()) -> binary().
message_key(Uid, MsgId) ->
    <<?MESSAGE_KEY/binary, <<"{">>/binary, Uid/binary, <<"}:">>/binary, MsgId/binary>>.


-spec message_queue_key(Uid :: binary()) -> binary().
message_queue_key(Uid) ->
    <<?MESSAGE_QUEUE_KEY/binary, <<"{">>/binary, Uid/binary, <<"}">>/binary>>.


-spec message_order_key(Uid :: binary()) -> binary().
message_order_key(Uid) ->
    <<?MESSAGE_ORDER_KEY/binary, <<"{">>/binary, Uid/binary, <<"}">>/binary>>.

