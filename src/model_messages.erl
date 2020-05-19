%%%------------------------------------------------------------------------------------
%%% File: model_messages.erl
%%% Copyright (C) 2020, HalloApp, Inc.
%%%
%%% This model handles all the redis db queries that are related with user-messages.
%%%
%%%------------------------------------------------------------------------------------
-module(model_messages).
-author('murali').
-behavior(gen_server).
-behavior(gen_mod).

-include("logger.hrl").
-include("xmpp.hrl").
-include("offline_message.hrl").

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
    store_message/1,
    ack_message/2,
    remove_all_user_messages/1,
    count_user_messages/1,
    get_message/2,
    increment_retry_count/2,
    get_retry_count/2,
    get_all_user_messages/1
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

-define(MESSAGE_KEY, <<"msg:">>).
-define(MESSAGE_QUEUE_KEY, <<"mq:">>).
-define(MESSAGE_ORDER_KEY, <<"ord:">>).
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
    gen_server:call(get_proc(), {store_message, ToUid, FromUid, MsgId, ContentType, Message});
store_message(_ToUid, _FromUid, _MsgId, _ContentType, Message) ->
    ?ERROR_MSG("Invalid message format: ~p: use binary format", [Message]).


-spec increment_retry_count(Uid :: binary(), MsgId :: binary()) -> {ok, integer()} | {error, any()}.
increment_retry_count(Uid, MsgId) ->
    gen_server:call(get_proc(), {increment_retry_count, Uid, MsgId}).


-spec get_retry_count(Uid :: binary(), MsgId :: binary()) -> {ok, integer()} | {error, any()}.
get_retry_count(Uid, MsgId) ->
    gen_server:call(get_proc(), {get_retry_count, Uid, MsgId}).


-spec get_message(Uid :: binary(), MsgId :: binary()) -> {ok, message()} | {error, any()}.
get_message(Uid, MsgId) ->
    gen_server:call(get_proc(), {get_message, Uid, MsgId}).


-spec get_all_user_messages(Uid :: binary()) -> {ok, [message()]} | {error, any()}.
get_all_user_messages(Uid) ->
    gen_server:call(get_proc(), {get_all_user_messages, Uid}).


-spec ack_message(Uid :: binary(), MsgId :: binary()) -> ok | {error, any()}.
ack_message(Uid, MsgId) ->
    gen_server:call(get_proc(), {ack_message, Uid, MsgId}).


%%TODO(murali@): Update this to use a lua script.
-spec remove_all_user_messages(Uid :: binary()) -> ok | {error, any()}.
remove_all_user_messages(Uid) ->
    gen_server:call(get_proc(), {remove_all_user_messages, Uid}).


-spec count_user_messages(Uid :: binary()) -> {ok, integer()} | {error, any()}.
count_user_messages(Uid) ->
    gen_server:call(get_proc(), {count_user_messages, Uid}).


%%====================================================================
%% gen_server callbacks
%%====================================================================

init(_Stuff) ->
    process_flag(trap_exit, true),
    {ok, redis_messages_client}.

handle_call({store_message, ToUid, FromUid, MsgId, ContentType, Message}, _From, Redis) ->
    {ok, OrderId} = q(["INCR", message_order_key(ToUid)]),
    MessageKey = message_key(ToUid, MsgId),
    Fields = [
        ?FIELD_TO, ToUid,
        ?FIELD_MESSAGE, Message,
        ?FIELD_CONTENT_TYPE, ContentType,
        ?FIELD_RETRY_COUNT, 0,
        ?FIELD_ORDER, OrderId],
    Fields2 = case FromUid of
                undefined -> Fields;
                _ -> [?FIELD_FROM, FromUid | Fields]
            end,
    Fields3 = ["HSET", MessageKey | Fields2],
    PipeCommands = [
            ["MULTI"],
            Fields3,
            ["ZADD", message_queue_key(ToUid), OrderId, MsgId],
            ["EXEC"]],
    _Results = qp(PipeCommands),
    {reply, ok, Redis};

handle_call({ack_message, Uid, MsgId}, _From, Redis) ->
    _Results = qp(
            [["MULTI"],
            ["ZREM", message_queue_key(Uid), MsgId],
            ["DEL", message_key(Uid, MsgId)],
            ["EXEC"]]),
    {reply, ok, Redis};

handle_call({remove_all_user_messages, Uid}, _From, Redis) ->
    {ok, MsgIds} = q(["ZRANGEBYLEX", message_queue_key(Uid), "-", "+"]),
    MessageKeys = message_keys(Uid, MsgIds),
    case MessageKeys of
        [] -> ok;
        _ -> {ok, _MRes} = q(["DEL" | MessageKeys])
    end,
    {ok, _QRes} = q(["DEL", message_queue_key(Uid)]),
    {reply, ok, Redis};

handle_call({count_user_messages, Uid}, _From, Redis) ->
    {ok, Res} = q(["ZCARD", message_queue_key(Uid)]),
    {reply, {ok, binary_to_integer(Res)}, Redis};

handle_call({increment_retry_count, Uid, MsgId}, _From, Redis) ->
    {ok, RetryCount} = q(["HINCRBY", message_key(Uid, MsgId), ?FIELD_RETRY_COUNT, 1]),
    {reply, {ok, binary_to_integer(RetryCount)}, Redis};

handle_call({get_retry_count, Uid, MsgId}, _From, Redis) ->
    {ok, RetryCount} = q(["HGET", message_key(Uid, MsgId), ?FIELD_RETRY_COUNT]),
    Res = case RetryCount of
            undefined -> undefined;
            _ -> binary_to_integer(RetryCount)
        end,
    {reply, {ok, Res}, Redis};

handle_call({get_message, Uid, MsgId}, _From, Redis) ->
    Result = q(["HGETALL", message_key(Uid, MsgId)]),
    OfflineMessage = parse_result(Result),
    {reply, {ok, OfflineMessage}, Redis};

handle_call({get_all_user_messages, Uid}, _From, Redis) ->
    {ok, MsgIds} = q(["ZRANGEBYLEX", message_queue_key(Uid), "-", "+"]),
    Messages = get_all_user_messages(Uid, MsgIds),
    {reply, {ok, Messages}, Redis}.


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


handle_cast(_Message, Redis) -> {noreply, Redis}.
handle_info(_Message, Redis) -> {noreply, Redis}.
terminate(_Reason, _Redis) -> ok.
code_change(_OldVersion, Redis, _Extra) -> {ok, Redis}.


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


