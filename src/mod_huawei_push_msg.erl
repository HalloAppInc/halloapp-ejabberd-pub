%%%-------------------------------------------------------------------------------------------
%%% File    : mod_huawei_push_msg.erl
%%%
%%% Copyright (C) 2022 HalloApp inc.
%%%
%%% Supplement to mod_android_push. Sends a push notification and handles its response.
%%% Retry push messages are sent back to mod_android_push.
%%% 
%%% Broken into three sections: 
%%% getting an access token to send message, sending the messages, processing the response
%%%
%%% TODO: add wpools, track if clients wake up (mod_wakeup), track if pushes fail (mod_push_monitor)
%%%-------------------------------------------------------------------------------------------

-module(mod_huawei_push_msg).
-author('michelle').

-behaviour(gen_mod).
-behaviour(gen_server).

-include("logger.hrl").
-include("push_message.hrl").
-include("proc.hrl").
-include("time.hrl").

%% gen_mod API
-export([start/2, stop/1, reload/3, depends/2, mod_options/1]).
%% gen_server API
-export([init/1, terminate/2, code_change/3, handle_call/3, handle_cast/2, handle_info/2]).

%% API
-export([push_message/1]).


-define(REFRESH_TIME_MS, (60 * ?MINUTES_MS)).          %% 60 minutes.
-define(HTTP_TIMEOUT_MS, (60 * ?SECONDS)).             %% 60 seconds.
-define(HTTP_CONNECT_TIMEOUT_MS, (60 * ?SECONDS)).     %% 60 seconds.

-define(HUAWEI_URL_PREFIX, <<"https://push-api.cloud.huawei.com/v1/">>).
-define(HUAWEI_URL_SUFFIX, <<"/messages:send">>).

-define(CLIENT_ID, <<"106829255">>).

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
    [].

reload(_Host, _NewOpts, _OldOpts) ->
    ok.

mod_options(_Host) ->
    [].

%%====================================================================
%% API
%%====================================================================

push_message(PushMessageItem) ->
    gen_server:cast(?PROC(), {push_message_item, PushMessageItem}),
    ok.

%%====================================================================
%% gen_server callbacks
%%====================================================================

init([Host|_]) ->
    PushUrl = util:to_list(<<?HUAWEI_URL_PREFIX/binary, ?CLIENT_ID/binary, ?HUAWEI_URL_SUFFIX/binary>>),
    State = load_access_token(#{}),
    {ok, State#{host => Host, url => PushUrl, pending_map => #{} }}.


terminate(_Reason, #{host := _Host}) ->
    ok.


code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


handle_call(_Request, _From, State) ->
    ?ERROR("invalid call request: ~p", [_Request]),
    {reply, {error, invalid_request}, State}.


handle_cast({ping, Id, Ts, From}, State) ->
    util_monitor:send_ack(self(), From, {ack, Id, Ts, self()}),
    {noreply, State};
handle_cast({push_message_item, PushMessageItem}, State) ->
    Id = PushMessageItem#push_message_item.id,
    Uid = PushMessageItem#push_message_item.uid,
    Token = PushMessageItem#push_message_item.push_info#push_info.huawei_token,
    case Token =:= undefined orelse Token =:= <<>> of
        true ->
            ?INFO("Ignoring push for Uid: ~p MsgId: ~p due to invalid token: ~p", [Uid, Id, Token]),
            {noreply, State};
        false ->
            NewState = push_message_item(PushMessageItem, State),
            {noreply, NewState}
    end;
handle_cast(_Request, State) ->
    ?DEBUG("Invalid request, ignoring it: ~p", [_Request]),
    {noreply, State}.


handle_info(load_access_token, State) ->
    NewState = load_access_token(State),
    {noreply, NewState};
handle_info({http, {RequestId, _Response} = ReplyInfo}, #{pending_map := PendingMap} = State) ->
    State2 = case maps:take(RequestId, PendingMap) of
        error ->
            ?ERROR("Request not found in our map: RequestId: ~p", [RequestId]),
            State#{pending_map => PendingMap};
        {PushMessageItem, NewPendingMap} ->
            State1 = handle_huawei_response(ReplyInfo, PushMessageItem, State),
            State1#{pending_map => NewPendingMap}
    end,
    {noreply, State2};
handle_info(Request, State) ->
    ?DEBUG("Unknown request: ~p, ~p", [Request, State]),
    {noreply, State}.


%%====================================================================
%% Access Token functions
%%
%% Ref: https://developer.huawei.com/consumer/en/doc/development/HMSCore-Guides/oauth2-0000001212610981#section128682386159
%%====================================================================

-spec load_access_token(State :: map()) -> map().
load_access_token(State) ->
    ?DEBUG("huawei reload_access_token"),
    cancel_token_timer(State),
    {ok, {Result}} = get_access_token(),
    AccessToken = proplists:get_value(<<"access_token">>, Result, undefined),
    AuthToken = util:to_list(<<"Bearer ", AccessToken/binary>>),
    ?DEBUG("AuthToken: ~p, ~p", [AccessToken, AuthToken]),
    State#{
        auth_token => AuthToken,
        refresh_tref => erlang:send_after(?REFRESH_TIME_MS, self(), load_access_token)
    }.


-spec get_access_token() -> {ok, jiffy:json_value()} | {error, any()}.
get_access_token() ->
    URL = "https://oauth-login.cloud.huawei.com/oauth2/v3/token",
    ContentType = "application/x-www-form-urlencoded",
    ClientId = <<"grant_type=client_credentials&client_id=">> ,
    ClientSecret = iolist_to_binary([<<"&client_secret=">>, get_client_secret()]),
    Body = iolist_to_binary([ClientId, ?CLIENT_ID, ClientSecret]),
    Response = httpc:request(post, {URL, [], ContentType, Body}, [], []),
    ?INFO("Response from getting huawei access token ~p", [Response]),
    case Response of
        {ok, {{_,200,_}, _, Result}} -> {ok, jiffy:decode(Result)};
        {ok, Reason} -> {error, Reason};
        {error, _} = Error -> Error
    end.


-spec cancel_token_timer(State :: map()) -> ok.
cancel_token_timer(#{token_tref := TimerRef}) ->
    erlang:cancel_timer(TimerRef);
cancel_token_timer(_) ->
    ok.


-spec get_client_secret() -> string().
get_client_secret() ->
    mod_aws:get_secret_value(<<"Huawei">>, <<"client_secret">>).

%%====================================================================
%% Push request logic
%%
%% Ref: https://developer.huawei.com/consumer/en/doc/development/HMSCore-Guides/android-server-dev-0000001050040110 
%%====================================================================

-spec push_message_item(PushMessageItem :: push_message_item(), map()) -> map().
push_message_item(PushMessageItem, #{auth_token := AuthToken, url := Url, pending_map := PendingMap} = State) ->
    PushMetadata = push_util:parse_metadata(PushMessageItem#push_message_item.message),
    Id = PushMessageItem#push_message_item.id,
    Uid = PushMessageItem#push_message_item.uid,
    ContentId = PushMetadata#push_metadata.content_id,
    ContentType = PushMetadata#push_metadata.content_type,
    Token = PushMessageItem#push_message_item.push_info#push_info.huawei_token,

    AndroidMap = extract_android_map(PushMessageItem, PushMetadata),
    PushBody = #{
        % <<"validate_only">> => <<"true">>, % set true for test mode
        <<"message">> => #{
            <<"token">> => [Token],
            <<"android">> => AndroidMap,
            <<"data">> => <<"{\"title\":\"test\",\"body\":\"test\"}">>
        }
    },

    Request = {Url, [{"Authorization", AuthToken}], "application/json; charset=UTF-8", jiffy:encode(PushBody)},
    HTTPOptions = [],
    Options = [{sync, false}, {receiver, self()}],
    ?DEBUG("Request: ~p", [Request]),

    %% Send the request.
    case httpc:request(post, Request, HTTPOptions, Options) of
        {ok, RequestId} ->
            ?INFO("Uid: ~s, MsgId: ~s, ContentId: ~s, ContentType: ~s, RequestId: ~p",
                [Uid, Id, ContentId, ContentType, RequestId]),
            NewPendingMap = PendingMap#{RequestId => PushMessageItem},
            State#{pending_map => NewPendingMap};
        {error, Reason} ->
            ?ERROR("Push failed, Uid:~s, token: ~p, reason: ~p", [Uid, binary:part(Token, 0, 10), Reason]),
            mod_android_push:retry_message_item(PushMessageItem),
            State
    end.


-spec extract_android_map(PushMessageItem :: push_message_item(), PushMetadata :: push_metadata()) -> map().
extract_android_map(PushMessageItem, PushMetadata) ->
    AndroidMap = case PushMetadata#push_metadata.push_type of
        direct_alert ->
            Version = PushMessageItem#push_message_item.push_info#push_info.client_version,
            {Title, Body} = push_util:get_title_body(
                PushMessageItem#push_message_item.message,
                PushMessageItem#push_message_item.push_info),   
            ChannelId = case util_ua:is_version_greater_than(Version, <<"HalloApp/Android0.216">>) of
                true -> <<"broadcast_notifications">>;
                false -> <<"critical_notifications">>
            end,
            NotificationMap = #{
                <<"title">> => Title,
                <<"body">> => Body,
                % Click Action Options: 1 - open custom app page, 2 - open URL, 3 - start app
                <<"click_action">> => <<"3">>,
                <<"importance">> => <<"NORMAL">>,
                <<"sound">> => <<"default">>,
                <<"icon">> => <<"ic_notification">>,
                <<"channel_id">> => ChannelId,
                <<"color">> => <<"#ff4500">>
            },
            #{<<"notification">> => NotificationMap};
        _ ->
            #{}
    end,
    AndroidMap.

%%====================================================================
%% Push response logic
%%
%% Ref: https://developer.huawei.com/consumer/en/doc/development/HMSCore-References/https-send-api-0000001050986197#section723545214380
%%====================================================================

-spec handle_huawei_response({Id ::reference(), Response :: term()},
        PushMessageItem :: push_message_item(), State :: map()) -> State :: map().
handle_huawei_response({_Id, Response}, PushMessageItem, #{host := _Host} = State) ->
    Id = PushMessageItem#push_message_item.id,
    Uid = PushMessageItem#push_message_item.uid,
    Version = PushMessageItem#push_message_item.push_info#push_info.client_version,
    ContentType = PushMessageItem#push_message_item.content_type,
    Token = PushMessageItem#push_message_item.push_info#push_info.huawei_token,
    TokenPart = binary:part(Token, 0, 10),
    case Response of
        {{_, StatusCode5xx, _}, _, Body} when StatusCode5xx >= 500 andalso StatusCode5xx < 600 ->
            stat:count("HA/push", ?HUAWEI, 1, [{"result", "huawei_error"}]),
            ?ERROR("Push failed, Uid: ~s, Token: ~p, Code ~p, recoverable huawei error: ~p",
                    [Uid, TokenPart, StatusCode5xx, Body]),
            mod_android_push:retry_message_item(PushMessageItem),
            State;
        {{_, 200, _}, _, Body} ->
            ?INFO("Uid:~s push successful for msg-id: ~s", [Uid, Id]),
            case parse_response(Body) of
                {ok, ReqId} ->
                    stat:count("HA/push", ?HUAWEI, 1, [{"result", "success"}]),
                    ?INFO("Uid:~s push successful for msg-id: ~s, Huawei Id: ~p", [Uid, Id, ReqId]),
                    {ok, Phone} = model_accounts:get_phone(Uid),
                    CC = mod_libphonenumber:get_cc(Phone),
                    ha_events:log_event(<<"server.push_sent">>, #{uid => Uid, push_id => ReqId,
                            platform => android, client_version => Version, push_type => silent,
                            push_api => huawei, content_type => ContentType, cc => CC});
                {error, _} ->
                    stat:count("HA/push", ?HUAWEI, 1, [{"result", "failure"}])
                    % remove_push_token(Uid, Host)
            end,
            State;
        {{_, 401, _}, _, _Body} ->
            stat:count("HA/push", ?HUAWEI, 1, [{"result", "huawei_error"}]),
            ?ERROR("Push failed, Uid: ~s, Token: ~p, expired auth token, Response: ~p", [Uid, TokenPart, Response]),
            mod_android_push:retry_message_item(PushMessageItem),
            NewState = load_access_token(State),
            NewState;
        {{_, 404, _}, _, _Body} ->
            stat:count("HA/push", ?HUAWEI, 1, [{"result", "failure"}]),
            ?ERROR("Push failed, Uid: ~s, Token: ~p, incorrect request url, Response: ~p", [Uid, TokenPart, Response]),
            % remove_push_token(Uid, Host),
            State;
        {_, _, _Body} ->
            stat:count("HA/push", ?HUAWEI, 1, [{"result", "failure"}]),
            ?ERROR("Push failed, Uid:~s, token: ~p, non-recoverable Huawei Response: ~p", [Uid, TokenPart, Response]),
            % remove_push_token(Uid, Host),
            State;
        {error, Reason} ->
            ?INFO("Push failed, Uid:~s, token: ~p, reason: ~p", [Uid, TokenPart, Reason]),
            mod_android_push:retry_message_item(PushMessageItem),
            State
    end.


-spec parse_response(binary()) -> {ok, string()} | {error, string()}.
parse_response(Body) ->
    {JsonData} = jiffy:decode(Body),
    ReqId = proplists:get_value(<<"requestId">>, JsonData, undefined),
    ResultCode = proplists:get_value(<<"code">>, JsonData, undefined),
    case ResultCode of
        <<"80000000">> ->
            ?DEBUG("Huawei success: ReqId: ~p response body: ~p", [ReqId, Body]),
            {ok, ReqId};
        _ ->
            ?INFO("Huawei error: ReqId: ~p Code: ~p response body: ~p", [ReqId, ResultCode, Body]),
            {error, ReqId}
    end.


% -spec remove_push_token(Uid :: binary(), Server :: binary()) -> ok.
% remove_push_token(Uid, Server) ->
%     mod_push_tokens:remove_huawei_token(Uid, Server).

