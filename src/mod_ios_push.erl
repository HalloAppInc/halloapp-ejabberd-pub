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
-define(SSL_TIMEOUT_MILLISEC, 10000).              %% 10 seconds.
-define(MESSAGE_EXPIRY_TIME_SEC, 86400).           %% 1 day.
-define(MESSAGE_RESPONSE_TIMEOUT_SEC, 60).         %% 1 minute.
-define(STATE_CLEANUP_TIMEOUT_MILLISEC, 120000).   %% 2 minutes.
-define(MESSAGE_MAX_RETRY_TIME_SEC, 600).          %% 10 minutes.
-define(RETRY_INTERVAL_MILLISEC, 30000).           %% 30 seconds.

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
    Socket = connect_to_apns(prod),
    DevSocket = connect_to_apns(dev),
    {ok, #push_state{pendingList = [], host = Host, socket = Socket, dev_socket = DevSocket}}.


terminate(_Reason, #push_state{host = _Host, socket = Socket, dev_socket = DevSocket}) ->
    close_socket(Socket),
    close_socket(DevSocket),
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


-spec close_socket(Socket :: undefined | sslsocket()) -> ok | {error, any()}.
close_socket(undefined) ->
    ok;
close_socket(Socket) ->
    ssl:close(Socket).


-spec connect_to_apns(BuildType :: build_type()) -> sslsocket() | undefined.
connect_to_apns(BuildType) ->
    ApnsGateway = get_apns_gateway(BuildType),
    ApnsCertfile = get_apns_certfile(BuildType),
    ApnsPort = get_apns_port(BuildType),
    Options = [{certfile, ApnsCertfile}, {mode, binary}],
    ?INFO_MSG("BuildType: ~s, Gateway: ~s, Port: ~p", [BuildType, ApnsGateway, ApnsPort]),
    case ssl:connect(ApnsGateway, ApnsPort, Options, ?SSL_TIMEOUT_MILLISEC) of
        {ok, Socket} ->
            ?INFO_MSG("BuildType: ~s, connection successful: ~p", [BuildType, Socket]),
            Socket;
        {error, Reason} ->
            ?ERROR_MSG("BuildType: ~s, Failed to connect to apns: ~p", [BuildType, Reason]),
            undefined
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

handle_info({ssl, Socket, Data}, State) ->
    ?INFO_MSG("ssl: socket: ~p, message: ~p", [Socket, Data]),
    try
        <<RCommand:1/unit:8, RStatus:1/unit:8, RId:4/unit:8>> = iolist_to_binary(Data),
        {RCommand, RStatus, RId}
    of
        {8, Status, Id} ->
            ?ERROR_MSG("Failed sending push for with id: ~s, status: ~s", [Id, Status]),
            NewState = handle_apns_response(Status, Id, State),
            {noreply, NewState};
        _ ->
            ?ERROR_MSG("invalid APNS response", []),
            {noreply, State}
    catch
        {'EXIT', _} ->
            ?ERROR_MSG("invalid APNS response", []),
            {noreply, State}
    end;

handle_info({ssl_closed, Socket}, #push_state{socket = Socket} = State) ->
    ?INFO_MSG("prod: ssl_closed: ~p", [Socket]),
    NewSocket = connect_to_apns(prod),
    {noreply, State#push_state{socket = NewSocket}};

handle_info({ssl_closed, DevSocket}, #push_state{dev_socket = DevSocket} = State) ->
    ?INFO_MSG("dev: ssl_closed: ~p", [DevSocket]),
    NewDevSocket = connect_to_apns(dev),
    {noreply, State#push_state{dev_socket = NewDevSocket}};

handle_info({ssl_error, Socket, Reason}, #push_state{socket = Socket} = State) ->
    ?INFO_MSG("prod: ssl_error: ~p, reason: ~p", [Socket, Reason]),
    NewSocket = connect_to_apns(prod),
    {noreply, State#push_state{socket = NewSocket}};

handle_info({ssl_error, DevSocket, Reason}, #push_state{dev_socket = DevSocket} = State) ->
    ?INFO_MSG("dev: ssl_error: ~p, reason: ~p", [DevSocket, Reason]),
    NewDevSocket = connect_to_apns(dev),
    {noreply, State#push_state{dev_socket = NewDevSocket}};

handle_info({ssl_passive, Socket}, State) ->
    ?ERROR_MSG("unexpected ssl_passive message: ~p, state: ~p", [Socket, State]),
    {noreply, State};

handle_info({clean_up_state}, State) ->
    OldPendingList = State#push_state.pendingList,
    ?INFO_MSG("clean_up_state, pending messages: ~p", [length(OldPendingList)]),
    CurTimestamp = util:now(),
    NewPendingList = lists:dropwhile(
            fun(PushMessageItem) ->
                ThenTimestamp = PushMessageItem#push_message_item.timestamp,
                CurTimestamp - ThenTimestamp  >= ?MESSAGE_RESPONSE_TIMEOUT_SEC
            end, OldPendingList),
    NewState = State#push_state{pendingList = NewPendingList},
    case length(NewPendingList) > 0 of
        false -> ok;
        true -> setup_cleanup_timer()
    end,
    {noreply, NewState};

handle_info(Request, State) ->
    ?DEBUG("unknown request: ~p, state: ~p", [Request, State]),
    {noreply, State}.


-spec handle_apns_response(Status :: integer(),
        Id :: integer(), State :: push_state()) -> push_state().
handle_apns_response(Status, Id, State) when Status == 10 orelse Status == 7 ->
    PushMessageItem = lists:keyfind(Id, #push_message_item.id, State#push_state.pendingList),
    NewState = case PushMessageItem of
        false ->
            ?INFO_MSG("Could not find the message, id: ~s, ignoring it.", [Id]),
            State;
        _ ->
            ?INFO_MSG("retrying message item: ~p", [Id]),
            PendingList = lists:delete(PushMessageItem, State#push_state.pendingList),
            retry_message_item(PushMessageItem),
            State#push_state{pendingList = PendingList}
    end,
    NewState;
handle_apns_response(Status, _Id, State) ->
    ?ERROR_MSG("non-recoverable APNS error: ~p", [Status]),
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


%% Sends an apns push notification to the user with a subject and body using that token of the user.
%% Using the legacy binary API for now: link below for details
%% [https://developer.apple.com/library/archive/documentation/NetworkingInternet/Conceptual/RemoteNotificationsPG/BinaryProviderAPI.html#//apple_ref/doc/uid/TP40008194-CH13-SW1]
%% TODO(murali@): switch to the modern API soon.
-spec push_message_item(PushMessageItem :: push_message_item(),
        State :: push_state()) -> push_state().
push_message_item(PushMessageItem, State) ->
    BuildType = case PushMessageItem#push_message_item.push_info#push_info.os of
        <<"ios">> -> prod;
        <<"ios_dev">> -> dev
    end,
    Id = PushMessageItem#push_message_item.id,
    Uid = PushMessageItem#push_message_item.uid,
    PayloadBin = get_payload(PushMessageItem, BuildType),
    PayloadLength = size(PayloadBin),
    %% Token length is hardcoded for now. TODO(murali@): move away from this!
    Token = PushMessageItem#push_message_item.push_info#push_info.token,
    TokenLength = 32,
    TokenNum = erlang:binary_to_integer(Token, 16),
    TokenBin = <<TokenNum:TokenLength/integer-unit:8>>,
    ExpiryTime = PushMessageItem#push_message_item.timestamp + ?MESSAGE_EXPIRY_TIME_SEC,
    %% Packet structure is described in the link above for legacy binary API in APNS.
    Packet = <<1:1/unit:8, Id:4/binary, ExpiryTime:4/unit:8, TokenLength:2/unit:8,
            TokenBin/binary, PayloadLength:2/unit:8, PayloadBin/binary>>,
    {NewState, SocketToSend} = get_socket_to_send(BuildType, State),
    FinalState = case SocketToSend of
        undefined ->
            retry_message_item(PushMessageItem),
            NewState;
        _ ->
            Result = ssl:send(SocketToSend, Packet),
            case Result of
                ok ->
                    ?DEBUG("sent to apns, Uid: ~s, id: ~p", [Uid, Id]),
                    add_to_pending_list(PushMessageItem, NewState);
                {error, Reason} ->
                    ?ERROR_MSG("failure: Uid: ~s, id: ~p, reason: ~p", [Uid, Id, Reason]),
                    retry_message_item(PushMessageItem),
                    NewState
            end
    end,
    FinalState.


-spec add_to_pending_list(PushMessageItem :: push_message_item(),
        State :: push_state()) -> push_state().
add_to_pending_list(PushMessageItem, State) ->
    setup_cleanup_timer(),
    PendingList = [PushMessageItem | State#push_state.pendingList],
    State#push_state{pendingList = PendingList}.


-spec retry_message_item(PushMessageItem :: push_message_item()) -> reference().
retry_message_item(PushMessageItem) ->
    RetryTime = PushMessageItem#push_message_item.retry_ms,
    setup_timer({retry, PushMessageItem}, RetryTime).


-spec get_socket_to_send(BuildType :: build_type(),
        State :: push_state()) -> {push_state(), sslsocket() | undefined}.
get_socket_to_send(prod = BuildType, #push_state{socket = undefined} = State) ->
    Socket = connect_to_apns(BuildType),
    {State#push_state{socket = Socket}, Socket};
get_socket_to_send(prod, State) ->
    {State, State#push_state.socket};
get_socket_to_send(dev = BuildType, #push_state{dev_socket = undefined} = State) ->
    DevSocket = connect_to_apns(BuildType),
    {State#push_state{dev_socket = DevSocket}, DevSocket};
get_socket_to_send(dev, State) ->
    {State, State#push_state.dev_socket}.


-spec parse_message(#message{}) -> {binary(), binary()}.
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


-spec get_payload(PushMessageItem :: push_message_item(), BuildType :: build_type()) -> binary().
get_payload(PushMessageItem, BuildType) ->
    BuildTypeMap = case BuildType of
        prod ->
            {Subject, Body} = parse_message(PushMessageItem#push_message_item.message),
            DataMap = #{<<"title">> => Subject, <<"body">> => Body},
            #{<<"alert">> => DataMap, <<"sound">> => <<"default">>};
        dev ->
            #{}
    end,
    ApsMap = BuildTypeMap#{<<"content-available">> => <<"1">>},
    PayloadMap = #{<<"aps">> => ApsMap},
    jiffy:encode(PayloadMap).


%%====================================================================
%% setup timers
%%====================================================================

-spec setup_cleanup_timer() -> reference().
setup_cleanup_timer() ->
    setup_timer({clean_up_state}, ?STATE_CLEANUP_TIMEOUT_MILLISEC).


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

