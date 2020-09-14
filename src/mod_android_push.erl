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
-include("xmpp.hrl").
-include("translate.hrl").
-include ("push_message.hrl").

%% TODO(murali@): convert everything to 1 timeunit.
-define(HTTP_TIMEOUT_MILLISEC, 10000).             %% 10 seconds.
-define(HTTP_CONNECT_TIMEOUT_MILLISEC, 10000).     %% 10 seconds.
-define(MESSAGE_MAX_RETRY_TIME_SEC, 600).          %% 10 minutes.
-define(RETRY_INTERVAL_MILLISEC, 30000).           %% 30 seconds.

-define(FCM_GATEWAY, "https://fcm.googleapis.com/fcm/send").

%% gen_mod API
-export([start/2, stop/1, reload/3, depends/2, mod_options/1]).
%% gen_server API
-export([init/1, terminate/2, code_change/3, handle_call/3, handle_cast/2, handle_info/2]).

%% API
-export([
    push/2
]).


%%====================================================================
%% gen_mod API.
%%====================================================================

start(Host, Opts) ->
    ?INFO_MSG("start ~w", [?MODULE]),
    gen_mod:start_child(?MODULE, Host, Opts, get_proc()),
    ok.

stop(_Host) ->
    ?INFO_MSG("stop ~w", [?MODULE]),
    gen_mod:stop_child(get_proc()),
    ok.

depends(_Host, _Opts) ->
    [{mod_aws, hard}].

reload(_Host, _NewOpts, _OldOpts) ->
    ok.

mod_options(_Host) ->
    [].

get_proc() ->
    gen_mod:get_module_proc(global, ?MODULE).


%%====================================================================
%% API
%%====================================================================

-spec push(Message :: message(), PushInfo :: push_info()) -> ok.
push(Message, #push_info{os = <<"android">>} = PushInfo) ->
    gen_server:cast(get_proc(), {push_message, Message, PushInfo});
push(_Message, _PushInfo) ->
    ?ERROR_MSG("Invalid push_info : ~p", [_PushInfo]).


%%====================================================================
%% gen_server callbacks
%%====================================================================

init([Host|_]) ->
    process_flag(trap_exit, true),
    get_fcm_info(),
    {ok, #push_state{host = Host}}.


terminate(_Reason, #push_state{host = _Host}) ->
    ok.


code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


handle_call(_Request, _From, State) ->
    ?ERROR_MSG("invalid call request: ~p", [_Request]),
    {reply, {error, invalid_request}, State}.


handle_cast({push_message, Message, PushInfo} = _Request, State) ->
    ?DEBUG("push_message: ~p", [Message]),
    push_message(Message, PushInfo, State),
    {noreply, State};
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
    CurTimestamp = util:now(),
    MsgTimestamp = PushMessageItem#push_message_item.timestamp,
    %% Stop retrying after 10 minutes!
    case CurTimestamp - MsgTimestamp < ?MESSAGE_MAX_RETRY_TIME_SEC of
        false ->
            ?INFO_MSG("Uid: ~s push failed, no more retries msg_id: ~s", [Uid, Id]);
        true ->
            ?INFO_MSG("Uid: ~s, retry push_message_item: ~s", [Uid, Id]),
            NewRetryMs = round(PushMessageItem#push_message_item.retry_ms * ?GOLDEN_RATIO),
            NewPushMessageItem = PushMessageItem#push_message_item{retry_ms = NewRetryMs},
            push_message_item(NewPushMessageItem, State)
    end,
    {noreply, State};

handle_info(Request, State) ->
    ?DEBUG("Unknown request: ~p, ~p", [Request, State]),
    {noreply, State}.


%%====================================================================
%% internal module functions
%%====================================================================

-spec push_message(Message :: message(), PushInfo :: push_info(), State :: push_state()) -> ok.
push_message(Message, PushInfo, State) ->
    Timestamp = util:now(),
    #jid{luser = Uid} = xmpp:get_to(Message),
    PushMessageItem = #push_message_item{
            id = xmpp:get_id(Message),
            uid = Uid,
            message = Message,
            timestamp = Timestamp,
            retry_ms = ?RETRY_INTERVAL_MILLISEC,
            push_info = PushInfo},
    push_message_item(PushMessageItem, State).


-spec push_message_item(PushMessageItem :: push_message_item(), State :: push_state()) -> ok.
push_message_item(PushMessageItem, #push_state{host = ServerHost}) ->
    Id = PushMessageItem#push_message_item.id,
    Uid = PushMessageItem#push_message_item.uid,
    Token = PushMessageItem#push_message_item.push_info#push_info.token,
    HTTPOptions = [
            {timeout, ?HTTP_TIMEOUT_MILLISEC},
            {connect_timeout, ?HTTP_CONNECT_TIMEOUT_MILLISEC}
    ],
    Options = [],
    FcmApiKey = get_fcm_apikey(),
    PushMetadata = push_util:parse_metadata(PushMessageItem#push_message_item.message),
    Payload = #{
            <<"title">> => <<"PushMessage">>,
            <<"content-id">> => PushMetadata#push_metadata.content_id,
            <<"content-type">> => PushMetadata#push_metadata.content_type,
            <<"from-id">> => PushMetadata#push_metadata.from_uid,
            <<"timestamp">> => PushMetadata#push_metadata.timestamp,
            <<"thread-id">> => PushMetadata#push_metadata.thread_id,
            <<"thread-name">> => PushMetadata#push_metadata.thread_name
    },
    PushMessage = #{<<"to">> => Token, <<"priority">> => <<"high">>, <<"data">> => Payload},
    Request = {?FCM_GATEWAY, [{"Authorization", "key=" ++ FcmApiKey}],
            "application/json", jiffy:encode(PushMessage)},
    %% TODO(murali@): Switch to using an asynchronous http client.
    Response = httpc:request(post, Request, HTTPOptions, Options),
    case Response of
        {ok, {{_, StatusCode5xx, _}, _, ResponseBody}}
                when StatusCode5xx >= 500 andalso StatusCode5xx < 600 ->
            stat:count(?FCM, "fcm_error"),
            ?ERROR_MSG("Push failed, Uid: ~s, Token: ~p, recoverable FCM error: ~p",
                    [Uid, binary:part(Token, 0, 10), ResponseBody]),
            retry_message_item(PushMessageItem);

        {ok, {{_, 200, _}, _, ResponseBody}} ->
            case parse_response(ResponseBody) of
                ok ->
                    stat:count(?FCM, "success"),
                    ?INFO_MSG("Uid:~s push successful for msg-id: ~s", [Uid, Id]);
                Reason ->
                    stat:count(?FCM, "failure"),
                    ?ERROR_MSG("Push failed, Uid:~s, token: ~p, reason: ~p",
                            [Uid, binary:part(Token, 0, 10), Reason]),
                    remove_push_token(Uid, ServerHost)
            end;

        {ok, {{_, _, _}, _, ResponseBody}} ->
            stat:count(?FCM, "failure"),
            ?ERROR_MSG("Push failed, Uid:~s, token: ~p, non-recoverable FCM error: ~p",
                    [Uid, binary:part(Token, 0, 10), ResponseBody]),
            remove_push_token(Uid, ServerHost);

        {error, Reason} ->
            ?ERROR_MSG("Push failed, Uid:~s, token: ~p, reason: ~p",
                    [Uid, binary:part(Token, 0, 10), Reason]),
            retry_message_item(PushMessageItem)

    end,
    ok.


-spec retry_message_item(PushMessageItem :: push_message_item()) -> reference().
retry_message_item(PushMessageItem) ->
    RetryTime = PushMessageItem#push_message_item.retry_ms,
    setup_timer({retry, PushMessageItem}, RetryTime).


-spec setup_timer(Msg :: any(), Timeout :: integer()) -> reference().
setup_timer(Msg, Timeout) ->
    NewTimer = erlang:send_after(Timeout, self(), Msg),
    NewTimer.


%% Parses response of the request to check if everything worked successfully.
-spec parse_response(binary()) -> ok | not_registered | invalid_registration | other.
parse_response(ResponseBody) ->
    {JsonData} = jiffy:decode(ResponseBody),
    case proplists:get_value(<<"success">>, JsonData) of
        1 ->
            ok;
        0 ->
            [{Result}] = proplists:get_value(<<"results">>, JsonData),
            case proplists:get_value(<<"error">>, Result) of
                <<"NotRegistered">> ->
                    ?ERROR_MSG("FCM error: NotRegistered", []),
                    not_registered;
                <<"InvalidRegistration">> ->
                    ?ERROR_MSG("FCM error: InvalidRegistration", []),
                    invalid_registration;
                Error ->
                    ?ERROR_MSG("FCM error: ~s", [Error]),
                    other
            end
    end.


-spec remove_push_token(Uid :: binary(), Server :: binary()) -> ok.
remove_push_token(Uid, Server) ->
    mod_push_tokens:remove_push_token(Uid, Server).


%%====================================================================
%% FCM stuff
%%====================================================================

get_fcm_info() ->
    jsx:decode(mod_aws:get_secret(<<"fcm">>)).


-spec get_fcm_apikey() -> string().
get_fcm_apikey() ->
    [{<<"apikey">>, Res}] = get_fcm_info(),
    binary_to_list(Res).

