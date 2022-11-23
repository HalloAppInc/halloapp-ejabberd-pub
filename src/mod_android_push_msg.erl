%%%-------------------------------------------------------------------------------------------
%%% File    : mod_android_push_msg.erl
%%%
%%% Copyright (C) 2022 HalloApp inc.
%%%
%%% Supplement to mod_android_push. Helps send a push notification
%%%-------------------------------------------------------------------------------------------

-module(mod_android_push_msg).

-include("logger.hrl").
-include("proc.hrl").
-include("time.hrl").
-include("push_message.hrl").

-define(HTTP_TIMEOUT_MILLISEC, 10000).             %% 10 seconds.
-define(HTTP_CONNECT_TIMEOUT_MILLISEC, 10000).     %% 10 seconds.

%% TODO: Should move away from having the key in the codebase.
%% Unfortunately one of the dependencies needs it in a file as of now. we can fix it eventually.
-define(GOOGLE_SERVICE_KEY_FILE, "google_service_key.json").
-define(REFRESH_TIME_MS, 30 * ?MINUTES_MS).    %% 30 minutes.
-define(FCM_URL_PREFIX, <<"https://fcm.googleapis.com/v1/projects/">>).
-define(FCM_URL_SUFFIX, <<"/messages:send">>).
-define(SCOPE_URL, <<"https://www.googleapis.com/auth/firebase.messaging">>).

%% gen_mod API
-export([start/2, stop/1, reload/3, depends/2, mod_options/1]).
%% gen_server API
-export([init/1, terminate/2, handle_call/3, handle_cast/2, handle_info/2]).


%%====================================================================
%% gen_mod API.
%%====================================================================

start(Host, Opts) ->
    ?INFO("start ~w", [?MODULE]),
    gen_mod:start_child(?MODULE, Host, Opts, ?PROC()),
    ok.

stop(_Host) ->
    ?INFO("stop ~w", [?MODULE]),
    ok.

depends(_Host, _Opts) ->
    [{mod_aws, hard}].

reload(_Host, _NewOpts, _OldOpts) ->
    ok.

mod_options(_Host) ->
    [].


%%====================================================================
%% gen_server callbacks
%%====================================================================

init([Host|_]) ->
    ServiceKeyFilePath = filename:join(misc:data_dir(), ?GOOGLE_SERVICE_KEY_FILE),
    State = reload_access_token(#{service_key_file => ServiceKeyFilePath}),
    {ok, State#{host => Host, pending_map => #{}}}.


terminate(_Reason, #{}) ->
    ok.

% Should never be called
handle_call(Request, _From, State) ->
    ?DEBUG("unknown request: ~p", [Request]),
    {reply, ok, State}.


handle_cast({ping, Id, Ts, From}, State) ->
    util_monitor:send_ack(self(), From, {ack, Id, Ts, self()}),
    {noreply, State};

handle_cast({push_message_item, PushMessageItem}, State) ->
    Id = PushMessageItem#push_message_item.id,
    Uid = PushMessageItem#push_message_item.uid,
    Token = PushMessageItem#push_message_item.push_info#push_info.token,
    case Token =:= undefined orelse Token =:= <<>> of
        true ->
            ?INFO("Ignoring push for Uid: ~p MsgId: ~p due to invalid token: ~p", [Uid, Id, Token]),
            {noreply, State};
        false ->
            NewState = push_message_item(PushMessageItem, State),
            {noreply, NewState}
    end;
handle_cast(refresh_token, State) ->
    NewState = reload_access_token(State),
    {noreply, NewState};

handle_cast(crash, _State) ->
    error(test_crash);
handle_cast(Request, State) ->
    ?DEBUG("unknown request: ~p", [Request]),
    {noreply, State}.


handle_info({http, {RequestId, _Response} = ReplyInfo}, #{pending_map := PendingMap} = State) ->
    State2 = case maps:take(RequestId, PendingMap) of
        error ->
            ?ERROR("Request not found in our map: RequestId: ~p", [RequestId]),
            State#{pending_map => PendingMap};
        {PushMessageItem, NewPendingMap} ->
            State1 = handle_fcm_response(ReplyInfo, PushMessageItem, State),
            State1#{pending_map => NewPendingMap}
    end,
    {noreply, State2};

handle_info(refresh_token, State) ->
    NewState = reload_access_token(State),
    {noreply, NewState};

handle_info(Request, State) ->
    ?DEBUG("unknown request: ~p", [Request]),
    {noreply, State}.


%%====================================================================
%% internal module functions
%%====================================================================


-spec reload_access_token(State :: map()) -> map().
reload_access_token(#{service_key_file := ServiceKeyFilePath} = State) ->
    ?INFO("reload_access_token, service_key_file: ~p", [ServiceKeyFilePath]),
    cancel_token_timer(State),
    {ok, SecretBin} = file:read_file(ServiceKeyFilePath),
    #{project_id := ProjectId} = jsx:decode(SecretBin, [return_maps, {labels, atom}]),
    {ok, #{access_token := AccessToken}} = google_oauth:get_access_token(ServiceKeyFilePath, ?SCOPE_URL),
    AuthToken = util:to_list(<<"Bearer ", AccessToken/binary>>),
    ?DEBUG("AuthToken: ~p, ~p", [AccessToken, AuthToken]),
    FcmUrl = util:to_list(<<?FCM_URL_PREFIX/binary, ProjectId/binary, ?FCM_URL_SUFFIX/binary>>),
    State#{
        fcm_url => FcmUrl,
        auth_token => AuthToken,
        token_tref => erlang:send_after(?REFRESH_TIME_MS, self(), refresh_token)
    }.


-spec push_message_item(PushMessageItem :: push_message_item(), State :: map()) -> map().
push_message_item(PushMessageItem, #{fcm_url := FcmUrl,
        auth_token := AuthToken, pending_map := PendingMap} = State) ->
    PushMetadata = push_util:parse_metadata(PushMessageItem#push_message_item.message),
    Id = PushMessageItem#push_message_item.id,
    Uid = PushMessageItem#push_message_item.uid,
    ContentId = PushMetadata#push_metadata.content_id,
    ContentType = PushMetadata#push_metadata.content_type,
    Token = PushMessageItem#push_message_item.push_info#push_info.token,

    %% Extract Notification
    {NotificationMap, DataMap} = extract_payload_maps(PushMessageItem, PushMetadata),
    %% Compose body
    PushBody = #{
        <<"message">> => #{
            <<"token">> => Token,
            <<"data">> => DataMap,
            <<"android">> => #{
                <<"priority">> => <<"high">>,
                <<"notification">> => NotificationMap
            },
            <<"fcm_options">> => #{
                <<"analytics_label">> => <<"halloapp">>
            }
        }
    },
    %% Setup options
    HTTPOptions = [
            {timeout, ?HTTP_TIMEOUT_MILLISEC},
            {connect_timeout, ?HTTP_CONNECT_TIMEOUT_MILLISEC}
    ],
    Options = [{sync, false}, {receiver, self()}],
    Request = {FcmUrl, [{"Authorization", AuthToken}], "application/json; UTF-8", jiffy:encode(PushBody)},

    %% Send the request.
    case httpc:request(post, Request, HTTPOptions, Options) of
        {ok, RequestId} ->
            ?INFO("Uid: ~s, MsgId: ~s, ContentId: ~s, ContentType: ~s, RequestId: ~p",
                [Uid, Id, ContentId, ContentType, RequestId]),
            NewPendingMap = PendingMap#{RequestId => PushMessageItem},
            State#{pending_map => NewPendingMap};
        {error, Reason} ->
            ?ERROR("Push failed, Uid:~s, token: ~p, reason: ~p",
                    [Uid, binary:part(Token, 0, 10), Reason]),
            mod_android_push:retry_message_item(PushMessageItem),
            State
    end.


-spec extract_payload_maps(PushMessageItem :: push_message_item(),
        PushMetadata :: push_metadata()) -> {map(), map()}.
extract_payload_maps(PushMessageItem, PushMetadata) ->
    Version = PushMessageItem#push_message_item.push_info#push_info.client_version,
    NotificationMap = case PushMetadata#push_metadata.push_type of
        direct_alert ->
            % Used only in marketing alerts
            {Title, Body} = push_util:get_title_body(
                PushMessageItem#push_message_item.message,
                PushMessageItem#push_message_item.push_info),
            NotificationContentMap = #{
                <<"title">> => Title,
                <<"body">> => Body
            },
            ChannelId = case util_ua:is_version_greater_than(Version, <<"HalloApp/Android0.216">>) of
                true -> <<"broadcast_notifications">>;
                false -> <<"critical_notifications">>
            end,
            DirectAlertMap = NotificationContentMap#{
                <<"sound">> => <<"default">>,
                <<"icon">> => <<"ic_notification">>,
                <<"android_channel_id">> => ChannelId,
                <<"color">> => <<"#ff4500">>
            },
            DirectAlertMap;
        _ ->
            #{}
    end,
    DataMap = case PushMetadata#push_metadata.push_type of
        direct_alert -> #{};
        _ -> #{<<"test">> => <<"test">>}
    end,
    {NotificationMap, DataMap}.


-spec cancel_token_timer(State :: map()) -> ok.
cancel_token_timer(#{token_tref := TimerRef}) ->
    erlang:cancel_timer(TimerRef);
cancel_token_timer(_) ->
    ok.


-spec handle_fcm_response({RequestId :: reference(), Response :: term()},
        PushMessageItem :: push_message_item(), State :: map()) -> State :: map().
handle_fcm_response({_RequestId, Response}, PushMessageItem, #{host := _ServerHost} = State) ->
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
            mod_android_push:retry_message_item(PushMessageItem),
            State;
        {{_, 200, _}, _, ResponseBody} ->
            case parse_response(ResponseBody) of
                {ok, FcmId} ->
                    stat:count("HA/push", ?FCM, 1, [{"result", "success"}]),
                    ?INFO("Uid:~s push successful for msg-id: ~s, FcmId: ~p", [Uid, Id, FcmId]),
                    %% TODO: We should capture this info in the push info itself.
                    {ok, Phone} = model_accounts:get_phone(Uid),
                    CC = mod_libphonenumber:get_cc(Phone),
                    mod_wakeup:monitor_push(Uid, PushMessageItem#push_message_item.message),
                    mod_android_push:pushed_message(PushMessageItem, success),
                    ha_events:log_event(<<"server.push_sent">>, #{uid => Uid, push_id => FcmId,
                            platform => android, client_version => Version, push_type => silent,
                            push_api => fcm, content_type => ContentType, cc => CC});
                {error, Reason, FcmId} ->
                    stat:count("HA/push", ?FCM, 1, [{"result", "failure"}]),
                    ?ERROR("Push failed: Server Error, Uid:~s, token: ~p, reason: ~p, FcmId: ~p",
                        [Uid, binary:part(Token, 0, 10), Reason, FcmId]),
                    % remove_push_token(Uid, ServerHost),
                    mod_android_push:pushed_message(PushMessageItem, failure)
            end,
            State;
        {{_, 401, _}, _, ResponseBody} ->
            stat:count("HA/push", ?FCM, 1, [{"result", "fcm_error"}]),
            ?ERROR("Push failed, Uid: ~s, Token: ~p, expired auth token, Response: ~p",
                    [Uid, binary:part(Token, 0, 10), ResponseBody]),
            erlang:send(self(), refresh_token),
            mod_android_push:retry_message_item(PushMessageItem),
            NewState = reload_access_token(State),
            NewState;
        {{_, 404, _}, _, ResponseBody} ->
            stat:count("HA/push", ?FCM, 1, [{"result", "failure"}]),
            ?INFO("Push failed, Uid:~s, token: ~p, unregistered FCM error: ~p",
                    [Uid, binary:part(Token, 0, 10), ResponseBody]),
            % remove_push_token(Uid, ServerHost),
            mod_android_push:pushed_message(PushMessageItem, failure),
            State;
        {{_, _, _}, _, ResponseBody} ->
            stat:count("HA/push", ?FCM, 1, [{"result", "failure"}]),
            ?ERROR("Push failed, Uid:~s, token: ~p, non-recoverable FCM error: ~p",
                    [Uid, binary:part(Token, 0, 10), ResponseBody]),
            % remove_push_token(Uid, ServerHost),
            mod_android_push:pushed_message(PushMessageItem, failure),
            State;
        {error, Reason} ->
            ?INFO("Push failed, Uid:~s, token: ~p, reason: ~p",
                    [Uid, binary:part(Token, 0, 10), Reason]),
            mod_android_push:retry_message_item(PushMessageItem),
            State
    end.


%% Parses response of the request to check if everything worked successfully.
-spec parse_response(binary()) -> {ok, string()} | {error, any(), any()}.
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


% -spec remove_push_token(Uid :: binary(), Server :: binary()) -> ok.
% remove_push_token(Uid, Server) ->
%     mod_push_tokens:remove_android_token(Uid, Server).

