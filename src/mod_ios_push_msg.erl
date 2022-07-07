%%%----------------------------------------------------------------------
%%% File    : mod_ios_push_msg.erl
%%%
%%% Copyright (C) 2022 HalloApp inc.
%%%
%%% Supplement to mod_ios_push. Helps send a push notification
%%%----------------------------------------------------------------------

-module(mod_ios_push_msg).

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

%% gen_mod API
-export([start/2, stop/1, reload/3, depends/2, mod_options/1]).
%% gen_server API
-export([init/1, terminate/2, handle_call/3, handle_cast/2, handle_info/2]).

%% API
-export([
    push_message/2,
    push_message/3,
    send_post_request_to_apns/9
]).


-spec push_message(PushMessageItem :: push_message_item(), ParentPid :: pid()) -> ok.
push_message(PushMessageItem, ParentPid) ->
    gen_server:cast(?PROC(), {push_message_item, PushMessageItem, ParentPid}),
    ok.


-spec push_message(PushMessageItem :: push_message_item(),
    PushMetadata:: push_metadata(), ParentPid :: pid()) -> ok.
push_message(PushMessageItem, PushMetadata, ParentPid) ->
    gen_server:cast(?PROC(), {push_message_item, PushMessageItem, PushMetadata, ParentPid}),
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
    gen_mod:stop_child(?PROC()),
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
    {Pid, Mon} = connect_to_apns(prod),
    {DevPid, DevMon} = connect_to_apns(dev),
    {VoipPid, VoipMon} = connect_to_apns(voip_prod),
    {VoipDevPid, VoipDevMon} = connect_to_apns(voip_dev),
    %% TODO: Move all voip push logic to its own gen_server.
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
            voip_dev_mon = VoipDevMon}}.


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
handle_cast({push_message_item, PushMessageItem, PushMetadata, ParentPid}, State) ->
    NewState = push_message_item(PushMessageItem, PushMetadata, State, ParentPid),
    {noreply, NewState};
handle_cast(Request, State) ->
    ?DEBUG("unknown request: ~p", [Request]),
    {noreply, State}.


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


handle_info(Request, State) ->
    ?DEBUG("unknown request: ~p", [Request]),
    {noreply, State}.



%%====================================================================
%% internal module functions
%%====================================================================


-spec push_message_item(PushMessageItem :: push_message_item(),
        State :: push_state(), ParentPid :: pid()) -> push_state().
push_message_item(PushMessageItem, State, ParentPid) ->
    PushMetadata = push_util:parse_metadata(PushMessageItem#push_message_item.message),
    NewPushMessageItem = PushMessageItem#push_message_item{
            push_type = PushMetadata#push_metadata.push_type,
            content_type = PushMetadata#push_metadata.content_type},
    push_message_item(NewPushMessageItem, PushMetadata, State, ParentPid).


-spec push_message_item(PushMessageItem :: push_message_item(), PushMetadata :: push_metadata(),
        State :: push_state(), ParentPid :: pid()) -> push_state().
push_message_item(PushMessageItem, PushMetadata, State, ParentPid) ->
    Message = PushMessageItem#push_message_item.message,
    Os = PushMessageItem#push_message_item.push_info#push_info.os,
    ContentId = PushMetadata#push_metadata.content_id,
    Id = PushMessageItem#push_message_item.id,
    Uid = PushMessageItem#push_message_item.uid,
    ContentType = PushMetadata#push_metadata.content_type,
    ApnsId = PushMessageItem#push_message_item.apns_id,
    EndpointType = case {util:is_voip_incoming_message(Message), Os} of
        {true, <<"ios">>} -> voip_prod;
        {true, <<"ios_dev">>} -> voip_dev;
        {false, <<"ios">>} -> prod;
        {false, <<"ios_dev">>} -> dev
    end,
    PushType = PushMetadata#push_metadata.push_type,
    PayloadBin = get_payload(PushMessageItem, PushMetadata, PushType, State),
    ?INFO("Uid: ~s, MsgId: ~s, ApnsId: ~s, ContentId: ~s, ContentType: ~s",
        [Uid, Id, ApnsId, ContentId, ContentType]),
    {_Result, FinalState} = send_post_request_to_apns(Uid, ApnsId, ContentId, PayloadBin,
            PushType, EndpointType, PushMessageItem, State, ParentPid),
    FinalState.


%% Details about the content inside the apns push payload are here:
%% [https://developer.apple.com/documentation/usernotifications/setting_up_a_remote_notification_server/generating_a_remote_notification]
-spec get_payload(PushMessageItem :: push_message_item(), PushMetadata :: push_metadata(),
        PushType :: alertType(), State :: push_state()) -> binary().
get_payload(PushMessageItem, PushMetadata, PushType, State) ->
    Message = PushMessageItem#push_message_item.message,
    EncryptedContent = base64:encode(encrypt_message(PushMessageItem, State)),
    EncryptedContentSize = byte_size(EncryptedContent),
    ?INFO("Push contentId: ~p includes encrypted content size: ~p",
        [PushMetadata#push_metadata.content_id, EncryptedContentSize]),
    EncryptedContent2 = case EncryptedContentSize > ?MAX_PUSH_PAYLOAD_SIZE of
        true ->
            ?INFO("Push contentId: ~p size: ~p > max_payload_size, message: ~p",
                [PushMetadata#push_metadata.content_id, EncryptedContentSize, Message]),
            <<>>;
        false ->
            EncryptedContent
    end,
    MetadataMap = #{ <<"content">> => EncryptedContent2 },
    ApsMap = case PushType of
        alert ->
            %% Setting mutable-content flag allows the ios client to modify the push notification.
            #{<<"alert">> => #{}, <<"mutable-content">> => <<"1">>};
        direct_alert ->
            % Used only in marketing alerts
            {Title, Body} = push_util:get_title_body(Message, PushMessageItem#push_message_item.push_info),
            DataMap = #{
                <<"title">> => Title,
                <<"body">> => Body
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
encrypt_message(#push_message_item{uid = Uid, message = Message}, PushState) ->
    try
        case enif_protobuf:encode(Message) of
            {error, Reason1} ->
                ?ERROR("Failed encoding message: ~p, reason: ~p", [Message, Reason1]),
                <<>>;
            MsgBin when byte_size(MsgBin) < ?MAX_PUSH_PAYLOAD_SIZE ->
                encrypt_message_bin(Uid, MsgBin, PushState);
            MsgBin ->
                case util:is_voip_incoming_message(Message) of
                    false ->
                        ?INFO("Failed encrypting message |~p| too large, size: ~p",
                            [Message, byte_size(MsgBin)]),
                        <<>>;
                    true ->
                        transform_and_encrypt_message(Uid, Message, PushState)
                end
        end
    catch
        Class: Reason: St ->
            ?ERROR("Failed encrypting message |~p| with reason: ~s",
                [Message, lager:pr_stacktrace(St, {Class, Reason})]),
        <<>>
    end.


-spec transform_and_encrypt_message(Uid :: uid(), Msg :: pb_msg(), PushState :: push_state()) -> binary().
transform_and_encrypt_message(Uid, #pb_msg{payload = #pb_incoming_call{} = IncomingCall} = Message, PushState) ->
    IncomingCallPush = #pb_incoming_call_push{
        call_id = IncomingCall#pb_incoming_call.call_id,
        call_type = IncomingCall#pb_incoming_call.call_type,
        stun_servers = IncomingCall#pb_incoming_call.stun_servers,
        turn_servers = IncomingCall#pb_incoming_call.turn_servers,
        timestamp_ms = IncomingCall#pb_incoming_call.timestamp_ms,
        call_config = IncomingCall#pb_incoming_call.call_config,
        call_capabilities = IncomingCall#pb_incoming_call.call_capabilities
    },
    Message2 = Message#pb_msg{payload = IncomingCallPush},
    case enif_protobuf:encode(Message2) of
        {error, Reason1} ->
            ?ERROR("Failed encoding message: ~p, reason: ~p", [Message2, Reason1]),
            <<>>;
        MsgBin ->
            encrypt_message_bin(Uid, MsgBin, PushState)
    end.


-spec encrypt_message_bin(Uid :: uid(), MsgBin :: binary(), PushState :: push_state()) -> binary().
encrypt_message_bin(Uid, MsgBin, #push_state{noise_static_key = S, noise_certificate = Cert}) ->
    case enif_protobuf:encode(#pb_push_content{certificate = Cert, content = MsgBin}) of
        {error, Reason2} ->
            ?ERROR("Failed encoding msgbin: ~p, cert: ~p, reason: ~p",
                    [MsgBin, Cert, Reason2]),
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
    end.


-spec send_post_request_to_apns(Uid :: binary(), ApnsId :: binary(), ContentId :: binary(), PayloadBin :: binary(),
        PushType :: alertType(), EndpointType :: endpoint_type(), PushMessageItem :: push_message_item(),
        State :: push_state(), ParentPid :: pid()) -> {ok, push_state()} | {ignored, push_state()} | {{error, any()}, push_state()}.
send_post_request_to_apns(Uid, ApnsId, ContentId, PayloadBin, PushType, EndpointType, PushMessageItem, State, ParentPid) ->
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
            _StreamRef = gun:post(Pid, DevicePath, HeadersList, PayloadBin, #{reply_to => ParentPid}),
            {ok, NewState}
    end.


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

-spec get_bundle_id(EndpointType :: endpoint_type()) -> binary().
get_bundle_id(prod) -> ?APP_BUNDLE_ID;
get_bundle_id(dev) -> ?APP_BUNDLE_ID;
get_bundle_id(voip_prod) -> ?APP_VOIP_BUNDLE_ID;
get_bundle_id(voip_dev) -> ?APP_VOIP_BUNDLE_ID.


-spec get_priority(EndpointType :: endpoint_type(), PushType :: alertType()) -> integer().
get_priority(voip_prod, _) -> 10;
get_priority(voip_dev, _) -> 10;
get_priority(_, silent) -> 5;
get_priority(_, alert) -> 10;
get_priority(_, direct_alert) -> 10.


-spec get_apns_push_type(EndpointType :: endpoint_type(), PushType :: alertType()) -> binary().
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


-spec retry_function(Retries :: non_neg_integer(), Opts :: map()) -> map().
retry_function(Retries, Opts) ->
    Timeout = maps:get(retry_timeout, Opts, 5000),
    #{
        retries => Retries - 1,
        timeout => Timeout * ?GOLDEN_RATIO
    }.
