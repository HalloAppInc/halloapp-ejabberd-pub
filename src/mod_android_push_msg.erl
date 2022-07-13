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
-include("push_message.hrl").

-define(HTTP_TIMEOUT_MILLISEC, 10000).             %% 10 seconds.
-define(HTTP_CONNECT_TIMEOUT_MILLISEC, 10000).     %% 10 seconds.

-define(HALLOAPP, <<"halloapp">>).
%% TODO: Should move away from having the key in the codebase.
%% Unfortunately one of the dependencies needs it in a file as of now. we can fix it eventually.
-define(GOOGLE_SERVICE_KEY_FILE, "google_service_key.json").
-define(REFRESH_TIME, 3540).    %% 59 minutes.
-define(FCM_URL_PREFIX, <<"https://fcm.googleapis.com/v1/projects/">>).
-define(FCM_URL_SUFFIX, <<"/messages:send">>).
-define(SCOPE_URL, <<"https://www.googleapis.com/auth/firebase.messaging">>).

-export([
    push_message_item/2,
    refresh_token/0
]).

%% gen_mod API
-export([start/2, stop/1, reload/3, depends/2, mod_options/1]).
%% gen_server API
-export([init/1, terminate/2, handle_call/3, handle_cast/2, handle_info/2]).


-spec push_message_item(PushMessageItem :: push_message_item(), ParentPid :: pid()) -> ok.
push_message_item(PushMessageItem, ParentPid) ->
    gen_server:cast(?PROC(), {push_message_item, PushMessageItem, ParentPid}),
    ok.

refresh_token() ->
    gen_server:cast(?PROC(), {refresh_token}),
    ok.


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

init([_Host|_]) ->
    ServiceKeyFilePath = filename:join(misc:data_dir(), ?GOOGLE_SERVICE_KEY_FILE),
    State = reload_access_token(#{service_key_file => ServiceKeyFilePath}),
    {ok, State}.


terminate(_Reason, #{}) ->
    ok.

% Should never be called
handle_call(Request, _From, State) ->
    ?DEBUG("unknown request: ~p", [Request]),
    {reply, ok, State}.


handle_cast({ping, Id, Ts, From}, State) ->
    util_monitor:send_ack(self(), From, {ack, Id, Ts, self()}),
    {noreply, State};

handle_cast({push_message_item, PushMessageItem, ParentPid}, State) ->
    NewState = push_message_item(PushMessageItem, State, ParentPid),
    {noreply, NewState};

handle_cast({refresh_token}, State) ->
    NewState = reload_access_token(State),
    {noreply, NewState};

handle_cast(crash, _State) ->
    error(test_crash);
handle_cast(Request, State) ->
    ?DEBUG("unknown request: ~p", [Request]),
    {noreply, State}.


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
    AuthToken = <<"Bearer ", AccessToken/binary>>,
    FcmUrl = util:to_list(<<?FCM_URL_PREFIX/binary, ProjectId/binary, ?FCM_URL_SUFFIX/binary>>),
    State#{
        fcm_url => FcmUrl,
        auth_token => AuthToken,
        token_tref => erlang:send_after(timer:seconds(?REFRESH_TIME), self(), refresh_token)
    }.


-spec push_message_item(PushMessageItem :: push_message_item(), State :: map(), ParentPid :: pid()) -> map().
push_message_item(PushMessageItem, #{fcm_url := FcmUrl, auth_token := AuthToken} = State, ParentPid) ->
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
    Options = [{sync, false}, {receiver, ParentPid}],
    Request = {FcmUrl, [{"Authorization", AuthToken}], "application/json; UTF-8", jiffy:encode(PushBody)},

    %% Send the request.
    case httpc:request(post, Request, HTTPOptions, Options) of
        {ok, RequestId} ->
            ?INFO("Uid: ~s, MsgId: ~s, ContentId: ~s, ContentType: ~s, RequestId: ~p",
                [Uid, Id, ContentId, ContentType, RequestId]),
            erlang:send(ParentPid, {add_to_pending_map, RequestId, PushMessageItem}),
            State;
        {error, Reason} ->
            ?ERROR("Push failed, Uid:~s, token: ~p, reason: ~p",
                    [Uid, binary:part(Token, 0, 10), Reason]),
            retry_message_item(PushMessageItem, ParentPid),
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
        _ -> #{<<"data">> => #{}, <<"fcm_options">> => #{<<"analytics_label">> => ?HALLOAPP}}
    end,
    {NotificationMap, DataMap}.


-spec retry_message_item(PushMessageItem :: push_message_item(), ParentPid :: pid()) -> reference().
retry_message_item(PushMessageItem, ParentPid) ->
    RetryTime = PushMessageItem#push_message_item.retry_ms,
    setup_timer({retry, PushMessageItem}, ParentPid, RetryTime).


-spec setup_timer(Msg :: any(), ParentPid :: pid(), Timeout :: integer()) -> reference().
setup_timer(Msg, ParentPid, Timeout) ->
    NewTimer = erlang:send_after(Timeout, ParentPid, Msg),
    NewTimer.


-spec cancel_token_timer(State :: map()) -> ok.
cancel_token_timer(#{token_tref := TimerRef}) ->
    erlang:cancel_timer(TimerRef);
cancel_token_timer(_) ->
    ok.

