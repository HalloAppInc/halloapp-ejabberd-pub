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
    crash/0    %% test
]).


%%====================================================================
%% gen_mod API.
%%====================================================================

start(Host, Opts) ->
    ?INFO("start ~w", [?MODULE]),
    gen_mod:start_child(?MODULE, Host, Opts, ?PROC()),
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
push(Message, #push_info{os = <<"android">>} = PushInfo) ->
    gen_server:cast(?PROC(), {push_message, Message, PushInfo});
push(_Message, _PushInfo) ->
    ?ERROR("Invalid push_info : ~p", [_PushInfo]).


-spec crash() -> ok.
crash() ->
    gen_server:cast(?PROC(), crash).


%%====================================================================
%% gen_server callbacks
%%====================================================================

init([Host|_]) ->
    _ = get_fcm_apikey(),
    {ok, #push_state{
            pendingMap = #{},
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
    State1 = push_message(Message, PushInfo, State),
    {noreply, State1};

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
            ?INFO("Uid: ~s push failed, no more retries msg_id: ~s", [Uid, Id]);
        true ->
            ?INFO("Uid: ~s, retry push_message_item: ~s", [Uid, Id]),
            NewRetryMs = round(PushMessageItem#push_message_item.retry_ms * ?GOLDEN_RATIO),
            NewPushMessageItem = PushMessageItem#push_message_item{retry_ms = NewRetryMs},
            mod_android_push_msg:push_message_item(NewPushMessageItem, self())
    end,
    {noreply, State};

handle_info({http, {RequestId, _Response} = ReplyInfo}, #push_state{pendingMap = PendingMap} = State) ->
    FinalPendingMap = case maps:take(RequestId, PendingMap) of
        error ->
            ?ERROR("Request not found in our map: RequestId: ~p", [RequestId]),
            NewPushTimes = State#push_state.push_times_ms,
            PendingMap;
        {PushMessageItem, NewPendingMap} ->
            TimeTakenMs = util:now_ms() - PushMessageItem#push_message_item.timestamp_ms,
            NewPushTimes = push_util:process_push_times(State#push_state.push_times_ms, TimeTakenMs, android),
            handle_fcm_response(ReplyInfo, PushMessageItem, State),
            NewPendingMap
    end,
    State1 = State#push_state{pendingMap = FinalPendingMap, push_times_ms = NewPushTimes},
    {noreply, State1};

handle_info({add_to_pending_map, RequestId, PushMessageItem}, #push_state{pendingMap = PendingMap} = State) ->
    NewPendingMap = PendingMap#{RequestId => PushMessageItem},
    {noreply, State#push_state{pendingMap = NewPendingMap}};

handle_info(Request, State) ->
    ?DEBUG("Unknown request: ~p, ~p", [Request, State]),
    {noreply, State}.


%%====================================================================
%% internal module functions
%%====================================================================

-spec push_message(Message :: pb_msg(), PushInfo :: push_info(), State :: push_state()) -> push_state().
push_message(Message, PushInfo, State) ->
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
        mod_android_push_msg:push_message_item(PushMessageItem, self()),
        State
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


-spec setup_timer(Msg :: any(), Timeout :: integer()) -> reference().
setup_timer(Msg, Timeout) ->
    NewTimer = erlang:send_after(Timeout, self(), Msg),
    NewTimer.


-spec handle_fcm_response({RequestId :: reference(), Response :: term()},
        PushMessageItem ::push_message_item(), State :: push_state()) -> ok.
handle_fcm_response({_RequestId, Response}, PushMessageItem, #push_state{host = ServerHost} = _State) ->
    Id = PushMessageItem#push_message_item.id,
    Uid = PushMessageItem#push_message_item.uid,
    Version = PushMessageItem#push_message_item.push_info#push_info.client_version,
    ContentType = PushMessageItem#push_message_item.content_type,
    Token = PushMessageItem#push_message_item.push_info#push_info.token,
    case Response of
        {{_, StatusCode5xx, _}, _, ResponseBody}
                when StatusCode5xx >= 500 andalso StatusCode5xx < 600 ->
            stat:count("HA/push", ?FCM, 1, [{"result", "fcm_error"}]),
            ?ERROR("Push failed, Uid: ~s, Token: ~p, recoverable FCM error: ~p",
                    [Uid, binary:part(Token, 0, 10), ResponseBody]),
            retry_message_item(PushMessageItem);

        {{_, 200, _}, _, ResponseBody} ->
            case parse_response(ResponseBody) of
                {ok, FcmId} ->
                    stat:count("HA/push", ?FCM, 1, [{"result", "success"}]),
                    ?INFO("Uid:~s push successful for msg-id: ~s, FcmId: ~p", [Uid, Id, FcmId]),
                    %% TODO: We should capture this info in the push info itself.
                    {ok, Phone} = model_accounts:get_phone(Uid),
                    CC = mod_libphonenumber:get_cc(Phone),
                    ha_events:log_event(<<"server.push_sent">>, #{uid => Uid, push_id => FcmId,
                            platform => android, client_version => Version, push_type => silent,
                            content_type => ContentType, cc => CC});
                {error, Reason, FcmId} ->
                    stat:count("HA/push", ?FCM, 1, [{"result", "failure"}]),
                    case Reason =:= not_registered orelse Reason =:= invalid_registration of
                        true ->
                            ?INFO("Push failed: User Error, Uid:~s, token: ~p, reason: ~p, FcmId: ~p",
                                [Uid, binary:part(Token, 0, 10), Reason, FcmId]);
                        false ->
                            ?ERROR("Push failed: Server Error, Uid:~s, token: ~p, reason: ~p, FcmId: ~p",
                                [Uid, binary:part(Token, 0, 10), Reason, FcmId])
                    end,
                    remove_push_token(Uid, ServerHost)
            end;

        {{_, 401, _}, _, ResponseBody} ->
            stat:count("HA/push", ?FCM, 1, [{"result", "fcm_error"}]),
            ?ERROR("Push failed, Uid: ~s, Token: ~p, expired auth token, Response: ~p",
                    [Uid, binary:part(Token, 0, 10), ResponseBody]),
            mod_android_push_msg:refresh_token(),
            retry_message_item(PushMessageItem);

        {{_, _, _}, _, ResponseBody} ->
            stat:count("HA/push", ?FCM, 1, [{"result", "failure"}]),
            ?ERROR("Push failed, Uid:~s, token: ~p, non-recoverable FCM error: ~p",
                    [Uid, binary:part(Token, 0, 10), ResponseBody]),
            remove_push_token(Uid, ServerHost);

        {error, Reason} ->
            ?ERROR("Push failed, Uid:~s, token: ~p, reason: ~p",
                    [Uid, binary:part(Token, 0, 10), Reason]),
            retry_message_item(PushMessageItem)
    end.


%% Parses response of the request to check if everything worked successfully.
-spec parse_response(binary()) -> {ok, string()} | {error, any(), string()}.
parse_response(ResponseBody) ->
    {JsonData} = jiffy:decode(ResponseBody),
    Name = proplists:get_value(<<"name">>, JsonData, undefined),
    case Name of
        undefined ->
            ?INFO("FCM error: response body: ~p", [ResponseBody]),
            {error, other, <<"undefined">>};
        _ ->
            [FcmId | _] = lists:reverse(re:split(Name, "/")),
            ?DEBUG("Fcm push: message_id: ~p", [FcmId]),
            {ok, FcmId}
    end.


-spec remove_push_token(Uid :: binary(), Server :: binary()) -> ok.
remove_push_token(Uid, Server) ->
    mod_push_tokens:remove_push_token(Uid, Server).


%%====================================================================
%% FCM stuff
%%====================================================================


-spec get_fcm_apikey() -> string().
get_fcm_apikey() ->
    mod_aws:get_secret_value(<<"fcm">>, <<"apikey">>).

