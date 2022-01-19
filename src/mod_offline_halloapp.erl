%%%----------------------------------------------------------------------
%%% File    : mod_offline_halloapp.erl
%%%
%%% Copyright (C) 2020 halloappinc.
%%%
%%% TODO(murali@): Add limit for max number of messages per user. 
%%% TODO(murali@): add more unit tests for offline window.
%%%----------------------------------------------------------------------
%% TODO(murali@): rename this file later.
-module(mod_offline_halloapp).
-author('murali').
-behaviour(gen_mod).
-behaviour(gen_server).

-include("ha_types.hrl").
-include("logger.hrl").
-include("packets.hrl").
-include("offline_message.hrl").
-include("ejabberd_sm.hrl").
-include("proc.hrl").
-include_lib("stdlib/include/assert.hrl").

-define(MESSAGE_RESPONSE_TIMEOUT_MILLISEC, 30000).  %% 30 seconds.
-define(MAX_RETRY_COUNT, 5).
-define(RETRY_INTERVAL_MILLISEC, 10000).    %% 10 sec.
-define(MAX_OFFLINE_CHECK_RETRIES, 3).      %% 3 times - every 10 seconds.
-define(MAX_WINDOW, 64).
-define(RATE_COEFFECIENT, 8).


-type state() :: halloapp_c2s:state().
%% gen_mod API.
-export([start/2, stop/1, reload/3, mod_options/1, depends/2]).
%% gen_server API
-export([init/1, terminate/2, code_change/3, handle_call/3, handle_cast/2, handle_info/2]).

%% API and hooks.
-export([
    store_message_hook/1,
    user_receive_packet/1,
    user_send_ack/2,
    c2s_session_opened/1,
    user_session_activated/3,
    remove_user/2,
    count_user_messages/1,
    offline_queue_check/5,
    route_offline_messages/4  % DEBUG
]).


%%%===================================================================
%%% gen_mod API
%%%===================================================================

start(Host, Opts) ->
    ?INFO("mod_offline_halloapp: start", []),
    gen_mod:start_child(?MODULE, Host, Opts, ?PROC()).

stop(_Host) ->
    ?INFO("mod_offline_halloapp: stop", []),
    gen_mod:stop_child(?PROC()).

depends(_Host, _Opts) ->
    [].

reload(_Host, _NewOpts, _OldOpts) ->
    ok.

mod_options(_Host) ->
    [].



%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([Host|_]) ->
    ?INFO("mod_offline_halloapp: init", []),
    ejabberd_hooks:add(store_message_hook, Host, ?MODULE, store_message_hook, 50),
    ejabberd_hooks:add(user_receive_packet, Host, ?MODULE, user_receive_packet, 100),
    ejabberd_hooks:add(user_send_ack, Host, ?MODULE, user_send_ack, 50),
    ejabberd_hooks:add(c2s_session_opened, Host, ?MODULE, c2s_session_opened, 100),
    ejabberd_hooks:add(user_session_activated, Host, ?MODULE, user_session_activated, 50),
    ejabberd_hooks:add(offline_queue_check, Host, ?MODULE, offline_queue_check, 50),
    ejabberd_hooks:add(remove_user, Host, ?MODULE, remove_user, 50),
    {ok, #{host => Host}}.


terminate(_Reason, #{host := Host} = _State) ->
    ?INFO("mod_offline_halloapp: terminate", []),
    ejabberd_hooks:delete(store_message_hook, Host, ?MODULE, store_message_hook, 50),
    ejabberd_hooks:delete(user_receive_packet, Host, ?MODULE, user_receive_packet, 100),
    ejabberd_hooks:delete(user_send_ack, Host, ?MODULE, user_send_ack, 50),
    ejabberd_hooks:delete(c2s_session_opened, Host, ?MODULE, c2s_session_opened, 100),
    ejabberd_hooks:delete(user_session_activated, Host, ?MODULE, user_session_activated, 50),
    ejabberd_hooks:delete(offline_queue_check, Host, ?MODULE, offline_queue_check, 50),
    ejabberd_hooks:delete(remove_user, Host, ?MODULE, remove_user, 50),
    ok.


code_change(_OldVsn, State, _Extra) ->
    ?INFO("mod_offline_halloapp: code_change", []),
    {ok, State}.


handle_call(Request, _From, State) ->
    ?ERROR("invalid request: ~p", [Request]),
    {reply, {error, bad_arg}, State}.


handle_cast({ping, Id, Ts, From}, State) ->
    util_monitor:send_ack(self(), From, {ack, Id, Ts, self()}),
    {noreply, State};

handle_cast({setup_push_timer, Message}, State) ->
    util:send_after(?MESSAGE_RESPONSE_TIMEOUT_MILLISEC, {push_offline_message, Message}),
    {noreply, State};

handle_cast(Request, State) ->
    ?ERROR("invalid request: ~p", [Request]),
    {noreply, State}.


handle_info({push_offline_message, Message}, #{host := _ServerHost} = State) ->
    MsgId = pb:get_id(Message),
    Uid = pb:get_to(Message),
    case model_messages:get_message(Uid, MsgId) of
        {ok, undefined} ->
            ?INFO("Uid: ~s, message has been acked, Id: ~s", [Uid, MsgId]);
        _ ->
            ?INFO("Uid: ~s, no ack for message Id: ~s, trying a push", [Uid, MsgId]),
            ejabberd_sm:push_message(Message)
    end,
    {noreply, State};

handle_info(Request, State) ->
    ?ERROR("invalid request: ~p", [Request]),
    {noreply, State}.


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%      API and hooks
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

-spec user_send_ack(State :: state(), Packet :: pb_ack()) -> state().
user_send_ack(State, #pb_ack{id = MsgId, from_uid = Uid} = Ack) ->
    ?INFO("Uid: ~s, Ack_MsgId: ~s", [Uid, MsgId]),

    EndOfQueueMsgId = maps:get(end_of_queue_msg_id, State, undefined),
    case MsgId =:= EndOfQueueMsgId of
        true ->
            ?INFO("Uid: ~s, processed entire queue: ~p", [Uid, EndOfQueueMsgId]),
            State;
        false ->
            accept_ack(State, Ack)
    end.


-spec accept_ack(State :: state(), Packet :: pb_ack()) -> state().
accept_ack(#{offline_queue_params := #{window := Window, pending_acks  := PendingAcks} = OfflineQueueParams,
        offline_queue_cleared := IsOfflineQueueCleared, mode := Mode} = State,
        #pb_ack{id = MsgId, from_uid = Uid} = Ack) ->
    Server = util:get_host(),
    {ok, OfflineMessage} = model_messages:get_message(Uid, MsgId),
    case OfflineMessage of
        undefined ->
            ?WARNING("missing a message on redis, msg_id: ~s, from_uid: ~s", [MsgId, Uid]),
            State;
        _ ->
            RetryCount = OfflineMessage#offline_message.retry_count,
            %% This is the retryCount for sending it the next time,
            %% so, we need to decrement this value for our counters.
            CountTagValue = "retry" ++ util:to_list(RetryCount - 1),
            stat:count("HA/offline_messages", "retry_count", 1, [{count, CountTagValue}]),
            ok = model_messages:ack_message(Uid, MsgId),
            ejabberd_hooks:run(user_ack_packet, Server, [Ack, OfflineMessage]),
            State1 = State#{offline_queue_params := OfflineQueueParams#{pending_acks => PendingAcks - 1}},

            ?INFO("Uid: ~s, Window: ~p, PendingAcks: ~p, offline_queue_cleared: ~p",
                    [Uid, Window, PendingAcks, IsOfflineQueueCleared]),

            case Mode of
                active -> check_offline_queue(State1);
                passive -> State1
            end
    end.


store_message_hook(#pb_msg{retry_count = RetryCount} = Message) when RetryCount > 0 ->
    Message;
store_message_hook(#pb_msg{id = MsgID, to_uid = Uid} = Message) ->
    ?INFO("To Uid: ~s MsgID: ~s storing message", [Uid, MsgID]),
    store_message(Message),
    Message.


%% When we receive packets: we need to check the mode of the user's session.
%% When the mode is passive: we should not route any message stanzas to the client (old or new).
user_receive_packet({#pb_msg{id = MsgId, to_uid = ToUid, retry_count = RetryCount} = Message,
        #{mode := passive} = State} = _Acc) ->
    ?INFO("Uid: ~s MsgId: ~s, retry_count: ~p", [ToUid, MsgId, RetryCount]),
    ejabberd_sm:push_message(Message),
    {stop, {drop, State}};

%% If OfflineQueue is cleared: send all messages.
%% If not, send only offline messages: they have retry_count >=1.

user_receive_packet({#pb_msg{id = MsgId, to_uid = ToUid, payload = #pb_end_of_queue{}} = _Message,
        _State} = Acc) ->
    ?INFO("Uid: ~s MsgId: ~s sending end-of-queue", [ToUid, MsgId]),
    Acc;
user_receive_packet({#pb_msg{id = MsgId, to_uid = ToUid, retry_count = RetryCount} = Message,
        #{mode := active, offline_queue_cleared := false} = State} = _Acc) when RetryCount =:= 0 ->
    ?INFO("Uid: ~s MsgId: ~s, retry_count: ~p", [ToUid, MsgId, RetryCount]),
    setup_push_timer(Message),
    {stop, {drop, State}};
user_receive_packet({#pb_msg{id = MsgId, to_uid = ToUid, retry_count = RetryCount} = Message,
        #{mode := active, offline_queue_cleared := true} = _State} = Acc) when RetryCount =:= 0 ->
    ?INFO("Uid: ~s MsgId: ~s, retry_count: ~p", [ToUid, MsgId, RetryCount]),
    setup_push_timer(Message),
    model_messages:mark_sent(ToUid, MsgId),
    Acc;
user_receive_packet(Acc) ->
    Acc.


-spec c2s_session_opened(State :: state()) -> state().
c2s_session_opened(#{mode := active, user := Uid, client_version := ClientVersion} = State) ->
    cleanup_offline_queue(Uid, ClientVersion),
    send_offline_messages(State);
c2s_session_opened(#{mode := passive} = State) ->
    State.


-spec offline_queue_check(Uid :: binary(), Server :: binary(),
    LastMsgOrderId :: integer(), RetryCount :: integer(), LeftOverMsgIds :: [binary()]) -> ok.
offline_queue_check(#{client_version := ClientVersion} = State, Uid,
        LastMsgOrderId, RetryCount, LeftOverMsgIds) when RetryCount >= ?MAX_OFFLINE_CHECK_RETRIES ->
    ?INFO("Uid: ~s", [Uid]),
    case model_messages:get_user_messages(Uid, LastMsgOrderId + 1, undefined) of
        {ok, true, []} -> ok;
        {ok, true, OfflineMessages} ->
            %% Applying filter to remove certain messages.
            FilteredMsgs1 = filter_offline_messages(ClientVersion, OfflineMessages),
            %% Filter messages again that were just sent to the client.
            FilteredMsgs2 = filter_sent_messages(FilteredMsgs1),
            FilteredMsgIds2 = extract_msgid(FilteredMsgs2),
            NumFilteredMsgs = length(FilteredMsgs2),
            LeftOverMsgIdSet = sets:from_list(LeftOverMsgIds),
            case NumFilteredMsgs > 0 of
                true ->
                    lists:foreach(
                        fun(MsgId) ->
                            case sets:is_element(MsgId, LeftOverMsgIdSet) of
                                true -> ?ERROR("Uid: ~s, still has MsgId: ~p in their offline queue", [Uid, MsgId]);
                                false -> ok
                            end
                        end, FilteredMsgIds2),
                    %% TODO: make this info if we dont encounter any errors in 1 month [10-01-2021].
                    ?WARNING("Uid: ~s has ~p messages to send again after offline queue cleared.",
                        [Uid, NumFilteredMsgs]);
                false ->
                    ?INFO("Uid: ~s has ~p messages to send again after offline queue cleared.",
                        [Uid, NumFilteredMsgs])
            end,
            do_send_offline_messages(Uid, FilteredMsgs2)
    end,
    State;
offline_queue_check(#{client_version := ClientVersion} = State, Uid,
        LastMsgOrderId, RetryCount, _LeftOverMsgIds) ->
    ?INFO("Uid: ~s", [Uid]),
    NewLeftOverMsgIds = case model_messages:get_user_messages(Uid, LastMsgOrderId + 1, undefined) of
        {ok, true, []} -> [];
        {ok, true, OfflineMessages} ->
            %% Applying filter to remove certain messages.
            FilteredMsgs1 = filter_offline_messages(ClientVersion, OfflineMessages),
            %% Filter messages again that were just sent to the client.
            FilteredMsgs2 = filter_sent_messages(FilteredMsgs1),
            FilteredMsgIds2 = extract_msgid(FilteredMsgs2),
            FilteredMsgIds2
    end,
    schedule_offline_queue_check(Uid, LastMsgOrderId, RetryCount + 1, NewLeftOverMsgIds),
    State.


-spec user_session_activated(State :: state(), Uid :: binary(), SID :: sid()) -> state().
user_session_activated(State, _Uid, _SID) ->
    send_offline_messages(State).


remove_user(User, _Server) ->
    ?INFO("removing all user messages, uid: ~s", [User]),
    model_messages:remove_all_user_messages(User).


-spec count_user_messages(UserId :: binary()) -> integer().
count_user_messages(User) ->
    {ok, Res} = model_messages:count_user_messages(User),
    Res.


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%      internal functions
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

-spec filter_sent_messages([offline_message()]) -> [offline_message()].
filter_sent_messages(OfflineMessages) ->
    %% Filter messages again that were just sent to the client.
    %% Note that, we do this "additional filter" for the sent field only after offline queue
    %% is marked as cleared. so any messages on the past connection will be sent to the
    %% client before the queue is cleared in this new connection.
    lists:filter(
        fun(#offline_message{sent = Sent}) -> Sent =/= true end,
        OfflineMessages).


-spec extract_msgid([offline_message()]) -> [binary()].
extract_msgid(OfflineMessages) ->
    lists:map(
        fun(#offline_message{msg_id = MsgId}) -> MsgId end,
        OfflineMessages).


-spec check_offline_queue(State :: state()) -> state().
check_offline_queue(#{offline_queue_params := #{window := Window,
        pending_acks  := PendingAcks} = _OfflineQueueParams,
        offline_queue_cleared := IsOfflineQueueCleared, mode := active} = State) ->
    %% If OfflineQueue is cleared: nothing to do.
    %% If OfflineQueue is not cleared: we need to check if we can send more messages.
    %% We check if the window size is undefined or
    %% if number of messages outstanding is half the window size.
    case IsOfflineQueueCleared of
        true -> State;
        false ->
            case (Window =:= undefined orelse PendingAcks =< Window / 2) of
                true ->
                    send_offline_messages(State);
                false ->
                    State
            end
    end.


-spec route_offline_messages(UserId :: binary(), Server :: binary(),
        LastMsgOrderId :: integer(), State :: state()) -> ok.
route_offline_messages(UserId, Server, LastMsgOrderId, State) ->
    ?INFO("Uid: ~s start", [UserId]),
    {ok, _, OfflineMessages} = model_messages:get_user_messages(UserId, LastMsgOrderId, undefined),
    % TODO: We need to rate limit the number of offline messages we send at once.
    % TODO: get metrics about the number of retries

    ClientVersion = maps:get(client_version, State, undefined),
    %% Applying filter to remove certain messages.
    FilteredOfflineMessages = filter_offline_messages(ClientVersion, OfflineMessages),
    ?INFO("Uid: ~s has ~p offline messages after order_id: ~p",
            [UserId, length(FilteredOfflineMessages), LastMsgOrderId]),
    lists:foreach(fun route_offline_message/1, FilteredOfflineMessages),

    % TODO: maybe don't increment the retry count on all the messages
    % we can increment the retry count on just the first X
    mark_sent_and_increment_retry_counts(UserId, FilteredOfflineMessages),

    NewLastMsgOrderId = get_last_msg_order_id(FilteredOfflineMessages, LastMsgOrderId),

    %% mark offline queue to be cleared, send eoq msg and timer, update state.
    mark_offline_queue_cleared(UserId, Server, NewLastMsgOrderId, State).


-spec send_offline_messages(State :: state()) -> state().
send_offline_messages(#{mode := passive} = State) ->
    State;
send_offline_messages(#{mode := active, user := Uid, server := Server,
        offline_queue_params := #{window := Window, pending_acks := PendingAcks,
        last_msg_order_id := LastMsgOrderId} = OfflineQueueParams} = State) ->
    case model_messages:get_user_messages(Uid, LastMsgOrderId + 1, Window) of
        {ok, true, []} ->
            %% mark offline queue to be cleared, send eoq msg and timer, update state.
            mark_offline_queue_cleared(Uid, Server, LastMsgOrderId, State);

        {ok, EndOfQueue, OfflineMessages} ->
            ClientVersion = maps:get(client_version, State, undefined),
            %% Applying filter to remove certain messages.
            FilteredOfflineMessages = filter_offline_messages(ClientVersion, OfflineMessages),
            TotalNumOfMessages = length(FilteredOfflineMessages),
            case FilteredOfflineMessages of
                [] ->
                    %% we dont know if there are more messages in the queue..
                    %% so recursively call to either send atleast 1 message or mark the queue as cleared.
                    send_offline_messages(State);

                [#offline_message{retry_count = RetryCount} | _Rest] ->
                    {NewWindow, NumMsgToSend} = compute_new_params(RetryCount, Window,
                            PendingAcks, TotalNumOfMessages),

                    %% We could have less messages to send than the actual window size.
                    %% This should be okay for now.
                    %% https://github.com/HalloAppInc/halloapp-ejabberd/pull/1057#discussion_r553727406
                    %% TODO(murali@): observe logs if this happens too often.

                    {MsgsToSend, RemMsgs} = case length(FilteredOfflineMessages) >= NumMsgToSend of
                        true -> lists:split(NumMsgToSend, FilteredOfflineMessages);
                        false -> {FilteredOfflineMessages, []}
                    end,
                    ?INFO("Uid: ~s sending some ~p offline messages", [Uid, length(MsgsToSend)]),
                    do_send_offline_messages(Uid, MsgsToSend),
                    NewLastMsgOrderId = get_last_msg_order_id(MsgsToSend, LastMsgOrderId),
                    State1 = State#{
                        offline_queue_params => OfflineQueueParams#{
                            window => NewWindow,
                            pending_acks => PendingAcks + length(MsgsToSend),
                            last_msg_order_id => NewLastMsgOrderId
                        }
                    },
                    %% If we are sending all the messages read and
                    %% if there are no more messages in the queue, then mark the queue as cleared.
                    case EndOfQueue =:= true andalso RemMsgs =:= [] of
                        true ->
                            %% mark offline queue to be cleared, send eoq msg and timer, update state.
                            mark_offline_queue_cleared(Uid, Server, NewLastMsgOrderId, State1);
                        false -> State1
                    end
            end
    end.


-spec do_send_offline_messages(Uid :: binary(), MsgsToSend :: [pb_msg()]) -> ok.
do_send_offline_messages(Uid, MsgsToSend) ->
    lists:foreach(fun route_offline_message/1, MsgsToSend),
    mark_sent_and_increment_retry_counts(Uid, MsgsToSend),
    ok.


%% This function must always run on user's c2s process only!
-spec mark_offline_queue_cleared(UserId :: binary(), Server :: binary(),
        NewLastMsgOrderId :: integer(), State :: state()) -> state().
mark_offline_queue_cleared(UserId, Server, NewLastMsgOrderId, State) ->
    %% TODO(murali@): use end_of_queue marker for time to clear out the offline queue.
    EndOfQueueMsgId = send_end_of_queue_marker(UserId, Server),
    schedule_offline_queue_check(UserId, NewLastMsgOrderId, 0, []),
    ejabberd_hooks:run(offline_queue_cleared, Server, [UserId, NewLastMsgOrderId]),
    State#{offline_queue_cleared => true, end_of_queue_msg_id => EndOfQueueMsgId}.


%% We check our offline_queue after sometime even after we flush out all messages.
%% Because other processes could end up storing some messages here.
-spec schedule_offline_queue_check(UserId :: binary(), NewLastMsgOrderId :: integer(),
    RetryCount :: integer(), LeftOverMsgIds :: [binary()]) -> ok.
schedule_offline_queue_check(UserId, NewLastMsgOrderId, RetryCount, LeftOverMsgIds) ->
    ?INFO("Uid: ~s, send offline_queue_check notice to c2s process: ~p", [UserId, self()]),
    erlang:send_after(?RETRY_INTERVAL_MILLISEC, self(), {offline_queue_check, NewLastMsgOrderId, RetryCount, LeftOverMsgIds}),
    ok.


-spec send_end_of_queue_marker(UserId :: binary(), Server :: binary()) -> MsgId :: binary().
send_end_of_queue_marker(UserId, _Server) ->
    MsgId = util_id:new_msg_id(),
    EndOfQueueMarker = #pb_msg{
        id = MsgId,
        to_uid = UserId,
        payload = #pb_end_of_queue{}
    },
    ejabberd_router:route(EndOfQueueMarker),
    MsgId.


-spec route_offline_message(OfflineMessage :: maybe(offline_message())) -> ok.
route_offline_message(undefined) ->
    ok;
route_offline_message(#offline_message{
        msg_id = MsgId, to_uid = ToUid, retry_count = RetryCount, message = Message, protobuf = true}) ->
    try
        case enif_protobuf:decode(Message, pb_packet) of
            {error, DecodeReason} ->
                ?ERROR("MsgId: ~p, Message: ~p, failed decoding reason: ~s", [MsgId, Message, DecodeReason]);
            #pb_packet{stanza = MsgPacket} ->
                adjust_and_send_message(MsgPacket, RetryCount),
                ?INFO("sending offline message Uid: ~s MsgId: ~p rc: ~p", [ToUid, MsgId, RetryCount])
        end
    catch
        Class : Reason : Stacktrace ->
            ?ERROR("failed parsing: ~s", [
                    lager:pr_stacktrace(Stacktrace, {Class, Reason})])
    end,
    ok.


-spec adjust_and_send_message(Message :: pb_msg(), RetryCount :: integer()) -> ok.
adjust_and_send_message(#pb_msg{} = Message, RetryCount) ->
    Message1 = Message#pb_msg{retry_count = RetryCount},
    ejabberd_router:route(Message1),
    ok.


-spec filter_offline_messages(ClientVersion :: binary(),
    OfflineMessages :: [offline_message()]) -> [offline_message()].
filter_offline_messages(ClientVersion, OfflineMessages) ->
    OfflineMessages1 = lists:filter(
        fun(OfflineMessage) ->
            filter_messages(ClientVersion, OfflineMessage)
        end, OfflineMessages),
    %% TODO: Temporarily filter out duplicate content-ids from android clients to all users.
    OfflineMessages2 = filter_duplicate_content(OfflineMessages1),
    OfflineMessages2.


%% Filter undefined messages
filter_messages(_ClientVersion, undefined) ->
    ?INFO("invalid message, should have expired"),
    false;

%% Withhold messages after max retry_count.
filter_messages(_ClientVersion, #offline_message{msg_id = MsgId, to_uid = Uid,
        retry_count = RetryCount, message = Message})
        when RetryCount > ?MAX_RETRY_COUNT ->
    IsDev = dev_users:is_dev_uid(Uid),
    ?WARNING("Withhold offline message after max retries, Uid: ~p, IsDev: ~p, msg_id: ~p, message(b64): ~p",
            [Uid, IsDev, MsgId, base64url:encode(Message)]),
    ok = model_messages:withhold_message(Uid, MsgId),
    stat:count("HA/offline_messages", "drop"),
    false;

%% Check version rules for this user, version and filter accordingly.
filter_messages(ClientVersion, #offline_message{msg_id = MsgId,
        to_uid = Uid, content_type = ContentType} = OfflineMessage) ->
    Server = util:get_host(),
    case ejabberd_hooks:run_fold(offline_message_version_filter, Server, allow,
            [Uid, ClientVersion, OfflineMessage]) of
        allow -> true;
        deny ->
            ?INFO("Uid: ~s, MsgId: ~p dont deliver message: invalid content: ~p for client version: ~p",
                    [Uid, MsgId, ContentType, ClientVersion]),
            ok = model_messages:ack_message(Uid, MsgId),
            stat:count("HA/offline_messages", "dont_deliver"),
            false
    end.


%% Filter duplicate content from android clients.
%% We need to go through all messages and keep only unique content-ids from clients.
%% So we construct a map of content-ids and ignore the messages that have the some content.
%% TODO(murali@): Fix this after talking to the android team.
filter_duplicate_content(OfflineMessages) ->
    {FinalOfflineMessagesToSend, _} = lists:foldr(
        fun(OfflineMessage, {OfflineMessagesToSend, ContentKeyMap} = Acc) ->
            MsgId = OfflineMessage#offline_message.msg_id,
            Uid = OfflineMessage#offline_message.to_uid,
            FromUid = OfflineMessage#offline_message.from_uid,
            ContentType = OfflineMessage#offline_message.content_type,
            MsgBin = OfflineMessage#offline_message.message,

            case util:is_android_user(FromUid) of
                true ->
                    case ContentType =:= pb_group_feed_item orelse ContentType =:= pb_feed_item of
                        true ->
                            case enif_protobuf:decode(MsgBin, pb_packet) of
                                {error, DecodeReason} ->
                                    ?ERROR("MsgId: ~p, Message: ~p, failed decoding reason: ~s", [MsgId, MsgBin, DecodeReason]),
                                    ok = model_messages:ack_message(Uid, MsgId),
                                    Acc;
                                #pb_packet{stanza = MsgPacket} ->
                                    ContentId = util:get_content_id(MsgPacket#pb_msg.payload),
                                    case maps:is_key(ContentId, ContentKeyMap) of
                                        true ->
                                            ?INFO("Filtering out MsgId: ~p ContentId: ~p Uid: ~p fromUid: ~p", [MsgId, ContentId, Uid, FromUid]),
                                            ok = model_messages:ack_message(Uid, MsgId),
                                            Acc;
                                        false ->
                                            NewOfflineMessagesToSend = [OfflineMessage | OfflineMessagesToSend],
                                            NewContentKeyMap = ContentKeyMap#{ContentId => 1},
                                            {NewOfflineMessagesToSend, NewContentKeyMap}
                                    end
                            end;
                        false ->
                            NewOfflineMessagesToSend = [OfflineMessage | OfflineMessagesToSend],
                            {NewOfflineMessagesToSend, ContentKeyMap}
                    end;
                false ->
                    NewOfflineMessagesToSend = [OfflineMessage | OfflineMessagesToSend],
                    {NewOfflineMessagesToSend, ContentKeyMap}
            end
        end, {[], #{}}, OfflineMessages),
    FinalOfflineMessagesToSend.


-spec cleanup_offline_queue(Uid :: binary(), ClientVersion :: binary()) -> ok.
cleanup_offline_queue(Uid, ClientVersion) ->
    case model_messages:get_user_messages(Uid, 0, undefined) of
        {ok, true, []} -> ok;
        {ok, true, OfflineMessages} ->
            %% Applying filter to remove certain messages.
            filter_offline_messages(ClientVersion, OfflineMessages)
    end.


-spec mark_sent_and_increment_retry_counts(UserId :: uid, OfflineMsgs :: [maybe(offline_message())]) -> ok.
mark_sent_and_increment_retry_counts(UserId, OfflineMsgs) ->
    MsgIds = lists:filtermap(
        fun (undefined) -> false;
            (Msg) -> {true, Msg#offline_message.msg_id}
        end, OfflineMsgs),
    ok = model_messages:mark_sent_and_increment_retry_counts(UserId, MsgIds),
    ok.


-spec store_message(Message :: pb_msg()) -> ok.
store_message(#pb_msg{payload = #pb_end_of_queue{}} = _Message) ->
    %% ignore storing end_of_queue marker packets.
    ok;
store_message(#pb_msg{payload = #pb_wake_up{}} = _Message) ->
    %% ignore storing SMSApp client wakeup packets.
    ok;
store_message(#pb_msg{} = Message) ->
    ok = model_messages:store_message(Message),
    ok.


-spec compute_new_params(RetryCount :: integer(), Window :: maybe(integer()),
        PendingAcks :: integer(), TotalNumOfMessages :: integer()) -> {maybe(integer()), integer()}.
compute_new_params(RetryCount, Window, PendingAcks, TotalNumOfMessages) ->
    NewWindow = case RetryCount > 1 of
        true ->
            ExpDrop = round(math:pow(?RATE_COEFFECIENT, RetryCount - 2)),
            ExpWindow = max(1, ?MAX_WINDOW / ExpDrop),
            case Window of
                undefined -> round(ExpWindow);
                _ -> round(min(ExpWindow, Window * ?RATE_COEFFECIENT))
            end;
        false ->
            undefined
    end,
    NumMsgToSend = case NewWindow of
        undefined -> TotalNumOfMessages;
        _ ->
            max(NewWindow - PendingAcks, 1)
    end,
    {NewWindow, round(NumMsgToSend)}.


-spec setup_push_timer(Message :: pb_msg()) -> ok.
setup_push_timer(Message) ->
    gen_server:cast(?PROC(), {setup_push_timer, Message}).


-spec get_last_msg_order_id(MsgsToSend :: [offline_message()],
        PrevLastMsgOrderId :: maybe(integer())) -> maybe(integer()).
get_last_msg_order_id(MsgsToSend, PrevLastMsgOrderId) ->
    NewLastMsgOrderId = case MsgsToSend of
        [] -> PrevLastMsgOrderId;
        _ ->
            LastOfflineMessage = lists:last(MsgsToSend),
            LastOfflineMessage#offline_message.order_id
    end,
    NewLastMsgOrderId.

