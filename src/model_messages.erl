%%%------------------------------------------------------------------------------------
%%% File: model_messages.erl
%%% Copyright (C) 2020, HalloApp, Inc.
%%%
%%% This model handles all the redis db queries that are related with user-messages.
%%%
%%%------------------------------------------------------------------------------------
-module(model_messages).
-author("murali").
-behavior(gen_server).
-behavior(gen_mod).

-include("logger.hrl").
-include("xmpp.hrl").

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
    store_message/2,
    store_message/3,
    ack_message/2,
    remove_all_user_messages/1,
    count_user_messages/1,
    get_message/2,
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
-define(FIELD_MESSAGE, <<"m">>).
-define(FIELD_ORDER, <<"ord">>).


-spec store_message(Message :: message()) -> ok | {error, any()}.
store_message(Message) ->
    #jid{user = Uid} = Message#message.to,
    MsgId = Message#message.id,
    store_message(Uid, MsgId, Message).


-spec store_message(Uid :: binary(), Message :: message()) -> ok | {error, any()}.
store_message(Uid, Message) ->
    MsgId = Message#message.id,
    store_message(Uid, MsgId, Message).


-spec store_message(Uid :: binary(), MsgId :: binary(),
                    Message :: message()) -> ok | {error, any()}.
store_message(Uid, MsgId, Message) when is_record(Message, message) ->
    store_message(Uid, MsgId, fxml:element_to_binary(xmpp:encode(Message)));
store_message(Uid, MsgId, Message) when is_binary(Message)->
    gen_server:call(get_proc(), {store_message, Uid, MsgId, Message});
store_message(_Uid, _MsgId, Message) ->
    ?ERROR_MSG("Invalid message format: ~p: use binary format", [Message]).


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


handle_call({store_message, Uid, MsgId, Message}, _From, Redis) ->
    {ok, OrderId} = q(["INCR", message_order_key(Uid)]),
    _Results = qp(
            [["MULTI"],
            ["HSET", message_key(Uid, MsgId),
                ?FIELD_TO, Uid,
                ?FIELD_MESSAGE, Message,
                ?FIELD_ORDER, OrderId],
            ["ZADD", message_queue_key(Uid), OrderId, MsgId],
            ["EXEC"]]),
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
    {ok, _MRes} = q(["DEL" | MessageKeys]),
    {ok, _QRes} = q(["DEL", message_queue_key(Uid)]),
    {reply, ok, Redis};


handle_call({count_user_messages, Uid}, _From, Redis) ->
    {ok, Res} = q(["ZCARD", message_queue_key(Uid)]),
    {reply, {ok, binary_to_integer(Res)}, Redis};

handle_call({get_message, Uid, MsgId}, _From, Redis) ->
    {ok, Res} = q(["HGET", message_key(Uid, MsgId), ?FIELD_MESSAGE]),
    Message = case Res of
                undefined -> undefined;
                _ -> Res
            end,
    {reply, {ok, Message}, Redis};

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
    lists:map(
        fun({ok, [Message]}) ->
            case Message of
                undefined -> undefined;
                _ -> Message
            end
        end, MessageResults).


get_message_commands([], Commands) ->
   lists:reverse(Commands);
get_message_commands([MessageKey | Rest], Commands) ->
    Command = ["HMGET", MessageKey, ?FIELD_MESSAGE],
    get_message_commands(Rest, [Command | Commands]).



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




