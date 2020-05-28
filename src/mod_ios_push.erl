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
-include("xmpp.hrl").
-include("translate.hrl").
-include ("push_message.hrl").

-type build_type() :: prod | dev.

%% TODO(murali@): convert everything to 1 timeunit.
%% TODO(murali@): move basic timeunits to one header and use it to calculate.
-define(MESSAGE_EXPIRY_TIME_SEC, 86400).           %% seconds in 1 day.
-define(RETRY_INTERVAL_MILLISEC, 30000).           %% 30 seconds.
-define(MESSAGE_MAX_RETRY_TIME_SEC, 600).          %% 10 minutes.

-define(APNS_ID, <<"apns-id">>).
-define(APNS_PRIORITY, <<"apns-priority">>).
-define(APNS_EXPIRY, <<"apns-expiration">>).
-define(APNS_PUSH_TYPE, <<"apns-push-type">>).

%% gen_mod API
-export([start/2, stop/1, reload/3, depends/2, mod_opt_type/1, mod_options/1]).
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
    [].

reload(_Host, _NewOpts, _OldOpts) ->
    ok.

-spec mod_opt_type(atom()) -> econf:validator().
mod_opt_type(apns) ->
    econf:map(
      econf:atom(),
      econf:either(
      econf:binary(),
      econf:int()),
      [unique]).

mod_options(_Host) ->
    [{apns, []}].


get_proc() ->
    gen_mod:get_module_proc(global, ?MODULE).


%%====================================================================
%% API
%%====================================================================

-spec push(Message :: message(), PushInfo :: push_info()) -> ok.
push(Message, #push_info{os = Os} = PushInfo)
        when Os =:= <<"ios">>; Os =:= <<"ios_dev">> ->
    gen_server:cast(get_proc(), {push_message, Message, PushInfo});
push(_Message, _PushInfo) ->
    ?ERROR_MSG("Invalid push_info : ~p", [_PushInfo]).


%%====================================================================
%% gen_server callbacks
%%====================================================================

init([Host|_]) ->
    process_flag(trap_exit, true),
    Opts = gen_mod:get_module_opts(Host, ?MODULE),
    store_options(Opts),
    {Pid, Mon} = connect_to_apns(prod),
    {DevPid, DevMon} = connect_to_apns(dev),
    {ok, #push_state{
            pendingMap = #{},
            host = Host,
            conn = Pid,
            mon = Mon,
            dev_conn = DevPid,
            dev_mon = DevMon}}.


terminate(_Reason, #push_state{host = _Host, conn = Pid,
        mon = Mon, dev_conn = DevPid, dev_mon = DevMon}) ->
    demonitor(Mon),
    gun:close(Pid),
    demonitor(DevMon),
    gun:close(DevPid),
    ok.


code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


handle_call(_Request, _From, State) ->
    ?ERROR_MSG("invalid call request: ~p", [_Request]),
    {reply, {error, invalid_request}, State}.


handle_cast({push_message, Message, PushInfo} = _Request, State) ->
    ?DEBUG("push_message: ~p", [Message]),
    NewState = push_message(Message, PushInfo, State),
    {noreply, NewState};
handle_cast(_Request, State) ->
    ?DEBUG("Invalid request, ignoring it: ~p", [_Request]),
    {noreply, State}.


-spec connect_to_apns(BuildType :: build_type()) -> {pid(), reference()} | {undefined, undefined}.
connect_to_apns(BuildType) ->
    ApnsGateway = get_apns_gateway(BuildType),
    ApnsCertfile = get_apns_certfile(BuildType),
    ApnsPort = get_apns_port(BuildType),
    RetryFun = fun retry_function/2,
    Options = #{
        protocols => [http2],
        tls_opts => [{certfile, ApnsCertfile}],
        retry => 5,                         %% gun will retry connecting 5 times before giving up!
        retry_timeout => 5000,              %% Time between retries in milliseconds.
        retry_fun => RetryFun
    },
    ?INFO_MSG("BuildType: ~s, Gateway: ~s, Port: ~p", [BuildType, ApnsGateway, ApnsPort]),
    case gun:open(ApnsGateway, ApnsPort, Options) of
        {ok, Pid} ->
            Mon = monitor(process, Pid),
            {ok, Protocol} = gun:await_up(Pid, Mon),
            ?INFO_MSG("BuildType: ~s, connection successful pid: ~p, protocol: ~p, monitor: ~p",
                    [BuildType, Pid, Protocol, Mon]),
            {Pid, Mon};
        {error, Reason} ->
            ?ERROR_MSG("BuildType: ~s, Failed to connect to apns: ~p", [BuildType, Reason]),
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
            ?INFO_MSG("Uid: ~s push failed, no more retries msg_id: ~s", [Uid, Id]),
            State;
        true ->
            ?INFO_MSG("Uid: ~s, retry push_message_item: ~p", [Uid, Id]),
            NewRetryMs = round(PushMessageItem#push_message_item.retry_ms * ?GOLDEN_RATIO),
            NewPushMessageItem = PushMessageItem#push_message_item{retry_ms = NewRetryMs},
            push_message_item(NewPushMessageItem, State)
    end,
    {noreply, NewState};

handle_info({'DOWN', Mon, process, Pid, Reason},
        #push_state{conn = Pid, mon = Mon} = State) ->
    ?INFO_MSG("prod gun_down pid: ~p, mon: ~p, reason: ~p", [Pid, Mon, Reason]),
    {NewPid, NewMon} = connect_to_apns(prod),
    {noreply, State#push_state{conn = NewPid, mon = NewMon}};

handle_info({'DOWN', DevMon, process, DevPid, Reason},
        #push_state{dev_conn = DevPid, mon = DevMon} = State) ->
    ?INFO_MSG("dev gun_down pid: ~p, mon: ~p, reason: ~p", [DevPid, DevMon, Reason]),
    {NewDevPid, NewDevMon} = connect_to_apns(dev),
    {noreply, State#push_state{dev_conn = NewDevPid, dev_mon = NewDevMon}};

handle_info({'DOWN', _Mon, process, Pid, Reason}, State) ->
    ?ERROR_MSG("down message from gun pid: ~p, reason: ~p, state: ~p", [Pid, Reason, State]),
    {noreply, State};

handle_info({gun_response, ConnPid, StreamRef, fin, StatusCode, Headers}, State) ->
    ?DEBUG("gun_response: conn_pid: ~p, streamref: ~p, status: ~p, headers: ~p",
            [ConnPid, StreamRef, StatusCode, Headers]),
    ApnsId = proplists:get_value(?APNS_ID, Headers, undefined),
    NewState = handle_apns_response(StatusCode, ApnsId, State),
    {noreply, NewState};

handle_info(Request, State) ->
    ?DEBUG("unknown request: ~p, state: ~p", [Request, State]),
    {noreply, State}.



-spec handle_apns_response(StatusCode :: integer(), ApnsId :: binary() | undefined,
        State :: push_state()) -> push_state().
handle_apns_response(_, undefined, State) ->
    %% This should never happen, since apns always responds with the apns-id.
    ?ERROR_MSG("unexpected response from apns!!", []),
    State;
handle_apns_response(200, ApnsId, #push_state{pendingMap = PendingMap} = State) ->
    FinalPendingMap = case maps:take(ApnsId, PendingMap) of
        error ->
            ?ERROR_MSG("Message not found in our map: apns-id: ~p", [ApnsId]),
            PendingMap;
        {PushMessageItem, NewPendingMap} ->
            Id = PushMessageItem#push_message_item.id,
            Uid = PushMessageItem#push_message_item.uid,
            ?INFO_MSG("Uid: ~s, apns push successful: msg_id: ~s", [Uid, Id]),
            NewPendingMap
    end,
    State#push_state{pendingMap = FinalPendingMap};

handle_apns_response(StatusCode, ApnsId, #push_state{pendingMap = PendingMap} = State)
        when StatusCode =:= 429; StatusCode >= 500 ->
    FinalPendingMap = case maps:take(ApnsId, PendingMap) of
        error ->
            ?ERROR_MSG("Message not found in our map: apns-id: ~p", [ApnsId]),
            State;
        {PushMessageItem, NewPendingMap} ->
            Id = PushMessageItem#push_message_item.id,
            Uid = PushMessageItem#push_message_item.uid,
            ?WARNING_MSG("Uid: ~s, apns push error: msg_id: ~s, will retry", [Uid, Id]),
            retry_message_item(PushMessageItem),
            NewPendingMap
    end,
    State#push_state{pendingMap = FinalPendingMap};

handle_apns_response(StatusCode, ApnsId, #push_state{pendingMap = PendingMap} = State)
        when StatusCode >= 400; StatusCode < 500 ->
    FinalPendingMap = case maps:take(ApnsId, PendingMap) of
        error ->
            ?ERROR_MSG("Message not found in our map: apns-id: ~p", [ApnsId]),
            State;
        {PushMessageItem, NewPendingMap} ->
            Id = PushMessageItem#push_message_item.id,
            Uid = PushMessageItem#push_message_item.uid,
            ?ERROR_MSG("Uid: ~s, apns push error: msg_id: ~s, needs to be fixed!", [Uid, Id]),
            NewPendingMap
    end,
    State#push_state{pendingMap = FinalPendingMap};

handle_apns_response(StatusCode, ApnsId, State) ->
    ?ERROR_MSG("Invalid status code : ~p, from apns, apns-id: ~p", [StatusCode, ApnsId]),
    State.




%%====================================================================
%% internal module functions
%%====================================================================

%% TODO(murali@): Figure out a way to better use the message-id.
-spec push_message(Message :: message(), PushInfo :: push_info(),
        State :: push_state()) -> push_state().
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

-spec push_message_item(PushMessageItem :: push_message_item(),
        State :: push_state()) -> push_state().
push_message_item(PushMessageItem, State) ->
    BuildType = case PushMessageItem#push_message_item.push_info#push_info.os of
        <<"ios">> -> prod;
        <<"ios_dev">> -> dev
    end,
    Token = PushMessageItem#push_message_item.push_info#push_info.token,
    ExpiryTime = PushMessageItem#push_message_item.timestamp + ?MESSAGE_EXPIRY_TIME_SEC,
    PushType = get_push_type(PushMessageItem#push_message_item.message),
    PayloadBin = get_payload(PushMessageItem, PushType),
    Priority = get_priority(PushType),
    DevicePath = get_device_path(Token),
    ApnsId = util:uuid_binary(),
    HeadersList = [
        {?APNS_ID, ApnsId},
        {?APNS_PRIORITY, integer_to_binary(Priority)},
        {?APNS_EXPIRY, integer_to_binary(ExpiryTime)},
        {?APNS_PUSH_TYPE, get_apns_push_type(PushType)}
    ],

    {Pid, NewState} = get_pid_to_send(BuildType, State),
    _StreamRef = gun:post(Pid, DevicePath, HeadersList, PayloadBin),
    FinalState = add_to_pending_map(ApnsId, PushMessageItem, NewState),
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


-spec get_pid_to_send(BuildType :: build_type(),
        State :: push_state()) -> {pid() | undefined, push_state()}.
get_pid_to_send(prod = BuildType, #push_state{conn = undefined} = State) ->
    {Pid, Mon} = connect_to_apns(BuildType),
    {Pid, State#push_state{conn = Pid, mon = Mon}};
get_pid_to_send(prod, State) ->
    {State#push_state.conn, State};
get_pid_to_send(dev = BuildType, #push_state{dev_conn = undefined} = State) ->
    {DevPid, DevMon} = connect_to_apns(BuildType),
    {DevPid, State#push_state{dev_conn = DevPid, dev_mon = DevMon}};
get_pid_to_send(dev, State) ->
    {State#push_state.dev_conn, State}.


-spec parse_message(Message :: message()) -> {binary(), binary()}.
parse_message(#message{sub_els = [SubElement]}) when is_record(SubElement, chat) ->
    {<<"New Message">>, <<"You got a new message.">>};
parse_message(#message{sub_els = [#ps_event{items = #ps_items{
        items = [#ps_item{type = ItemType}]}}]}) ->
    case ItemType of
        comment -> {<<"New Notification">>, <<"New comment">>};
        feedpost -> {<<"New Notification">>, <<"New feedpost">>};
        _ -> {<<"New Message">>, <<"You got a new message.">>}
    end;
parse_message(#message{to = #jid{luser = Uid}, id = Id}) ->
    ?ERROR_MSG("Uid: ~s, Invalid message for push notification: id: ~s", [Uid, Id]).


-spec parse_metadata(Message :: message()) -> {binary(), binary(), binary()}.
parse_metadata(#message{id = Id, sub_els = [SubElement],
        from = #jid{luser = FromUid}}) when is_record(SubElement, chat) ->
    {Id, <<"chat">>, FromUid};
parse_metadata(#message{sub_els = [#ps_event{items = #ps_items{
        items = [#ps_item{id = Id, publisher = FromId, type = ItemType}]}}]}) ->
%% TODO(murali@): Change the fromId to be just userid instead of jid.
    {Id, util:to_binary(ItemType), FromId};
parse_metadata(#message{to = #jid{luser = Uid}, id = Id}) ->
    ?ERROR_MSG("Uid: ~s, Invalid message for push notification: id: ~s", [Uid, Id]),
    {<<>>, <<>>, <<>>}.


-spec get_payload(PushMessageItem :: push_message_item(), PushType :: silent | alert) -> binary().
get_payload(PushMessageItem, PushType) ->
    {ContentId, ContentType, FromId} = parse_metadata(PushMessageItem#push_message_item.message),
    MetadataMap = #{
        <<"content-id">> => ContentId,
        <<"content-type">> => ContentType,
        <<"from-id">> => FromId
    },
    BuildTypeMap = case PushType of
        alert ->
            {Subject, Body} = parse_message(PushMessageItem#push_message_item.message),
            DataMap = #{<<"title">> => Subject, <<"body">> => Body},
            #{<<"alert">> => DataMap, <<"sound">> => <<"default">>};
        silent ->
            #{}
    end,
    ApsMap = BuildTypeMap#{<<"content-available">> => <<"1">>},
    PayloadMap = #{<<"aps">> => ApsMap, <<"metadata">> => MetadataMap},
    jiffy:encode(PayloadMap).


-spec get_priority(PushType :: silent | alert) -> integer().
get_priority(silent) -> 5;
get_priority(alert) -> 10.


-spec get_push_type(Message :: message()) -> silent | alert.
get_push_type(#message{type = headline}) -> silent;
get_push_type(_) -> alert.


-spec get_apns_push_type(PushType :: silent | alert) -> binary().
get_apns_push_type(silent) -> <<"background">>;
get_apns_push_type(alert) -> <<"alert">>.

-spec get_device_path(DeviceId :: binary()) -> binary().
get_device_path(DeviceId) ->
  <<"/3/device/", DeviceId/binary>>.


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

%% TODO(murali@): Persistent terms are super expensive. Update this to use ets table!
store_options(Opts) ->
    ApnsOptions = mod_push_notifications_opt:apns(Opts),

    %% Store APNS Gateway and APIkey as strings.
    ApnsGateway = proplists:get_value(gateway, ApnsOptions),
    persistent_term:put({?MODULE, apns_gateway}, binary_to_list(ApnsGateway)),
    ApnsCertfile = proplists:get_value(certfile, ApnsOptions),
    persistent_term:put({?MODULE, apns_certfile}, binary_to_list(ApnsCertfile)),
    %% Store APNS port as int.
    ApnsPort = proplists:get_value(port, ApnsOptions),
    persistent_term:put({?MODULE, apns_port}, ApnsPort),

    %% Store APNS DevGateway and API Devkey as strings.
    ApnsDevGateway = proplists:get_value(dev_gateway, ApnsOptions),
    persistent_term:put({?MODULE, apns_dev_gateway}, binary_to_list(ApnsDevGateway)),
    ApnsDevCertfile = proplists:get_value(dev_certfile, ApnsOptions),
    persistent_term:put({?MODULE, apns_dev_certfile}, binary_to_list(ApnsDevCertfile)),
    %% Store APNS Devport as int.
    ApnsDevPort = proplists:get_value(dev_port, ApnsOptions),
    persistent_term:put({?MODULE, apns_dev_port}, ApnsDevPort).


-spec get_apns_gateway(BuildType :: build_type()) -> list().
get_apns_gateway(prod) ->
    persistent_term:get({?MODULE, apns_gateway});
get_apns_gateway(dev) ->
    persistent_term:get({?MODULE, apns_dev_gateway}).


-spec get_apns_certfile(BuildType :: build_type()) -> list().
get_apns_certfile(prod) ->
    persistent_term:get({?MODULE, apns_certfile});
get_apns_certfile(dev) ->
    persistent_term:get({?MODULE, apns_dev_certfile}).


-spec get_apns_port(BuildType :: build_type()) -> integer().
get_apns_port(prod) ->
    persistent_term:get({?MODULE, apns_port});
get_apns_port(dev) ->
    persistent_term:get({?MODULE, apns_dev_port}).

