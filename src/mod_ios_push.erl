%%%----------------------------------------------------------------------
%%% File    : mod_ios_push.erl
%%%
%%% Copyright (C) 2020 HalloApp inc.
%%%
%%% Currently, the process tries to resend failed push notifications using a retry interval
%%% from a fibonacci series starting with 0, 30 seconds for the next 10 minutes which is about
%%% 6 retries and then then discards the push notification. These numbers are configurable.
%%% We maintain a state for the process that contains all the necessary information
%%% about pendingMessages that haven't received their status about the notification,
%%% host of the process and the socket for the connection to APNS.
%%%----------------------------------------------------------------------

-module(mod_ios_push).
-author('murali').
-behaviour(gen_mod).
-behaviour(gen_server).

-include("logger.hrl").
-include("packets.hrl").
-include("server.hrl").
-include("push_message.hrl").
-include("feed.hrl").
-include("proc.hrl").
-include("password.hrl").

-define(RETRY_INTERVAL_MILLISEC, 30 * ?SECONDS_MS).    %% 30 seconds.
-define(MESSAGE_MAX_RETRY_TIME_MILLISEC, 10 * ?MINUTES_MS).    %% 10 minutes.

-define(APNS_ID, <<"apns-id">>).

%% gen_mod API
-export([start/2, stop/1, reload/3, depends/2, mod_options/1]).
%% gen_server API
-export([init/1, terminate/2, code_change/3, handle_call/3, handle_cast/2, handle_info/2]).

%% API
-export([
    push/2,
    send_dev_push/4,
    crash/0    %% test
]).


%%====================================================================
%% gen_mod API.
%%====================================================================

start(Host, Opts) ->
    ?INFO("start ~w", [?MODULE]),
    gen_mod:start_child(?MODULE, Host, Opts, ?PROC()),
    PoolConfigs = [{workers, ?NUM_IOS_POOL_WORKERS}, {worker, {mod_ios_push_msg, [Host]}}],
    Pid = wpool:start_sup_pool(?IOS_POOL, PoolConfigs),
    ?INFO("IOS Push pool is created with pid ~p", [Pid]),
    ok.

stop(_Host) ->
    ?INFO("stop ~w", [?MODULE]),
    gen_mod:stop_child(?PROC()),
    ok.

depends(_Host, _Opts) ->
    [{mod_aws, hard}].

reload(_Host, _NewOpts, _OldOpts) ->
    ok.

mod_options(_Host) ->
    [].


%%====================================================================
%% API
%%====================================================================

-spec push(Message :: pb_msg(), PushInfo :: push_info()) -> ok.
push(Message, #push_info{os = Os, voip_token = VoipToken} = PushInfo)
        when Os =:= <<"ios">>; Os =:= <<"ios_dev">>; VoipToken =/= undefined ->
    gen_server:cast(?PROC(), {push_message, Message, PushInfo});
push(_Message, _PushInfo) ->
    ?ERROR("Invalid push_info : ~p", [_PushInfo]).


%% Added sample payloads for the client teams here:
%% https://github.com/HalloAppInc/server/pull/291
-spec send_dev_push(Uid :: binary(), PushInfo :: push_info(),
        PushTypeBin :: binary(), PayloadBin :: binary()) -> ok | {error, any()}.
send_dev_push(Uid, PushInfo, PushTypeBin, Payload) ->
    gen_server:call(?PROC(), {send_dev_push, Uid, PushInfo, PushTypeBin, Payload}).


-spec crash() -> ok.
crash() ->
    gen_server:cast(?PROC(), crash).

%%====================================================================
%% gen_server callbacks
%%====================================================================

init([Host|_]) ->
    {ok, #push_state{
            pendingMap = #{},
            host = Host}}.


terminate(_Reason, #push_state{host = _Host}) ->
    ok.


code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


handle_call({send_dev_push, Uid, PushInfo, PushTypeBin, Payload}, _From, State) ->
    {ok, NewState} = send_dev_push_internal(Uid, PushInfo, PushTypeBin, Payload, State),
    {reply, ok, NewState};
handle_call(_Request, _From, State) ->
    ?ERROR("invalid call request: ~p", [_Request]),
    {reply, {error, invalid_request}, State}.


handle_cast({ping, Id, Ts, From}, State) ->
    util_monitor:send_ack(self(), From, {ack, Id, Ts, self()}),
    {noreply, State};
handle_cast({push_message, Message, PushInfo} = _Request, State) ->
    ?DEBUG("push_message: ~p", [Message]),
    NewState = push_message(Message, PushInfo, State),
    {noreply, NewState};

handle_cast(crash, _State) ->
    error(test_crash);

handle_cast(_Request, State) ->
    ?DEBUG("Invalid request, ignoring it: ~p", [_Request]),
    {noreply, State}.



%% TODO(murali@): Use non-recoverable APNS error responses!
% -spec remove_push_info(Uid :: binary(), Server :: binary()) -> ok.
% remove_push_info(Uid, Server) ->
%     mod_push_tokens:remove_push_info(Uid, Server).


%%====================================================================
%% Retry logic!
%%====================================================================

%% TODO(murali@): Store these messages in ets tables/Redis and use message-id in retry timers.
handle_info({retry, PushMessageItem}, State) ->
    Uid = PushMessageItem#push_message_item.uid,
    Id = PushMessageItem#push_message_item.id,
    ?DEBUG("retry: push_message_item: ~p", [PushMessageItem]),
    CurTimestampMs = util:now_ms(),
    MsgTimestampMs = PushMessageItem#push_message_item.timestamp_ms,
    %% Stop retrying after 10 minutes!
    NewState = case CurTimestampMs - MsgTimestampMs < ?MESSAGE_MAX_RETRY_TIME_MILLISEC of
        false ->
            ?INFO("Uid: ~s push failed, no more retries msg_id: ~s", [Uid, Id]),
            State;
        true ->
            ?INFO("Uid: ~s, retry push_message_item: ~p", [Uid, Id]),
            NewRetryMs = round(PushMessageItem#push_message_item.retry_ms * ?GOLDEN_RATIO),
            NewPushMessageItem = PushMessageItem#push_message_item{retry_ms = NewRetryMs},
            wpool:cast(?IOS_POOL, {push_message_item, NewPushMessageItem, self()}),
            add_to_pending_map(PushMessageItem#push_message_item.apns_id, NewPushMessageItem, State)
    end,
    {noreply, NewState};


handle_info({gun_response, ConnPid, StreamRef, _, StatusCode, Headers}, State) ->
    ?DEBUG("gun_response: conn_pid: ~p, streamref: ~p, status: ~p, headers: ~p",
            [ConnPid, StreamRef, StatusCode, Headers]),
    ApnsId = proplists:get_value(?APNS_ID, Headers, undefined),
    NewPushTimes = handle_push_times(ApnsId, State),
    NewState = handle_apns_response(StatusCode, ApnsId, State),
    {noreply, NewState#push_state{push_times_ms = NewPushTimes}};

handle_info({gun_data, ConnPid, StreamRef, _, Response}, State) ->
    ?INFO("gun_data: conn_pid: ~p, streamref: ~p, data: ~p", [ConnPid, StreamRef, Response]),
    {noreply, State};

handle_info(Request, State) ->
    ?DEBUG("unknown request: ~p", [Request]),
    {noreply, State}.


-spec handle_push_times(ApnsId :: binary() | undefined, State :: push_state()) -> push_state().
handle_push_times(ApnsId, #push_state{pendingMap = PendingMap} = State) ->
    NewPushTimes = case maps:get(ApnsId, PendingMap, undefined) of
        undefined ->
            State#push_state.push_times_ms;
        PushMessageItem ->
            TimeTakenMs = util:now_ms() - PushMessageItem#push_message_item.timestamp_ms,
            push_util:process_push_times(State#push_state.push_times_ms, TimeTakenMs, ios)
    end,
    NewPushTimes;
handle_push_times(_ApnsId, State) ->
    State#push_state.push_times_ms.


-spec handle_apns_response(StatusCode :: integer(), ApnsId :: binary() | undefined,
        State :: push_state()) -> push_state().
handle_apns_response(_, undefined, State) ->
    %% This should never happen, since apns always responds with the apns-id.
    ?ERROR("unexpected response from apns!!", []),
    State;
handle_apns_response(200, ApnsId, #push_state{pendingMap = PendingMap} = State) ->
    stat:count("HA/push", ?APNS, 1, [{"result", "success"}]),
    FinalPendingMap = case maps:take(ApnsId, PendingMap) of
        error ->
            ?ERROR("Message not found in our map: apns-id: ~p", [ApnsId]),
            PendingMap;
        {PushMessageItem, NewPendingMap} ->
            Id = PushMessageItem#push_message_item.id,
            Uid = PushMessageItem#push_message_item.uid,
            Version = PushMessageItem#push_message_item.push_info#push_info.client_version,
            PushType = PushMessageItem#push_message_item.push_type,
            ContentType = PushMessageItem#push_message_item.content_type,
            ?INFO("Uid: ~s, apns push successful: msg_id: ~s", [Uid, Id]),
            %% TODO: We should capture this info in the push info itself.
            {ok, Phone} = model_accounts:get_phone(Uid),
            CC = mod_libphonenumber:get_cc(Phone),
            ha_events:log_event(<<"server.push_sent">>, #{uid => Uid, push_id => Id,
                    platform => ios, client_version => Version, push_type => PushType,
                    content_type => ContentType, cc => CC}),
            NewPendingMap
    end,
    State#push_state{pendingMap = FinalPendingMap};

handle_apns_response(StatusCode, ApnsId, #push_state{pendingMap = PendingMap} = State)
        when StatusCode =:= 410 ->
    stat:count("HA/push", ?APNS, 1, [{"result", "apns_error"}]),
    FinalPendingMap = case maps:take(ApnsId, PendingMap) of
        error ->
            ?ERROR("Message not found in our map: apns-id: ~p", [ApnsId]),
            PendingMap;
        {PushMessageItem, NewPendingMap} ->
            Id = PushMessageItem#push_message_item.id,
            Uid = PushMessageItem#push_message_item.uid,
            ?INFO("Uid: ~s, apns push error code: ~p, msg_id: ~s, invalid_device_token", [Uid, StatusCode, Id]),
            NewPendingMap
    end,
    State#push_state{pendingMap = FinalPendingMap};

handle_apns_response(StatusCode, ApnsId, #push_state{pendingMap = PendingMap} = State)
        when StatusCode =:= 429; StatusCode >= 500 ->
    stat:count("HA/push", ?APNS, 1, [{"result", "apns_error"}]),
    FinalPendingMap = case maps:take(ApnsId, PendingMap) of
        error ->
            ?ERROR("Message not found in our map: apns-id: ~p", [ApnsId]),
            PendingMap;
        {PushMessageItem, NewPendingMap} ->
            Id = PushMessageItem#push_message_item.id,
            Uid = PushMessageItem#push_message_item.uid,
            ?WARNING("Uid: ~s, apns push error code: ~p, msg_id: ~s, will retry", [Uid, StatusCode, Id]),
            retry_message_item(PushMessageItem),
            NewPendingMap
    end,
    State#push_state{pendingMap = FinalPendingMap};

handle_apns_response(StatusCode, ApnsId, #push_state{pendingMap = PendingMap} = State)
        when StatusCode >= 400; StatusCode < 500 ->
    stat:count("HA/push", ?APNS, 1, [{"result", "failure"}]),
    FinalPendingMap = case maps:take(ApnsId, PendingMap) of
        error ->
            ?ERROR("Message not found in our map: apns-id: ~p", [ApnsId]),
            PendingMap;
        {PushMessageItem, NewPendingMap} ->
            Uid = PushMessageItem#push_message_item.uid,
            Msg = PushMessageItem#push_message_item.message,
            ?ERROR("Uid: ~s, apns push error:code: ~p, msg: ~p, needs to be fixed!", [Uid, StatusCode, Msg]),
            NewPendingMap
    end,
    State#push_state{pendingMap = FinalPendingMap};

handle_apns_response(StatusCode, ApnsId, State) ->
    ?ERROR("Invalid status code : ~p, from apns, apns-id: ~p", [StatusCode, ApnsId]),
    State.




%%====================================================================
%% internal module functions
%%====================================================================

-spec add_to_pending_map(ApnsId :: binary(), PushMessageItem :: push_message_item(),
        State :: push_state()) -> push_state().
add_to_pending_map(ApnsId, PushMessageItem, #push_state{pendingMap = PendingMap} = State) ->
    NewPendingMap = PendingMap#{ApnsId => PushMessageItem},
    State#push_state{pendingMap = NewPendingMap}.


%% TODO(murali@): Figure out a way to better use the message-id.
-spec push_message(Message :: pb_msg(), PushInfo :: push_info(),
        State :: push_state()) -> push_state().
push_message(Message, PushInfo, State) ->
    MsgId = pb:get_id(Message),
    Uid = pb:get_to(Message),
    try
        ApnsId = util_id:new_uuid(),
        TimestampMs = util:now_ms(),
        PushMetadata = push_util:parse_metadata(Message),
        PushMessageItem = #push_message_item{
            id = MsgId,
            uid = Uid,
            message = Message,
            timestamp_ms = TimestampMs,
            retry_ms = ?RETRY_INTERVAL_MILLISEC,
            push_info = PushInfo,
            push_type = PushMetadata#push_metadata.push_type,
            content_type = PushMetadata#push_metadata.content_type,
            apns_id = ApnsId
        },
        wpool:cast(?IOS_POOL, {push_message_item, PushMessageItem, PushMetadata, self()}),
        add_to_pending_map(ApnsId, PushMessageItem, State)
    catch
        Class: Reason: Stacktrace ->
            ?ERROR("Failed to push MsgId: ~s ToUid: ~s crash:~s",
                [MsgId, Uid, lager:pr_stacktrace(Stacktrace, {Class, Reason})]),
            State
    end.


-spec retry_message_item(PushMessageItem :: push_message_item()) -> reference().
retry_message_item(PushMessageItem) ->
    RetryTime = PushMessageItem#push_message_item.retry_ms,
    setup_timer({retry, PushMessageItem}, RetryTime).

%%====================================================================
%% setup timers
%%====================================================================

-spec setup_timer({any() | _}, integer()) -> reference().
setup_timer(Msg, TimeoutSec) ->
    NewTimer = erlang:send_after(TimeoutSec, self(), Msg),
    NewTimer.


%%====================================================================
%% Module Options
%%====================================================================

-spec send_dev_push_internal(Uid :: binary(), PushInfo :: push_info(),
        PushTypeBin :: binary(), PayloadBin :: binary(),
        State :: push_state()) -> {ok, push_state()} | {{error, any()}, push_state()}.
send_dev_push_internal(Uid, PushInfo, PushTypeBin, PayloadBin, State) ->
    EndpointType = dev,
    PushType = util:to_atom(PushTypeBin),
    ContentId = util_id:new_long_id(),
    ApnsId = util_id:new_uuid(),
    PushMessageItem = #push_message_item{
        id = ContentId,
        uid = Uid,
        message = PayloadBin,   %% Storing it here for now. TODO(murali@): fix this.
        timestamp_ms = util:now_ms(),
        retry_ms = ?RETRY_INTERVAL_MILLISEC,
        push_info = PushInfo,
        push_type = PushType
    },
    wpool:cast(?IOS_POOL, {send_post_request_to_apns, Uid, ApnsId, ContentId, PayloadBin,
            PushType, EndpointType, PushMessageItem, self()}),
    add_to_pending_map(ApnsId, PushMessageItem, State).

