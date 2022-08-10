%%%-------------------------------------------------------------------------------------------
%%% File    : mod_android_push.erl
%%%
%%% Copyright (C) 2020 HalloApp inc.
%%%
%%% Currently, the process tries to resend failed push notifications using a retry interval
%%% from a fibonacci series starting with 0, 30 seconds for the next 10 minutes which is about
%%% 6 retries and then then discards the push notification. These numbers are configurable.
%%%-------------------------------------------------------------------------------------------

-module(mod_android_push).
-author('murali').
-behaviour(gen_mod).
-behaviour(gen_server).

-include("logger.hrl").
-include("push_message.hrl").
-include("proc.hrl").

-define(MESSAGE_MAX_RETRY_TIME_MILLISEC, 600000).          %% 10 minutes.
-define(RETRY_INTERVAL_MILLISEC, 30000).           %% 30 seconds.

%% gen_mod API
-export([start/2, stop/1, reload/3, depends/2, mod_options/1]).
%% gen_server API
-export([init/1, terminate/2, code_change/3, handle_call/3, handle_cast/2, handle_info/2]).

%% API
-export([
    push/2,
    crash/0,    %% test
    retry_message_item/1,
    pushed_message/2
]).


%%====================================================================
%% gen_mod API.
%%====================================================================

start(Host, Opts) ->
    ?INFO("start ~w", [?MODULE]),
    gen_mod:start_child(?MODULE, Host, Opts, ?PROC()),
    PoolConfigs = [{workers, ?NUM_ANDROID_POOL_WORKERS}, {worker, {mod_android_push_msg, [Host]}}],
    Pid = wpool:start_sup_pool(?ANDROID_POOL, PoolConfigs),
    ?INFO("Android Push pool is created with pid ~p", [Pid]),
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

-spec push(Message :: message(), PushInfo :: push_info()) -> ok.
push(Message, #push_info{os = <<"android">>} = PushInfo) ->
    gen_server:cast(?PROC(), {push_message, Message, PushInfo});
push(_Message, _PushInfo) ->
    ?ERROR("Invalid push_info : ~p", [_PushInfo]).


-spec crash() -> ok.
crash() ->
    gen_server:cast(?PROC(), crash).


-spec retry_message_item(PushMessageItem :: push_message_item()) -> ok.
retry_message_item(PushMessageItem) ->
    gen_server:cast(?PROC(), {retry_message_item, PushMessageItem}).


-spec pushed_message(PushMessageItem :: push_message_item(), Status :: success | failure) -> ok.
pushed_message(#{uid := Uid} = PushMessageItem, Status) ->
    mod_push_monitor:log_push_response(Uid, Status, android),
    gen_server:cast(?PROC(), {pushed_message, PushMessageItem, Status}).


%%====================================================================
%% gen_server callbacks
%%====================================================================

init([Host|_]) ->
    _ = get_fcm_apikey(),
    {ok, #push_state{
            host = Host }}.


terminate(_Reason, #push_state{host = _Host}) ->
    ok.


code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


handle_call(_Request, _From, State) ->
    ?ERROR("invalid call request: ~p", [_Request]),
    {reply, {error, invalid_request}, State}.


handle_cast({ping, Id, Ts, From}, State) ->
    util_monitor:send_ack(self(), From, {ack, Id, Ts, self()}),
    {noreply, State};
handle_cast({push_message, Message, PushInfo} = _Request, State) ->
    ?DEBUG("push_message: ~p", [Message]),
    push_message(Message, PushInfo),
    {noreply, State};
handle_cast({pushed_message, PushMessageItem, Status}, State) ->
    ?INFO("Worker pool sent push id: ~p status: ~p", [PushMessageItem#push_message_item.id, Status]),
    TimeTakenMs = util:now_ms() - PushMessageItem#push_message_item.timestamp_ms,
    NewPushTimes = push_util:process_push_times(State#push_state.push_times_ms, TimeTakenMs, android),
    {noreply, State#push_state{push_times_ms = NewPushTimes}};
handle_cast({retry_message_item, PushMessageItem}, State) ->
    RetryTime = PushMessageItem#push_message_item.retry_ms,
    erlang:send_after(RetryTime, self(), {retry, PushMessageItem}),
    {noreply, State};
handle_cast(crash, _State) ->
    error(test_crash);

handle_cast(_Request, State) ->
    ?DEBUG("Invalid request, ignoring it: ~p", [_Request]),
    {noreply, State}.


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
    case CurTimestampMs - MsgTimestampMs < ?MESSAGE_MAX_RETRY_TIME_MILLISEC of
        false ->
            pushed_message(PushMessageItem, failure),
            ?INFO("Uid: ~s push failed, no more retries msg_id: ~s", [Uid, Id]);
        true ->
            ?INFO("Uid: ~s, retry push_message_item: ~s", [Uid, Id]),
            NewRetryMs = round(PushMessageItem#push_message_item.retry_ms * ?GOLDEN_RATIO),
            NewPushMessageItem = PushMessageItem#push_message_item{retry_ms = NewRetryMs},
            wpool:cast(?ANDROID_POOL, {push_message_item, NewPushMessageItem})
    end,
    {noreply, State};

handle_info(Request, State) ->
    ?DEBUG("Unknown request: ~p, ~p", [Request, State]),
    {noreply, State}.


%%====================================================================
%% internal module functions
%%====================================================================

-spec push_message(Message :: message(), PushInfo :: push_info()) -> ok.
push_message(Message, PushInfo) ->
    MsgId = pb:get_id(Message),
    Uid = pb:get_to(Message),
    try
        TimestampMs = util:now_ms(),
        PushMessageItem = #push_message_item{
                id = MsgId,
                uid = Uid,
                message = Message,
                timestamp_ms = TimestampMs,
                retry_ms = ?RETRY_INTERVAL_MILLISEC,
                push_info = PushInfo},
        wpool:cast(?ANDROID_POOL, {push_message_item, PushMessageItem})
    catch
        Class: Reason: Stacktrace ->
            ?ERROR("Failed to push MsgId: ~s ToUid: ~s crash:~s",
                [MsgId, Uid, lager:pr_stacktrace(Stacktrace, {Class, Reason})])
    end.


%%====================================================================
%% FCM stuff
%%====================================================================


-spec get_fcm_apikey() -> string().
get_fcm_apikey() ->
    mod_aws:get_secret_value(<<"fcm">>, <<"apikey">>).

