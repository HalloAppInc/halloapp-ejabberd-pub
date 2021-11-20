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

-type endpoint_type() :: prod | dev | voip_dev | voip_prod.

-define(MESSAGE_EXPIRY_TIME_SEC, 1 * ?DAYS).    %% seconds in 1 day.
-define(RETRY_INTERVAL_MILLISEC, 30 * ?SECONDS_MS).    %% 30 seconds.
-define(MESSAGE_MAX_RETRY_TIME_SEC, 10 * ?MINUTES).    %% 10 minutes.
-define(MAX_PUSH_PAYLOAD_SIZE, 3500).   % 3500 bytes.

-define(APNS_ID, <<"apns-id">>).
-define(APNS_PRIORITY, <<"apns-priority">>).
-define(APNS_EXPIRY, <<"apns-expiration">>).
-define(APNS_TOPIC, <<"apns-topic">>).
-define(APNS_PUSH_TYPE, <<"apns-push-type">>).
-define(APNS_COLLAPSE_ID, <<"apns-collapse-id">>).
-define(APP_BUNDLE_ID, <<"com.halloapp.hallo">>).
-define(APP_VOIP_BUNDLE_ID, <<"com.halloapp.hallo.voip">>).

%% APNS gateway and certificate details.
-define(APNS_GATEWAY, "api.push.apple.com").
-define(APNS_PORT, 443).
-define(APNS_CERTFILE_SM, <<"apns_prod.pem">>).
-define(APNS_DEV_GATEWAY, "api.sandbox.push.apple.com").
-define(APNS_DEV_PORT, 443).
-define(APNS_DEV_CERTFILE_SM, <<"apns_dev.pem">>).
-define(APNS_VOIP_CERTFILE_SM, <<"voip_prod.pem">>).
-define(IOS_ENDPOINT_TYPES, [prod, dev, voip_prod, voip_dev]).

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
    {Pid, Mon} = connect_to_apns(prod),
    {DevPid, DevMon} = connect_to_apns(dev),
    {VoipPid, VoipMon} = connect_to_apns(voip_prod),
    {VoipDevPid, VoipDevMon} = connect_to_apns(voip_dev),
    %% TODO: Move all voip push logic to its own gen_server.
    {NoiseStaticKey, NoiseCertificate} = util:get_noise_key_material(),
    {ok, #push_state{
            pendingMap = #{},
            host = Host,
            conn = Pid,
            mon = Mon,
            dev_conn = DevPid,
            dev_mon = DevMon,
            voip_conn = VoipPid,
            voip_mon = VoipMon,
            voip_dev_conn = VoipDevPid,
            voip_dev_mon = VoipDevMon,
            noise_static_key = NoiseStaticKey,
            noise_certificate = NoiseCertificate}}.


terminate(_Reason, #push_state{host = _Host, conn = Pid, mon = Mon, dev_conn = DevPid,
        dev_mon = DevMon, voip_conn = VoipPid, voip_mon = VoipMon,
        voip_dev_conn = VoipDevPid, voip_dev_mon = VoipDevMon}) ->
    demonitor(Mon),
    gun:close(Pid),
    demonitor(DevMon),
    gun:close(DevPid),
    demonitor(VoipMon),
    gun:close(VoipPid),
    demonitor(VoipDevMon),
    gun:close(VoipDevPid),
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
    %% TODO(vipin): We need to evaluate the cost of recording the push in Redis
    %% in this gen_server instead of outside.

    %% Ignore the push notification if it has already been sent.
    NewState = case push_util:record_push_sent(Message, PushInfo) of
        false -> 
                ?INFO("Push notification already sent for MsgId: ~p", [Message#pb_msg.id]),
                State;
        true -> push_message(Message, PushInfo, State)
    end,
    {noreply, NewState};

handle_cast(crash, _State) ->
    error(test_crash);

handle_cast(_Request, State) ->
    ?DEBUG("Invalid request, ignoring it: ~p", [_Request]),
    {noreply, State}.


-spec connect_to_apns(EndpointType :: endpoint_type()) -> {pid(), reference()} | {undefined, undefined}.
connect_to_apns(EndpointType) ->
    ApnsGateway = get_apns_gateway(EndpointType),
    {Cert, Key} = get_apns_cert(EndpointType),
    ApnsPort = get_apns_port(EndpointType),
    RetryFun = fun retry_function/2,
    Options = #{
        protocols => [http2],
        tls_opts => [{cert, Cert}, {key, Key}],
        retry => 100,                      %% gun will retry connecting 100 times before giving up!
        retry_timeout => 5000,             %% Time between retries in milliseconds.
        retry_fun => RetryFun
    },
    ?INFO("EndpointType: ~s, Gateway: ~s, Port: ~p", [EndpointType, ApnsGateway, ApnsPort]),
    case gun:open(ApnsGateway, ApnsPort, Options) of
        {ok, Pid} ->
            Mon = monitor(process, Pid),
            case gun:await_up(Pid, Mon) of
                {ok, Protocol} ->
                    ?INFO("EndpointType: ~s, connection successful pid: ~p, protocol: ~p, monitor: ~p",
                            [EndpointType, Pid, Protocol, Mon]),
                    {Pid, Mon};
                {error, Reason} ->
                    ?ERROR("EndpointType: ~s, Failed to connect to apns: ~p", [EndpointType, Reason]),
                    {undefined, undefined}
            end;
        {error, Reason} ->
            ?ERROR("EndpointType: ~s, Failed to connect to apns: ~p", [EndpointType, Reason]),
            {undefined, undefined}
    end.


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
    CurTimestamp = util:now(),
    MsgTimestamp = PushMessageItem#push_message_item.timestamp,
    %% Stop retrying after 10 minutes!
    NewState = case CurTimestamp - MsgTimestamp < ?MESSAGE_MAX_RETRY_TIME_SEC of
        false ->
            ?INFO("Uid: ~s push failed, no more retries msg_id: ~s", [Uid, Id]),
            State;
        true ->
            ?INFO("Uid: ~s, retry push_message_item: ~p", [Uid, Id]),
            NewRetryMs = round(PushMessageItem#push_message_item.retry_ms * ?GOLDEN_RATIO),
            NewPushMessageItem = PushMessageItem#push_message_item{retry_ms = NewRetryMs},
            push_message_item(NewPushMessageItem, State)
    end,
    {noreply, NewState};

handle_info({'DOWN', Mon, process, Pid, Reason},
        #push_state{conn = Pid, mon = Mon} = State) ->
    ?INFO("prod gun_down pid: ~p, mon: ~p, reason: ~p", [Pid, Mon, Reason]),
    {NewPid, NewMon} = connect_to_apns(prod),
    {noreply, State#push_state{conn = NewPid, mon = NewMon}};

handle_info({'DOWN', DevMon, process, DevPid, Reason},
        #push_state{dev_conn = DevPid, dev_mon = DevMon} = State) ->
    ?INFO("dev gun_down pid: ~p, mon: ~p, reason: ~p", [DevPid, DevMon, Reason]),
    {NewDevPid, NewDevMon} = connect_to_apns(dev),
    {noreply, State#push_state{dev_conn = NewDevPid, dev_mon = NewDevMon}};

handle_info({'DOWN', VoipMon, process, VoipPid, Reason},
        #push_state{voip_conn = VoipPid, voip_mon = VoipMon} = State) ->
    ?INFO("voip_prod gun_down pid: ~p, mon: ~p, reason: ~p", [VoipPid, VoipMon, Reason]),
    {NewVoipPid, NewVoipMon} = connect_to_apns(voip_prod),
    {noreply, State#push_state{voip_conn = NewVoipPid, voip_mon = NewVoipMon}};

handle_info({'DOWN', VoipDevMon, process, VoipDevPid, Reason},
        #push_state{voip_dev_conn = VoipDevPid, voip_dev_mon = VoipDevMon} = State) ->
    ?INFO("voip_dev gun_down pid: ~p, mon: ~p, reason: ~p", [VoipDevPid, VoipDevMon, Reason]),
    {NewVoipDevPid, NewVoipDevMon} = connect_to_apns(voip_dev),
    {noreply, State#push_state{voip_dev_conn = NewVoipDevPid, voip_dev_mon = NewVoipDevMon}};

handle_info({'DOWN', _Mon, process, Pid, Reason}, State) ->
    ?ERROR("down message from gun pid: ~p, reason: ~p", [Pid, Reason]),
    {noreply, State};

handle_info({gun_response, ConnPid, StreamRef, _, StatusCode, Headers}, State) ->
    ?DEBUG("gun_response: conn_pid: ~p, streamref: ~p, status: ~p, headers: ~p",
            [ConnPid, StreamRef, StatusCode, Headers]),
    ApnsId = proplists:get_value(?APNS_ID, Headers, undefined),
    NewState = handle_apns_response(StatusCode, ApnsId, State),
    {noreply, NewState};

handle_info({gun_data, ConnPid, StreamRef, _, Response}, State) ->
    ?INFO("gun_data: conn_pid: ~p, streamref: ~p, data: ~p", [ConnPid, StreamRef, Response]),
    {noreply, State};

handle_info(Request, State) ->
    ?DEBUG("unknown request: ~p", [Request]),
    {noreply, State}.



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
            ?INFO("Uid: ~s, apns push successful: msg_id: ~s", [Uid, Id]),
            mod_client_log:log_event(<<"server.push_sent">>, #{uid => Uid, push_id => Id,
                    platform => ios, client_version => Version, push_type => PushType}),
            NewPendingMap
    end,
    State#push_state{pendingMap = FinalPendingMap};

handle_apns_response(StatusCode, ApnsId, #push_state{pendingMap = PendingMap} = State)
        when StatusCode =:= 429; StatusCode >= 500 ->
    stat:count("HA/push", ?APNS, 1, [{"result", "apns_error"}]),
    FinalPendingMap = case maps:take(ApnsId, PendingMap) of
        error ->
            ?ERROR("Message not found in our map: apns-id: ~p", [ApnsId]),
            State;
        {PushMessageItem, NewPendingMap} ->
            Id = PushMessageItem#push_message_item.id,
            Uid = PushMessageItem#push_message_item.uid,
            ?WARNING("Uid: ~s, apns push error: msg_id: ~s, will retry", [Uid, Id]),
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
            State;
        {PushMessageItem, NewPendingMap} ->
            Id = PushMessageItem#push_message_item.id,
            Uid = PushMessageItem#push_message_item.uid,
            ?ERROR("Uid: ~s, apns push error: msg_id: ~s, needs to be fixed!", [Uid, Id]),
            NewPendingMap
    end,
    State#push_state{pendingMap = FinalPendingMap};

handle_apns_response(StatusCode, ApnsId, State) ->
    ?ERROR("Invalid status code : ~p, from apns, apns-id: ~p", [StatusCode, ApnsId]),
    State.




%%====================================================================
%% internal module functions
%%====================================================================

%% TODO(murali@): Figure out a way to better use the message-id.
-spec push_message(Message :: pb_msg(), PushInfo :: push_info(),
        State :: push_state()) -> push_state().
push_message(Message, PushInfo, State) ->
    MsgId = pb:get_id(Message),
    Uid = pb:get_to(Message),
    try
        Timestamp = util:now(),
        PushMetadata = push_util:parse_metadata(Message, PushInfo),
        PushMessageItem = #push_message_item{
            id = MsgId,
            uid = Uid,
            message = Message,
            timestamp = Timestamp,
            retry_ms = ?RETRY_INTERVAL_MILLISEC,
            push_info = PushInfo,
            push_type = PushMetadata#push_metadata.push_type},
        push_message_item(PushMessageItem, PushMetadata, State)
    catch
        Class: Reason: Stacktrace ->
            ?ERROR("Failed to push MsgId: ~s ToUid: ~s crash:~s",
                [MsgId, Uid, lager:pr_stacktrace(Stacktrace, {Class, Reason})]),
            ok
    end.


-spec push_message_item(PushMessageItem :: push_message_item(),
        State :: push_state()) -> push_state().
push_message_item(PushMessageItem, State) ->
    PushMetadata = push_util:parse_metadata(PushMessageItem#push_message_item.message,
            PushMessageItem#push_message_item.push_info),
    NewPushMessageItem = PushMessageItem#push_message_item{
            push_type = PushMetadata#push_metadata.push_type},
    push_message_item(NewPushMessageItem, PushMetadata, State).


-spec push_message_item(PushMessageItem :: push_message_item(), PushMetadata :: push_metadata(),
        State :: push_state()) -> push_state().
push_message_item(PushMessageItem, PushMetadata, State) ->
    Message = PushMessageItem#push_message_item.message,
    Os = PushMessageItem#push_message_item.push_info#push_info.os,
    EndpointType = case {util:is_voip_incoming_message(Message), Os} of
        {true, <<"ios">>} -> voip_prod;
        {true, <<"ios_dev">>} -> voip_dev;
        {false, <<"ios">>} -> prod;
        {false, <<"ios_dev">>} -> dev
    end,
    PushType = PushMetadata#push_metadata.push_type,
    PayloadBin = get_payload(PushMessageItem, PushMetadata, PushType, State),
    ApnsId = util_id:new_uuid(),
    ContentId = PushMetadata#push_metadata.content_id,
    Id = PushMessageItem#push_message_item.id,
    Uid = PushMessageItem#push_message_item.uid,
    ContentType = PushMetadata#push_metadata.content_type,
    ?INFO("Uid: ~s, MsgId: ~s, ApnsId: ~s, ContentId: ~s, ContentType: ~s",
        [Uid, Id, ApnsId, ContentId, ContentType]),
    {_Result, FinalState} = send_post_request_to_apns(Uid, ApnsId, ContentId, PayloadBin,
            PushType, EndpointType, PushMessageItem, State),
    FinalState.


-spec add_to_pending_map(ApnsId :: binary(), PushMessageItem :: push_message_item(),
        State :: push_state()) -> push_state().
add_to_pending_map(ApnsId, PushMessageItem, #push_state{pendingMap = PendingMap} = State) ->
    NewPendingMap = PendingMap#{ApnsId => PushMessageItem},
    State#push_state{pendingMap = NewPendingMap}.


-spec retry_message_item(PushMessageItem :: push_message_item()) -> reference().
retry_message_item(PushMessageItem) ->
    RetryTime = PushMessageItem#push_message_item.retry_ms,
    setup_timer({retry, PushMessageItem}, RetryTime).


-spec get_pid_to_send(EndpointType :: endpoint_type(),
        State :: push_state()) -> {pid() | undefined, push_state()}.
get_pid_to_send(prod = EndpointType, #push_state{conn = undefined} = State) ->
    {Pid, Mon} = connect_to_apns(EndpointType),
    {Pid, State#push_state{conn = Pid, mon = Mon}};
get_pid_to_send(prod, State) ->
    {State#push_state.conn, State};
get_pid_to_send(dev = EndpointType, #push_state{dev_conn = undefined} = State) ->
    {DevPid, DevMon} = connect_to_apns(EndpointType),
    {DevPid, State#push_state{dev_conn = DevPid, dev_mon = DevMon}};
get_pid_to_send(dev, State) ->
    {State#push_state.dev_conn, State};
get_pid_to_send(voip_prod = EndpointType, #push_state{voip_conn = undefined} = State) ->
    {VoipPid, VoipMon} = connect_to_apns(EndpointType),
    {VoipPid, State#push_state{voip_conn = VoipPid, voip_mon = VoipMon}};
get_pid_to_send(voip_prod, State) ->
    {State#push_state.voip_conn, State};
get_pid_to_send(voip_dev = EndpointType, #push_state{voip_dev_conn = undefined} = State) ->
    {VoipDevPid, VoipDevMon} = connect_to_apns(EndpointType),
    {VoipDevPid, State#push_state{voip_dev_conn = VoipDevPid, voip_dev_mon = VoipDevMon}};
get_pid_to_send(voip_dev, State) ->
    {State#push_state.voip_dev_conn, State}.


%% Details about the content inside the apns push payload are here:
%% [https://developer.apple.com/documentation/usernotifications/setting_up_a_remote_notification_server/generating_a_remote_notification]
-spec get_payload(PushMessageItem :: push_message_item(), PushMetadata :: push_metadata(),
        PushType :: silent | alert, State :: push_state()) -> binary().
get_payload(PushMessageItem, PushMetadata, PushType, State) ->
    PayloadB64 = case PushMetadata#push_metadata.payload of
        undefined -> <<>>;
        Payload -> base64:encode(Payload)
    end,
    PbMessageB64 = base64:encode(enif_protobuf:encode(PushMessageItem#push_message_item.message)),
    ClientVersion = PushMessageItem#push_message_item.push_info#push_info.client_version,
    EncryptedContent = base64:encode(encrypt_message(PushMessageItem, State)),
    %% TODO(murali@): remove other fields after 6months - 10-01-2021.
    %% accounts depending on this data will be deleted by then.
    MetadataMap = case util_ua:is_version_greater_than(ClientVersion, <<"HalloApp/iOS1.4.111">>) of
        true ->
            EncryptedContentSize = byte_size(EncryptedContent),
            ?INFO("Push contentId: ~p includes encrypted content size: ~p",
                            [PushMetadata#push_metadata.content_id, EncryptedContentSize]),
            case EncryptedContentSize > ?MAX_PUSH_PAYLOAD_SIZE of
                true ->
                    ?WARNING("Push contentId: ~p size: ~p > max_payload_size",
                        [PushMetadata#push_metadata.content_id, EncryptedContentSize]);
                false ->
                    ok
            end,
            #{
                <<"content">> => EncryptedContent
            };
        false ->
            #{
                <<"content-id">> => PushMetadata#push_metadata.content_id,
                <<"content-type">> => PushMetadata#push_metadata.content_type,
                <<"from-id">> => PushMetadata#push_metadata.from_uid,
                <<"timestamp">> => util:to_binary(PushMetadata#push_metadata.timestamp),
                <<"thread-id">> => PushMetadata#push_metadata.thread_id,
                <<"thread-name">> => PushMetadata#push_metadata.thread_name,
                <<"sender-name">> => PushMetadata#push_metadata.sender_name,
                %% Ideally clients should decode the pb message and then use this for metrics.
                %% Easier to have this if we start sending it ourselves - filed an issue for ios.
                <<"message-id">> => PushMessageItem#push_message_item.id,
                <<"data">> => PayloadB64,
                <<"message">> => PbMessageB64,
                <<"retract">> => util:to_binary(PushMetadata#push_metadata.retract)
            }
    end,
    ApsMap = case PushType of
        alert ->
            DataMap = #{
                <<"title">> => PushMetadata#push_metadata.subject,
                <<"body">> => PushMetadata#push_metadata.body
            },
            %% Setting mutable-content flag allows the ios client to modify the push notification.
            #{<<"alert">> => DataMap, <<"sound">> => <<"default">>, <<"mutable-content">> => <<"1">>};
        direct_alert ->
            DataMap = #{
                <<"title">> => PushMetadata#push_metadata.subject,
                <<"body">> => PushMetadata#push_metadata.body
            },
            #{<<"alert">> => DataMap, <<"sound">> => <<"default">>};
        silent ->
            #{<<"content-available">> => <<"1">>}
    end,
    PayloadMap = #{<<"aps">> => ApsMap, <<"metadata">> => MetadataMap},
    jiffy:encode(PayloadMap).


%% Use noise-x pattern to encrypt the message.
%% TODO(murali@): Fetch the static key when we fetch the push token itself.
-spec encrypt_message(PushMessageItem :: push_message_item(), State :: push_state()) -> binary().
encrypt_message(#push_message_item{uid = Uid, message = Message},
        #push_state{noise_static_key = S, noise_certificate = Cert}) ->
    try
        case enif_protobuf:encode(Message) of
            {error, Reason1} ->
                ?ERROR("Failed encoding message: ~p, reason: ~p", [Message, Reason1]),
                <<>>;
            MsgBin ->
                case enif_protobuf:encode(#pb_push_content{certificate = Cert, content = MsgBin}) of
                    {error, Reason2} ->
                        ?ERROR("Failed encoding msg: ~p, cert: ~p, reason: ~p",
                                [Message, Cert, Reason2]),
                        <<>>;
                    PushContent ->
                        case model_auth:get_spub(Uid) of
                            {ok, #s_pub{s_pub = undefined}} ->
                                <<>>;
                            {ok, #s_pub{s_pub = ClientStaticKey}} ->
                                {ok, EncryptedMessage} = ha_enoise:encrypt_x(PushContent,
                                        base64:decode(ClientStaticKey), S),
                                <<"0", EncryptedMessage/binary>>
                        end
                end
        end
    catch
        Class: Reason: St ->
            ?ERROR("Failed encrypting message |~p| with reason: ~s",
                [Message, lager:pr_stacktrace(St, {Class, Reason})]),
        <<>>
    end.


-spec retry_function(Retries :: non_neg_integer(), Opts :: map()) -> map().
retry_function(Retries, Opts) ->
    Timeout = maps:get(retry_timeout, Opts, 5000),
    #{
        retries => Retries - 1,
        timeout => Timeout * ?GOLDEN_RATIO
    }.

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

-spec get_apns_gateway(EndpointType :: endpoint_type()) -> list().
get_apns_gateway(prod) -> ?APNS_GATEWAY;
get_apns_gateway(dev) -> ?APNS_DEV_GATEWAY;
get_apns_gateway(voip_prod) -> ?APNS_GATEWAY;
get_apns_gateway(voip_dev) -> ?APNS_DEV_GATEWAY.


-spec get_apns_secret_name(EndpointType :: endpoint_type()) -> binary().
get_apns_secret_name(prod) -> ?APNS_CERTFILE_SM;
get_apns_secret_name(dev) -> ?APNS_DEV_CERTFILE_SM;
get_apns_secret_name(voip_prod) -> ?APNS_VOIP_CERTFILE_SM;
get_apns_secret_name(voip_dev) -> ?APNS_VOIP_CERTFILE_SM.


-spec get_apns_cert(EndpointType :: endpoint_type()) -> tuple().
get_apns_cert(EndpointType) ->
    SecretName = get_apns_secret_name(EndpointType),
    Secret = mod_aws:get_secret(SecretName),
    Arr = public_key:pem_decode(Secret),
    [{_, CertBin, _}, {Asn1Type, KeyBin, _}] = Arr,
    Key = {Asn1Type, KeyBin},
    {CertBin, Key}.

-spec get_apns_port(EndpointType :: endpoint_type()) -> integer().
get_apns_port(prod) -> ?APNS_PORT;
get_apns_port(dev) -> ?APNS_DEV_PORT;
get_apns_port(voip_prod) -> ?APNS_PORT;
get_apns_port(voip_dev) -> ?APNS_DEV_PORT.


-spec get_bundle_id(EndpointType :: endpoint_type()) -> binary().
get_bundle_id(prod) -> ?APP_BUNDLE_ID;
get_bundle_id(dev) -> ?APP_BUNDLE_ID;
get_bundle_id(voip_prod) -> ?APP_VOIP_BUNDLE_ID;
get_bundle_id(voip_dev) -> ?APP_VOIP_BUNDLE_ID.


-spec get_priority(EndpointType :: endpoint_type(), PushType :: silent | alert) -> integer().
get_priority(voip_prod, _) -> 10;
get_priority(voip_dev, _) -> 10;
get_priority(_, silent) -> 5;
get_priority(_, alert) -> 10;
get_priority(_, direct_alert) -> 10.


-spec get_apns_push_type(EndpointType :: endpoint_type(), PushType :: silent | alert) -> binary().
get_apns_push_type(voip_prod, _) -> <<"voip">>;
get_apns_push_type(voip_dev, _) -> <<"voip">>;
get_apns_push_type(_, silent) -> <<"background">>;
get_apns_push_type(_, alert) -> <<"alert">>;
get_apns_push_type(_, direct_alert) -> <<"alert">>.


-spec get_device_path(EndpointType :: endpoint_type(), PushInfo :: push_info()) -> binary().
get_device_path(EndpointType, PushInfo) ->
    DeviceToken = case EndpointType of
        voip_prod -> PushInfo#push_info.voip_token;
        voip_dev -> PushInfo#push_info.voip_token;
        _ -> PushInfo#push_info.token
    end,
    <<"/3/device/", DeviceToken/binary>>.


-spec get_expiry_time(EndpointType :: endpoint_type(), PushMessageItem :: push_message_item()) -> integer().
get_expiry_time(EndpointType, PushMessageItem) ->
    case EndpointType of
        voip_prod -> 0;
        voip_dev -> 0;
        _ -> PushMessageItem#push_message_item.timestamp + ?MESSAGE_EXPIRY_TIME_SEC
    end.


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
        timestamp = util:now(),
        retry_ms = ?RETRY_INTERVAL_MILLISEC,
        push_info = PushInfo,
        push_type = PushType
    },
    send_post_request_to_apns(Uid, ApnsId, ContentId, PayloadBin,
            PushType, EndpointType, PushMessageItem, State).


-spec send_post_request_to_apns(Uid :: binary(), ApnsId :: binary(), ContentId :: binary(), PayloadBin :: binary(),
        PushType :: alert | silent, EndpointType :: endpoint_type(), PushMessageItem :: push_message_item(),
        State :: push_state()) -> {ok, push_state()} | {ignored, push_state()} | {{error, any()}, push_state()}.
send_post_request_to_apns(Uid, ApnsId, ContentId, PayloadBin, PushType, EndpointType, PushMessageItem, State) ->
    IsDev = dev_users:is_dev_uid(Uid),
    case IsDev =:= true andalso PushType =:= silent of
        true ->
            ?INFO("Ignoring silent push, DevUid: ~s ApnsId: ~s ContentId: ~s", [Uid, ApnsId, ContentId]),
            {ok, State};
        false -> send_post_request_to_apns_internal(Uid, ApnsId, ContentId,
                PayloadBin, PushType, EndpointType, PushMessageItem, State)
    end.

send_post_request_to_apns_internal(Uid, ApnsId, ContentId, PayloadBin, PushType, EndpointType, PushMessageItem, State) ->
    Priority = get_priority(EndpointType, PushType),
    DevicePath = get_device_path(EndpointType, PushMessageItem#push_message_item.push_info),
    ExpiryTime = get_expiry_time(EndpointType, PushMessageItem),
    HeadersList = [
        {?APNS_ID, ApnsId},
        {?APNS_PRIORITY, integer_to_binary(Priority)},
        {?APNS_EXPIRY, integer_to_binary(ExpiryTime)},
        {?APNS_TOPIC, get_bundle_id(EndpointType)},
        {?APNS_PUSH_TYPE, get_apns_push_type(EndpointType, PushType)},
        {?APNS_COLLAPSE_ID, ContentId}
    ],
    ?INFO("Uid: ~s, ApnsId: ~s, ContentId: ~s", [Uid, ApnsId, ContentId]),
    case get_pid_to_send(EndpointType, State) of
        {undefined, NewState} ->
            ?ERROR("error: invalid_pid to send this push, Uid: ~p, ApnsId: ~p", [Uid, ApnsId]),
            {{error, cannot_connect}, NewState};
        {Pid, NewState} ->
            ?DEBUG("Post Request Pid: ~p, DevicePath: ~p, HeadersList: ~p, PayloadBin: ~p",
                [Pid, DevicePath, HeadersList, PayloadBin]),
            _StreamRef = gun:post(Pid, DevicePath, HeadersList, PayloadBin),
            FinalState = add_to_pending_map(ApnsId, PushMessageItem, NewState),
            {ok, FinalState}
    end.

