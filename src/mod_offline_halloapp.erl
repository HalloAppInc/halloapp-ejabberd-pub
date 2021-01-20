%%%----------------------------------------------------------------------
%%% File    : mod_offline_halloapp.erl
%%%
%%% Copyright (C) 2020 halloappinc.
%%%
%%% TODO(murali@): Add limit for max number of messages per user. 
%%%----------------------------------------------------------------------
%% TODO(murali@): rename this file later.
-module(mod_offline_halloapp).
-author('murali').
-behaviour(gen_mod).
-behaviour(gen_server).

-include("ha_types.hrl").
-include("logger.hrl").
-include("xmpp.hrl").
-include("translate.hrl").
-include("offline_message.hrl").
-include("ejabberd_sm.hrl").
-include_lib("stdlib/include/assert.hrl").

-define(MESSAGE_RESPONSE_TIMEOUT_MILLISEC, 30000).  %% 30 seconds.
-define(MAX_RETRY_COUNT, 10).
-define(RETRY_INTERVAL_MILLISEC, 30000).    %% 30 sec.
-define(MAX_WINDOW, 64).


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
    offline_queue_cleared/3,
    route_offline_messages/4  % DEBUG
]).


%%%===================================================================
%%% gen_mod API
%%%===================================================================

start(Host, Opts) ->
    ?INFO("mod_offline_halloapp: start", []),
    gen_mod:start_child(?MODULE, Host, Opts, get_proc()).

stop(_Host) ->
    ?INFO("mod_offline_halloapp: stop", []),
    gen_mod:stop_child(get_proc()).

depends(_Host, _Opts) ->
    [].

reload(_Host, _NewOpts, _OldOpts) ->
    ok.

mod_options(_Host) ->
    [].

get_proc() ->
    gen_mod:get_module_proc(global, ?MODULE).



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
    ejabberd_hooks:add(offline_queue_cleared, Host, ?MODULE, offline_queue_cleared, 50),
    ejabberd_hooks:add(remove_user, Host, ?MODULE, remove_user, 50),
    {ok, #{host => Host}}.


terminate(_Reason, #{host := Host} = _State) ->
    ?INFO("mod_offline_halloapp: terminate", []),
    ejabberd_hooks:delete(store_message_hook, Host, ?MODULE, store_message_hook, 50),
    ejabberd_hooks:delete(user_receive_packet, Host, ?MODULE, user_receive_packet, 100),
    ejabberd_hooks:delete(user_send_ack, Host, ?MODULE, user_send_ack, 50),
    ejabberd_hooks:delete(c2s_session_opened, Host, ?MODULE, c2s_session_opened, 100),
    ejabberd_hooks:delete(user_session_activated, Host, ?MODULE, user_session_activated, 50),
    ejabberd_hooks:add(offline_queue_cleared, Host, ?MODULE, offline_queue_cleared, 50),
    ejabberd_hooks:delete(remove_user, Host, ?MODULE, remove_user, 50),
    ok.


code_change(_OldVsn, State, _Extra) ->
    ?INFO("mod_offline_halloapp: code_change", []),
    {ok, State}.


handle_call(Request, _From, State) ->
    ?ERROR("invalid request: ~p", [Request]),
    {reply, {error, bad_arg}, State}.


handle_cast({setup_push_timer, Message}, State) ->
    util:send_after(?MESSAGE_RESPONSE_TIMEOUT_MILLISEC, {push_offline_message, Message}),
    {noreply, State};

handle_cast(Request, State) ->
    ?ERROR("invalid request: ~p", [Request]),
    {noreply, State}.


handle_info({push_offline_message, Message}, #{host := _ServerHost} = State) ->
    MsgId = xmpp:get_id(Message),
    #jid{user = Uid} = xmpp:get_to(Message),
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

-spec user_send_ack(State :: state(), Packet :: ack()) -> state().
user_send_ack(State, #ack{id = MsgId, from = #jid{user = Uid, server = _Server}} = Ack) ->
    ?INFO("Uid: ~s, Ack_MsgId: ~s", [Uid, MsgId]),

    EndOfQueueMsgId = maps:get(end_of_queue_msg_id, State, undefined),
    case MsgId =:= EndOfQueueMsgId of
        true ->
            ?INFO("Uid: ~s, processed entire queue: ~p", [Uid, EndOfQueueMsgId]),
            State;
        false ->
            accept_ack(State, Ack)
    end.


-spec accept_ack(State :: state(), Packet :: ack()) -> state().
accept_ack(#{offline_queue_params := #{window := Window, pending_acks  := PendingAcks} = OfflineQueueParams,
        offline_queue_cleared := IsOfflineQueueCleared} = State,
        #ack{id = MsgId, from = #jid{user = Uid, server = Server}} = Ack) ->
    {ok, OfflineMessage} = model_messages:get_message(Uid, MsgId),
    case OfflineMessage of
        undefined ->
            ?WARNING("missing a message on redis, msg_id: ~s, from_uid: ~s", [MsgId, Uid]),
            State;
        _ ->
            RetryCount = OfflineMessage#offline_message.retry_count,
            CountTagValue = "retry" ++ util:to_list(RetryCount),
            stat:count("HA/offline_messages", "retry_count", 1, [{count, CountTagValue}]),
            ok = model_messages:ack_message(Uid, MsgId),
            ejabberd_hooks:run(user_ack_packet, Server, [Ack, OfflineMessage]),
            State1 = State#{offline_queue_params := OfflineQueueParams#{pending_acks => PendingAcks - 1}},

            ?INFO("Uid: ~s, Window: ~p, PendingAcks: ~p, offline_queue_cleared: ~p",
                    [Uid, Window, PendingAcks, IsOfflineQueueCleared]),

            %% If OfflineQueue is cleared: nothing to do.
            %% If OfflineQueue is not cleared: we need to check if we can send more messages.
            %% We check if the window size is undefined or
            %% if number of messages outstanding is half the window size.
            case IsOfflineQueueCleared of
                true -> State;
                false ->
                    ?assert(PendingAcks > 0),
                    case Window =:= undefined orelse PendingAcks - 1 =< Window / 2 of
                        true ->
                            %% Temporary condition: I dont expect this code to run for non-dev users.
                            %% As of now: this code should run only for dev users.
                            case dev_users:is_dev_uid(Uid) of
                                false ->
                                    ?ERROR("Uid: ~s, unexpected c2s state: ~p", [Uid, State]),
                                    State;
                                true ->
                                    send_offline_messages(State1)
                            end;
                        false ->
                            State1
                    end
            end
    end.


store_message_hook(#message{retry_count = RetryCount} = Message) when RetryCount > 0 ->
    Message;
store_message_hook(#message{id = MsgID, to = To} = Message) ->
    Uid = To#jid.luser,
    ?INFO("To Uid: ~s MsgID: ~s storing message", [Uid, MsgID]),
    store_message(Message),
    Message.


%% When we receive packets: we need to check the mode of the user's session.
%% When the mode is passive: we should not route any message stanzas to the client (old or new).
user_receive_packet({#message{id = MsgId, to = To, retry_count = RetryCount} = Message,
        #{mode := passive} = State} = _Acc) ->
    ?INFO("Uid: ~s MsgId: ~s, retry_count: ~p", [To#jid.luser, MsgId, RetryCount]),
    % TODO: Delete this code after upgrade. When everyone has updated to the new code the sender
    % would have stored the message already.
    check_store_message(Message),
    ejabberd_sm:push_message(Message),
    {stop, {drop, State}};

%% If OfflineQueue is cleared: send all messages.
%% If not, send only offline messages: they have retry_count >=1.
user_receive_packet({#message{id = MsgId, to = To, retry_count = RetryCount} = Message,
        #{mode := active, offline_queue_cleared := false} = State} = _Acc) when RetryCount =:= 0 ->
    ?INFO("Uid: ~s MsgId: ~s, retry_count: ~p", [To#jid.luser, MsgId, RetryCount]),
    check_store_message(Message),
    setup_push_timer(Message),
    {stop, {drop, State}};
user_receive_packet({#message{id = MsgId, to = To, retry_count = RetryCount} = Message,
        #{mode := active, offline_queue_cleared := true} = _State} = Acc) when RetryCount =:= 0 ->
    ?INFO("Uid: ~s MsgId: ~s, retry_count: ~p", [To#jid.luser, MsgId, RetryCount]),
    check_store_message(Message),
    setup_push_timer(Message),
    Acc;
user_receive_packet(Acc) ->
    Acc.


-spec c2s_session_opened(State :: state()) -> state().
c2s_session_opened(#{mode := active} = State) ->
    NewState = check_and_send_offline_messages(State),
    NewState;
c2s_session_opened(#{mode := passive} = State) ->
    State.


-spec offline_queue_cleared(Uid :: binary(), Server :: binary(), LastMsgOrderId :: integer()) -> ok.
offline_queue_cleared(Uid, _Server, LastMsgOrderId) ->
    ?INFO("Uid: ~s", [Uid]),
    case model_messages:get_user_messages(Uid, LastMsgOrderId + 1, undefined) of
        {ok, true, []} -> ok;
        {ok, true, OfflineMessages} ->
            FilteredOfflineMessages = lists:filter(fun filter_messages/1, OfflineMessages),
            ?INFO("Uid: ~s has some more new ~p messages after queue cleared.",
                    [Uid, length(FilteredOfflineMessages)]),
            do_send_offline_messages(Uid, FilteredOfflineMessages)
    end,
    ok.


-spec user_session_activated(State :: state(), Uid :: binary(), Server :: binary()) -> state().
user_session_activated(State, _Uid, _Server) ->
    NewState = check_and_send_offline_messages(State),
    NewState.


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


-spec check_and_send_offline_messages(State :: state()) -> state().
check_and_send_offline_messages(#{user := Uid, server := Server} = State) ->
    %% Use the window algorithm to experiment only on dev users initially.
    %% TODO(murali@): update this after ensuring everything works correctly.
    case dev_users:is_dev_uid(Uid) of
        false ->
            route_offline_messages(Uid, Server, 0, State);
        true ->
            send_offline_messages(State)
    end.


-spec route_offline_messages(UserId :: binary(), Server :: binary(),
        LastMsgOrderId :: integer(), State :: state()) -> ok.
route_offline_messages(UserId, Server, LastMsgOrderId, State) ->
    ?INFO("Uid: ~s start", [UserId]),
    {ok, _, OfflineMessages} = model_messages:get_user_messages(UserId, LastMsgOrderId, undefined),
    % TODO: We need to rate limit the number of offline messages we send at once.
    % TODO: get metrics about the number of retries
    FilteredOfflineMessages = lists:filter(fun filter_messages/1, OfflineMessages),
    ?INFO("Uid: ~s has ~p offline messages after order_id: ~p",
            [UserId, length(FilteredOfflineMessages), LastMsgOrderId]),
    lists:foreach(fun route_offline_message/1, FilteredOfflineMessages),

    % TODO: maybe don't increment the retry count on all the messages
    % we can increment the retry count on just the first X
    increment_retry_counts(UserId, FilteredOfflineMessages),

    NewLastMsgOrderId = get_last_msg_order_id(FilteredOfflineMessages, LastMsgOrderId),

    %% mark offline queue to be cleared, send eoq msg and timer, update state.
    mark_offline_queue_cleared(UserId, Server, NewLastMsgOrderId, State).


-spec send_offline_messages(State :: state()) -> state().
send_offline_messages(#{user := Uid, server := Server,
        offline_queue_params := #{window := Window, pending_acks := PendingAcks,
        last_msg_order_id := LastMsgOrderId} = OfflineQueueParams} = State) ->
    case model_messages:get_user_messages(Uid, LastMsgOrderId + 1, Window) of
        {ok, true, []} ->
            %% mark offline queue to be cleared, send eoq msg and timer, update state.
            mark_offline_queue_cleared(Uid, Server, LastMsgOrderId, State);

        {ok, EndOfQueue, OfflineMessages} ->
            %% Applying filter to remove expired messages.
            FilteredOfflineMessages = lists:filter(fun filter_messages/1, OfflineMessages),
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

                    {MsgsToSend, _RemMsgs} = case length(FilteredOfflineMessages) >= NumMsgToSend of
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
                    case EndOfQueue of
                        true ->
                            %% mark offline queue to be cleared, send eoq msg and timer, update state.
                            mark_offline_queue_cleared(Uid, Server, NewLastMsgOrderId, State1);
                        false -> State1
                    end
            end
    end.


-spec do_send_offline_messages(Uid :: binary(), MsgsToSend :: [message()]) -> ok.
do_send_offline_messages(Uid, MsgsToSend) ->
    lists:foreach(fun route_offline_message/1, MsgsToSend),
    increment_retry_counts(Uid, MsgsToSend),
    ok.


%% This function must always run on user's c2s process only!
-spec mark_offline_queue_cleared(UserId :: binary(), Server :: binary(),
        NewLastMsgOrderId :: integer(), State :: state()) -> state().
mark_offline_queue_cleared(UserId, Server, NewLastMsgOrderId, State) ->
    %% TODO(murali@): use end_of_queue marker for time to clear out the offline queue.
    EndOfQueueMsgId = send_end_of_queue_marker(UserId, Server),
    schedule_offline_queue_check(UserId, NewLastMsgOrderId),
    State#{offline_queue_cleared => true, end_of_queue_msg_id => EndOfQueueMsgId}.


%% We check our offline_queue after sometime even after we flush out all messages.
%% Because other processes could end up storing some messages here.
-spec schedule_offline_queue_check(UserId :: binary(), NewLastMsgOrderId :: integer()) -> ok.
schedule_offline_queue_check(UserId, NewLastMsgOrderId) ->
    ?INFO("Uid: ~s, send offline_queue_cleared notice to c2s process: ~p", [UserId, self()]),
    erlang:send_after(?RETRY_INTERVAL_MILLISEC, self(), {offline_queue_cleared, NewLastMsgOrderId}),
    ok.


-spec send_end_of_queue_marker(UserId :: binary(), Server :: binary()) -> MsgId :: binary().
send_end_of_queue_marker(UserId, Server) ->
    MsgId = util:new_msg_id(),
    EndOfQueueMarker = #message{
        id = MsgId,
        to = jid:make(UserId, Server),
        from = jid:make(Server),
        sub_els = [#end_of_queue{}]
    },
    ejabberd_router:route(EndOfQueueMarker),
    MsgId.


-spec route_offline_message(OfflineMessage :: maybe(offline_message())) -> ok.
route_offline_message(undefined) ->
    ok;
route_offline_message(#offline_message{
        msg_id = MsgId, to_uid = ToUid, retry_count = RetryCount, message = Message, protobuf = true}) ->
    %% TODO: remove when turning on this logic for all users.
    ?assertEqual(true, dev_users:is_dev_uid(ToUid)),
    case enif_protobuf:decode(Message, pb_packet) of
        {error, Reason} ->
            ?ERROR("MsgId: ~p, Message: ~p, failed decoding reason: ~s", [MsgId, Message, Reason]);
        Packet ->
            Packet1 = packet_parser:proto_to_xmpp(Packet),
            adjust_and_send_message(Packet1, RetryCount),
            ?INFO("sending offline message Uid: ~s MsgId: ~p rc: ~p", [ToUid, MsgId, RetryCount])
    end,
    ok;
route_offline_message(#offline_message{
        msg_id = MsgId, to_uid = ToUid, retry_count = RetryCount, message = Message}) ->
    case fxml_stream:parse_element(Message) of
        {error, Reason} ->
            ?ERROR("MsgId: ~s, failed to parse: ~p, reason: ~p", [MsgId, Message, Reason]);
        MessageXmlEl ->
            try
                Packet = xmpp:decode(MessageXmlEl, ?NS_CLIENT, [ignore_els]),
                adjust_and_send_message(Packet, RetryCount),
                ?INFO("sending offline message Uid: ~s MsgId: ~p rc: ~p",
                    [ToUid, MsgId, RetryCount])
            catch
                Class : Reason : Stacktrace ->
                    ?ERROR("failed routing: ~s", [
                            lager:pr_stacktrace(Stacktrace, {Class, Reason})])
            end
    end,
    ok.


-spec adjust_and_send_message(Message :: message(), RetryCount :: integer()) -> ok.
adjust_and_send_message(Message, RetryCount) ->
    Message1 = Message#message{retry_count = RetryCount},
    ejabberd_router:route(Message1),
    ok.


%% TODO(murali@): remove this in one month.
filter_messages(undefined) -> false;
filter_messages(#offline_message{msg_id = MsgId, to_uid = Uid, content_type = <<"event">>}) ->
    %% Filter out old pubsub messages.
    ?INFO("Dropping old pubsub messages, Uid: ~p, msg_id: ~p", [Uid, MsgId]),
    model_messages:ack_message(Uid, MsgId),
    stat:count("HA/offline_messages", "drop"),
    false;
filter_messages(#offline_message{msg_id = MsgId, to_uid = Uid, content_type = <<"error_st">>}) ->
    %% Filter out old error_st messages, clients dont handle them.
    %% We should not be seeing these messages: TODO(murali@): debug and fix them.
    ?INFO("Dropping error_st messages, Uid: ~p, msg_id: ~p", [Uid, MsgId]),
    ok = model_messages:withhold_message(Uid, MsgId),
    stat:count("HA/offline_messages", "drop"),
    false;
filter_messages(#offline_message{msg_id = MsgId, to_uid = Uid,
        retry_count = RetryCount, message = Message})
        when RetryCount >= ?MAX_RETRY_COUNT ->
    ?WARNING("Withhold offline message after max retries, Uid: ~p, msg_id: ~p, message: ~p",
            [Uid, MsgId, Message]),
    ok = model_messages:withhold_message(Uid, MsgId),
    stat:count("HA/offline_messages", "drop"),
    false;
filter_messages(_) -> true.


-spec increment_retry_counts(UserId :: uid, OfflineMsgs :: [maybe(offline_message())]) -> ok.
increment_retry_counts(UserId, OfflineMsgs) ->
    MsgIds = lists:filtermap(
        fun (undefined) -> false;
            (Msg) -> {true, Msg#offline_message.msg_id}
        end, OfflineMsgs),
    ok = model_messages:increment_retry_counts(UserId, MsgIds),
    ok.


-spec store_message(Message :: message()) -> ok.
store_message(#message{sub_els = [#end_of_queue{}]} = _Message) ->
    %% ignore storing end_of_queue marker packets.
    ok;
store_message(#message{} = Message) ->
    ok = model_messages:store_message(Message),
    ok.

% TODO: (nikola): After the migration we will replce all calls to check_store_message with store_message or
% delete the call all together. This function will be deleted.
-spec check_store_message(Message :: message()) -> ok.
check_store_message(#message{sub_els = [#end_of_queue{}]} = _Message) ->
    %% ignore storing end_of_queue marker packets.
    ok;
check_store_message(#message{to = To, id = MsgID} = Message) ->
    ToUid = To#jid.luser,
    case model_messages:get_message(ToUid, MsgID) of
        {ok, undefined} ->
            ?INFO("Uid: ~s MsgID: ~s storing from receiver process", [ToUid, MsgID]),
            store_message(Message);
        {ok, #offline_message{}} ->
            ?INFO("Uid: ~s MsgID: ~s already stored", [ToUid, MsgID]),
            ok
    end,
    ok.


-spec compute_new_params(RetryCount :: integer(), Window :: maybe(integer()),
        PendingAcks :: integer(), TotalNumOfMessages :: integer()) -> {maybe(integer()), integer()}.
compute_new_params(RetryCount, Window, PendingAcks, TotalNumOfMessages) ->
    NewWindow = case RetryCount > 1 of
        true ->
            ExpDrop = round(math:pow(2, RetryCount - 2)),
            ExpWindow = max(1, ?MAX_WINDOW / ExpDrop),
            case Window of
                undefined -> round(ExpWindow);
                _ -> round(min(ExpWindow, Window * 2))
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


-spec setup_push_timer(Message :: message()) -> ok.
setup_push_timer(Message) ->
    gen_server:cast(get_proc(), {setup_push_timer, Message}).


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

