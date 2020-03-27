%%%----------------------------------------------------------------------
%%% File    : mod_push_notifications.erl
%%%
%%% Copyright (C) 2019 halloappinc.
%%%
%%% This module handles all the push notification related queries and hooks.
%%% - Handles iq-queries of type set and get for push_tokens for users.
%%% - Capable of sending push notifications for offline messages to android users through FCM.
%%% - Capable of sending push notifications for offline messages to iOS users using the binary API
%%% for APNS.
%%% - Capable of retrying to send failed pushed notifications.
%%% - Currently, the process tries to resend failed push notifications using a retry interval
%%% from a fibonacci series starting with 0, 30 seconds for the next 10 minutes which is about
%%% 9 retries and then then discards the push notification.
%%% We do this, by maintaining a state for the process that contains all the necessary information
%%% about pendingMessages that haven't received their status about the notification,
%%% retryMessages that should be resent again to the user, host of the process and
%%% the socket for the connection to APNS.
%%% We keep triggering retry timers for each message that have failed previously and we use the
%%% fibonacci series explained above when doing so. Everytime the timer is triggerred, the
%%% mod_push_notifications process receives a message called {retry, MessageItem} and
%%% then we resend the notifications to APNS/FCM based for that specific item.
%%% Additionally, we also triggering clean_up_internal_state timers to clean up the list of
%%% pending messages that haven't received a response based
%%% on the MESSAGE_RESPONSE_TIMEOUT_SEC value(2min).
%%% We also clean up the list of retry messages based
%%% on the MESSAGE_MAX_RETRY_TIME_SEC value(10min).
%%%----------------------------------------------------------------------

-module(mod_push_notifications).
-author('murali').
-behaviour(gen_mod).
-behaviour(gen_server).

-include("logger.hrl").
-include("xmpp.hrl").
-include("translate.hrl").

-define(NS_PUSH, <<"halloapp:push:notifications">>).
-define(SSL_TIMEOUT_MILLISEC, 10000).              %% 10 seconds.
-define(HTTP_TIMEOUT_MILLISEC, 10000).             %% 10 seconds.
-define(HTTP_CONNECT_TIMEOUT_MILLISEC, 10000).     %% 10 seconds.
-define(MESSAGE_EXPIRY_TIME_SEC, 86400).           %% 1 day.
-define(MESSAGE_RESPONSE_TIMEOUT_SEC, 60).         %% 1 minute.
-define(STATE_CLEANUP_TIMEOUT_MILLISEC, 120000).   %% 2 minutes.
-define(MESSAGE_MAX_RETRY_TIME_SEC, 600).          %% 10 minutes.
-define(RETRY_INTERVAL_MILLISEC, 30000).           %% 30 seconds.

%% gen_mod API
-export([start/2, stop/1, reload/3, depends/2, mod_opt_type/1, mod_options/1]).
%% gen_server API
-export([init/1, terminate/2, code_change/3, handle_call/3, handle_cast/2, handle_info/2]).
%% hooks and iq handler.
-export([process_local_iq/1, handle_message/1]).


%% record to keep track of all the information regarding a message.
-record(message_item, {message_id :: integer(),
                       message :: message(),
                       timestamp :: binary(),
                       prev_retry_time0 :: integer(),
                       prev_retry_time1 :: integer()}).

%% state for this process holds the necessary information to retry sending push notifications
%% that couldn't be delivered.
%% pendingMessageList: This contains the list of messages for which we await a response from APNS.
%% We get no response if it successful and an error response code if it failed.
%% retryMessageList: This contains the list of messages that should be resent to the user.
%% host: stores the serverHost of the process.
%% socket: socket that is returned upon establishing a connection with the apns server.
-record(state, {pendingMessageList :: [#message_item{}],
                retryMessageList :: [#message_item{}],
                host :: binary(),
                socket :: ssl:socket()}).


%%====================================================================
%% gen_mod API.
%%====================================================================

start(Host, Opts) ->
    ?DEBUG("mod_push_notifications: start", []),
    gen_mod:start_child(?MODULE, Host, Opts).

stop(Host) ->
    ?DEBUG("mod_push_notifications: stop", []),
    gen_mod:stop_child(?MODULE, Host).

depends(_Host, _Opts) ->
    [].

reload(_Host, _NewOpts, _OldOpts) ->
    ok.

%%====================================================================
%% gen_server callbacks
%%====================================================================

init([Host|_]) ->
    ?DEBUG("mod_push_notifications: init", []),
    process_flag(trap_exit, true),
    Opts = gen_mod:get_module_opts(Host, ?MODULE),
    xmpp:register_codec(push_notifications),
    store_options(Opts),
    mod_push_notifications_mnesia:init(Host, Opts),
    gen_iq_handler:add_iq_handler(ejabberd_local, Host, ?NS_PUSH, ?MODULE, process_local_iq),
    ejabberd_hooks:add(offline_message_hook, Host, ?MODULE, handle_message, 48),
    %% Start necessary modules from erlang.
    %% These modules are not ejabberd modules. Hence, we manually start them.
    inets:start(),
    crypto:start(),
    ssl:start(),
    {ok, #state{pendingMessageList = [],
                retryMessageList = [],
                host = Host}}.


terminate(_Reason, #state{host = Host, socket = Socket}) ->
    ?DEBUG("mod_push_notifications: terminate", []),
    xmpp:unregister_codec(push_notifications),
    gen_iq_handler:remove_iq_handler(ejabberd_local, Host, ?NS_PUSH),
    ejabberd_hooks:delete(offline_message_hook, Host, ?MODULE, handle_message, 48),
    mod_push_notifications_mnesia:close(),
    case Socket of
        undefined -> ok;
        _ -> ssl:close(Socket)
    end,
    ok.


code_change(_OldVsn, State, _Extra) ->
    ?DEBUG("mod_push_notifications: code_change", []),
    {ok, State}.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%    gen_server:call    %%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

handle_call({process_iq, IQ}, _From, State) ->
    ?DEBUG("mod_push_notifications: handle_call: process_iq", []),
    {reply, process_iq(IQ), State};

handle_call(Request, _From, State) ->
    ?DEBUG("mod_push_notifications: handle_call: ~p", [Request]),
    {reply, {error, bad_arg}, State}.


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%    gen_server:cast       %%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

handle_cast({process_message, Message} = _Request, State) ->
    ?DEBUG("mod_push_notifications: handle_cast: process_message: ~p", [Message]),
    NewState = process_message(Message, State),
    {noreply, NewState};

handle_cast(Request, State) ->
    ?DEBUG("mod_push_notifications: handle_cast: Invalid request, ignoring it: ~p", [Request]),
    {noreply, State}.


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%    other messages      %%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

handle_info({ssl, Socket, Data}, State) ->
    ?DEBUG("mod_push_notifications: received a message from ssl: ~p, ~p, ~p",
                                                                            [Socket, Data, State]),
    try
        <<RCommand:1/unit:8, RStatus:1/unit:8, RId:4/unit:8>> = iolist_to_binary(Data),
        {RCommand, RStatus, RId}
    of
        {8, Status, Id} ->
            ?INFO_MSG("mod_push_notifications: Failed sending push notification with id: ~p", [Id]),
            NewState = handle_apns_response_to_message(Status, Id, State),
            setup_timer({clean_up_internal_state}, ?STATE_CLEANUP_TIMEOUT_MILLISEC),
            {noreply, NewState};
        _ ->
            ?ERROR_MSG("mod_push_notifications: invalid APNS response", []),
            {noreply, State}
    catch
        {'EXIT', _} ->
            ?ERROR_MSG("mod_push_notifications: invalid APNS response", []),
            {noreply, State}
    end;

handle_info({ssl_closed, Socket}, State) ->
    ?DEBUG("mod_push_notifications: received a message from ssl_closed: ~p, ~p", [Socket, State]),
    {noreply, State#state{socket = undefined}};

handle_info({ssl_error, Socket, Reason}, State) ->
    ?DEBUG("mod_push_notifications:
             received a message from ssl_error: ~p, ~p, ~p", [Socket, Reason, State]),
    {noreply, State};

handle_info({ssl_passive, Socket}, State) ->
    ?DEBUG("mod_push_notifications:
             received a message from ssl_passive: ~p, ~p", [Socket, State]),
    {noreply, State};

handle_info({retry, MessageItem}, State0) ->
    ?INFO_MSG("mod_push_notifications:
                 received the retry message: will retry to resend failed messages.", []),
    CurrentTimestamp = util:convert_timestamp_to_binary(erlang:timestamp()),
    State1 = clean_up_messages(State0, CurrentTimestamp),
    State2 = handle_retry_message(MessageItem, State1),
    {noreply, State2};

handle_info({clean_up_internal_state}, State) ->
    ?INFO_MSG("mod_push_notifications:
                 clean_up_internal_state: will clean up internal state.", []),
    CurrentTimestamp = util:convert_timestamp_to_binary(erlang:timestamp()),
    State1 = clean_up_messages(State, CurrentTimestamp),
    PendingMessageList = State1#state.pendingMessageList,
    RetryMessageList = State1#state.retryMessageList,
    if
        length(PendingMessageList) > 0 ->
            setup_timer({clean_up_internal_state}, ?STATE_CLEANUP_TIMEOUT_MILLISEC);
        length(RetryMessageList) > 0 ->
            setup_timer({clean_up_internal_state}, ?STATE_CLEANUP_TIMEOUT_MILLISEC * 2);
        true ->
            ok
    end,
    {noreply, State1};

handle_info(Request, State) ->
    ?DEBUG("mod_push_notifications: received an unknown request: ~p, ~p", [Request, State]),
    {noreply, State}.



%%====================================================================
%% module hooks and iq handlers.
%%====================================================================

process_local_iq(#iq{to = Host} = IQ) ->
    ?DEBUG("mod_push_notifications: process_local_iq", []),
    ServerHost = jid:encode(Host),
    gen_server:call(gen_mod:get_module_proc(ServerHost, ?MODULE), {process_iq, IQ}).

handle_message({_, #message{to = #jid{luser = _, lserver = ServerHost}} = Message} = Acc) ->
    ?DEBUG("mod_push_notifications: handle_message", []),
    %% TODO(murali@): Temporary fix for now: handle this in a better way!
    case Message of
        #message{sub_els = [#ps_event{items = #ps_items{node = Node}}]} ->
            case re:run(binary_to_list(Node), "feed-.*", [global, {capture, none}]) of
                match ->
                    gen_server:cast(gen_mod:get_module_proc(ServerHost, ?MODULE),
                                                                {process_message, Message});
                _ ->
                    ok
            end;
        #message{sub_els = [#chat{}]} ->
            gen_server:cast(gen_mod:get_module_proc(ServerHost, ?MODULE),
                                                                {process_message, Message});
        _ ->
            ?ERROR_MSG("mod_push_notifications: handle_message: ignoring this message
                                                        for push notifications: ~p", [Message]),
            ok
    end,
    Acc.



%%====================================================================
%% internal module functions
%%====================================================================

-spec handle_apns_response_to_message(integer(), integer(), #state{}) -> #state{}.
handle_apns_response_to_message(Status, Id, State) when Status == 10 orelse Status == 7 ->
    MessageItem = lists:keyfind(Id, #message_item.message_id, State#state.pendingMessageList),
    case MessageItem of
        false ->
            ?DEBUG("mod_push_notifications:
                     Couldn't find the message with message id: ~p, so ignoring it.", [Id]),
            PendingMessageList = State#state.pendingMessageList,
            RetryMessageList = State#state.retryMessageList;
        _ ->
            RetryTimeout = MessageItem#message_item.prev_retry_time0 +
                                MessageItem#message_item.prev_retry_time1,
            PendingMessageList = lists:delete(MessageItem, State#state.pendingMessageList),
            RetryMessageList = lists:append([State#state.retryMessageList, [MessageItem]]),
            setup_timer({retry, MessageItem}, RetryTimeout),
            ?DEBUG("mod_push_notifications:
                     Found the message item: ~p, so retrying it.", [MessageItem])
    end,
    State#state{pendingMessageList = PendingMessageList,
                retryMessageList = RetryMessageList};
handle_apns_response_to_message(Status, _Id, State) ->
    ?ERROR_MSG("mod_push_notifications:
                 Failed sending push notification: non-recoverable APNS error: ~p", [Status]),
    State.



-spec handle_retry_message(#message_item{}, #state{}) -> #state{}.
handle_retry_message(MessageItem, State0) ->
    ?DEBUG("mod_push_notifications: retrying to send this message: ~p", [MessageItem]),
    RetryMessageList = lists:delete(MessageItem, State0#state.retryMessageList),
    State1 = State0#state{retryMessageList = RetryMessageList},
    RetryTimeout = MessageItem#message_item.prev_retry_time0 +
                        MessageItem#message_item.prev_retry_time1,
    PrevRetryTime1 = MessageItem#message_item.prev_retry_time1,
    NewMessageItem = MessageItem#message_item{prev_retry_time0 = PrevRetryTime1,
                                              prev_retry_time1 = RetryTimeout},
    State2 = process_message_item(NewMessageItem, State1),
    State2.



-spec clean_up_messages(#state{}, binary()) -> #state{}.
clean_up_messages(State, CurrentTimestamp) ->
    ?DEBUG("Before cleaning up messages here at timestamp: ~p:
             PendingMessageList: ~p, ~n, RetryMessageList: ~p",
                 [CurrentTimestamp, State#state.pendingMessageList, State#state.retryMessageList]),
    PendingMessageList = lists:dropwhile(
                            fun(MessageItem) ->
                                Timestamp = MessageItem#message_item.timestamp,
                                util:convert_binary_to_integer(CurrentTimestamp) -
                                        util:convert_binary_to_integer(Timestamp) >=
                                                ?MESSAGE_RESPONSE_TIMEOUT_SEC
                            end, State#state.pendingMessageList),
    RetryMessageList = lists:dropwhile(
                            fun(MessageItem) ->
                                Timestamp = MessageItem#message_item.timestamp,
                                util:convert_binary_to_integer(CurrentTimestamp) -
                                        util:convert_binary_to_integer(Timestamp) >=
                                                ?MESSAGE_MAX_RETRY_TIME_SEC
                            end, State#state.retryMessageList),
    ?DEBUG("After cleaning up messages here: PendingMessageList: ~p, ~n, RetryMessageList: ~p",
                                                        [PendingMessageList, RetryMessageList]),
    State#state{pendingMessageList = PendingMessageList,
                retryMessageList = RetryMessageList}.



-spec process_iq(#iq{}) -> #iq{}.
%% iq-stanza with get: retrieves the push token for the user if available and
%% sends it back to the user.
process_iq(#iq{from = #jid{luser = User, lserver = Server},
                        type = get, lang = Lang, to = _Host} = IQ) ->
    ?INFO_MSG("mod_push_notifications: Processing local iq ~p", [IQ]),
    case mod_push_notifications_mnesia:list_push_registrations({User, Server}) of
        {ok, none} ->
            xmpp:make_iq_result(IQ);
        {ok, {{User, Server}, Os, Token, _Timestamp}} ->
            xmpp:make_iq_result(IQ, #push_register{push_token = {Os, Token}});
        {error, _} ->
            Txt = ?T("Database failure"),
            xmpp:make_error(IQ, xmpp:err_internal_server_error(Txt, Lang))
    end;

%% iq-stanza with set: inserts the push token for the user into the table.
process_iq(#iq{from = #jid{luser = User, lserver = Server},
                        type = set, lang = Lang, to = _Host,
                            sub_els = [#push_register{push_token = {Os, Token}}]} = IQ) ->
    ?INFO_MSG("mod_push_notifications: Processing local iq ~p", [IQ]),
    case Token of
        <<>> ->
            Txt = ?T("Invalid value for token."),
            xmpp:make_error(IQ, xmpp:err_bad_request(Txt, Lang));
        _ELse ->
            Timestamp = util:convert_timestamp_to_binary(erlang:timestamp()),
            case mod_push_notifications_mnesia:register_push({User, Server},
                                                                Os, Token, Timestamp) of
                {ok, _} ->
                    xmpp:make_iq_result(IQ);
                {error, _} ->
                    Txt = ?T("Database failure"),
                    xmpp:make_error(IQ, xmpp:err_internal_server_error(Txt, Lang))
            end
    end;

process_iq(#iq{lang = Lang} = IQ) ->
    Txt = ?T("Unable to handle this IQ"),
    xmpp:make_error(IQ, xmpp:err_internal_server_error(Txt, Lang)).



%% process_message is the function that would be eventually invoked on the event
%% 'offline_message_hook'.
-spec process_message(#message{}, #state{}) -> #state{}.
%% Currently ignoring message-types, but probably need to handle different message types separately!
process_message(#message{} = Message, State) ->
    Timestamp = util:convert_timestamp_to_binary(erlang:timestamp()),
    MessageId = get_new_message_id(),
    MessageItem = #message_item{message_id = MessageId,
                                message = Message,
                                timestamp = Timestamp,
                                prev_retry_time0 = 0,
                                prev_retry_time1 = ?RETRY_INTERVAL_MILLISEC},
    process_message_item(MessageItem, State).

-spec process_message_item(#message_item{}, #state{}) -> #state{}.
process_message_item(MessageItem, State) ->
    ?INFO_MSG("mod_push_notifications: Handling Offline message item~p", [MessageItem]),
    NewState = handle_push_message(MessageItem, State),
    NewState.



%% Handles the push message: determines the os for the user and sends a request to either
%% fcm or apns accordingly.
-spec handle_push_message(#message_item{}, #state{}) -> #state{}.
handle_push_message(MessageItem, #state{host = _Host} = State) ->
    Message = MessageItem#message_item.message,
    #message{from = From, to = To} = Message,
    JFrom = jid:encode(jid:remove_resource(From)),
    _JTo = jid:encode(jid:remove_resource(To)),
    ToUser = To#jid.luser,
    ToServer = To#jid.lserver,
    {Subject, Body} = parse_message(Message),
    ?DEBUG("mod_push_notifications: Obtaining push token for user: ~p", [To]),
    case mod_push_notifications_mnesia:list_push_registrations({ToUser, ToServer}) of
        {ok, none} ->
            ?DEBUG("mod_push_notifications: No push token available for user: ~p", [To]),
            State;
        {ok, {{ToUser, ToServer}, Os, Token, _}} ->
            Args = {JFrom, {ToUser, ToServer}, Subject, Body, Token, MessageItem, State},
            NewState = send_push_notification_based_on_os(Os, Args),
            NewState;
        {error, _} ->
            State
    end.



-spec send_push_notification_based_on_os(binary(),
                                        {binary(), {binary(), binary()},
                                            binary(), binary(), binary(),
                                            #message_item{},#state{}}) -> #state{}.
send_push_notification_based_on_os(<<"ios">>, Args) ->
    {_, _, _, _, _, MessageItem, _} = Args,
    #message{to = To} = MessageItem#message_item.message,
    ?INFO_MSG("mod_push_notifications:
                 Trying to send an ios push notification for user: ~p through apns", [To]),
    send_apns_push_notification(Args);
send_push_notification_based_on_os(<<"android">>, Args) ->
    {_, _, _, _, _, MessageItem, _} = Args,
    #message{to = To} = MessageItem#message_item.message,
    ?INFO_MSG("mod_push_notifications:
                 Trying to send an android push notification for user: ~p through fcm", [To]),
    send_fcm_push_notification(Args);
send_push_notification_based_on_os(Os, Args) ->
    {_, {ToUser, ToServer}, _, _, _, _, State} = Args,
    ?ERROR_MSG("mod_push_notifications:
                 Invalid OS: ~p and token for the user: ~p ~p", [Os, ToUser, ToServer]),
    State.



%% Sends an apns push notification to the user with a subject and body using that token of the user.
%% Using the legacy binary API for now: link below for details
%% [https://developer.apple.com/library/archive/documentation/NetworkingInternet/Conceptual/
%%RemoteNotificationsPG/BinaryProviderAPI.html#//apple_ref/doc/uid/TP40008194-CH13-SW1]
%% TODO(murali@): switch to the modern API soon.
-spec send_apns_push_notification({binary(), {binary(), binary()},
                                    binary(), binary(), binary(),
                                    #message_item{}, #state{}}) -> #state{}.
send_apns_push_notification(Args) ->
    {_From, Username, Subject, Body, Token, MessageItem, State} = Args,
    ApnsGateway = get_apns_gateway(),
    ApnsCertfile = get_apns_certfile(),
    ApnsPort = get_apns_port(),
    MessageId = MessageItem#message_item.message_id,
    RetryTimeout = MessageItem#message_item.prev_retry_time0 +
                        MessageItem#message_item.prev_retry_time1,
    Options = [{certfile, ApnsCertfile},
               {mode, binary}],
    Payload = lists:append(["{\"aps\":",
                                    "{\"alert\":",
                                                    "{\"title\":\"", binary_to_list(Subject), "\","
                                                    "\"body\":\"", binary_to_list(Body), "\"",
                                                    "},",
                                    "\"sound\":\"default\",",
                                    "\"content-available\":\"1\"",
                            "}}"]),
    case ssl:connect(ApnsGateway, ApnsPort, Options, ?SSL_TIMEOUT_MILLISEC) of
        {ok, Socket} ->
            PayloadBin = list_to_binary(Payload),
            PayloadLength = size(PayloadBin),
            %% Token length is hardcoded for now.
            TokenLength = 32,
            TokenNum = erlang:binary_to_integer(Token, 16),
            TokenBin = <<TokenNum:TokenLength/integer-unit:8>>,
            Timestamp = MessageItem#message_item.timestamp,
            ExpiryTime = get_expiry_time(Timestamp),
            %% Packet structure is described in the link above for binary API in APNS.
            Packet = <<1:1/unit:8, MessageId:4/unit:8, ExpiryTime:4/unit:8, TokenLength:2/unit:8,
                        TokenBin/binary, PayloadLength:2/unit:8, PayloadBin/binary>>,
            Result = ssl:send(Socket, Packet),
            case Result of
                ok ->
                    ?DEBUG("mod_push_notifications:
                     Successfully sent payload to the APNS server, result: ~p for the user: ~p",
                    [Result, Username]),
                    PendingMessageList = lists:append([State#state.pendingMessageList,
                                                        [MessageItem]]),
                    RetryMessageList = State#state.retryMessageList,
                    SSLSocket = Socket;
                {error, Reason} ->
                    ?ERROR_MSG("mod_push_notifications:
                     Failed sending a push notification to the APNS server: ~p, reason: ~p",
                    [Username, Reason]),
                    PendingMessageList = State#state.pendingMessageList,
                    RetryMessageList = lists:append([State#state.retryMessageList,
                                                        [MessageItem]]),
                    setup_timer({retry, MessageItem}, RetryTimeout),
                    SSLSocket = Socket
            end;
        {error, Reason} = _Err ->
            ?ERROR_MSG("mod_push_notifications:
             Unable to connect to the APNS server: ~s for the user: ~p",
            [ssl:format_error(Reason), Username]),
            PendingMessageList = State#state.pendingMessageList,
            RetryMessageList = lists:append([State#state.retryMessageList, [MessageItem]]),
            setup_timer({retry, MessageItem}, RetryTimeout),
            SSLSocket = undefined
    end,
    setup_timer({clean_up_internal_state}, ?STATE_CLEANUP_TIMEOUT_MILLISEC),
    State#state{pendingMessageList = PendingMessageList,
               retryMessageList = RetryMessageList,
               socket = SSLSocket}.



%% Sends an fcm push notification to the user with a subject and body using that token of the user.
-spec send_fcm_push_notification({binary(), {binary(), binary()},
                                    binary(), binary(), binary(),
                                    {binary(), #message{}, binary()}, #state{}}) -> #state{}.
send_fcm_push_notification(Args) ->
    {_From, Username, Subject, Body, Token, MessageItem, State} = Args,
    %%%%%%%%%%%%%%%%%%%%%%%%%%%%
    %% Set timeout options here.
    %%%%%%%%%%%%%%%%%%%%%%%%%%%%
    HTTPOptions = [{timeout, ?HTTP_TIMEOUT_MILLISEC},
                    {connect_timeout, ?HTTP_CONNECT_TIMEOUT_MILLISEC}],
    Options = [],
    FcmGateway = get_fcm_gateway(),
    FcmApiKey = get_fcm_apikey(),
    RetryTimeout = MessageItem#message_item.prev_retry_time0 +
                        MessageItem#message_item.prev_retry_time1,
    Payload = [{body, Body}, {title, Subject}],
    PushMessage = {[{to,           Token},
                    {priority,     <<"high">>},
                    {data, {Payload}}
                   ]},
    Request = {FcmGateway, [{"Authorization", "key="++FcmApiKey}],
                "application/json", jiffy:encode(PushMessage)},
    Response = httpc:request(post, Request, HTTPOptions, Options),
    case Response of
        {ok, {{_, StatusCode5xx, _}, _, ResponseBody}} when StatusCode5xx >= 500 andalso
                                                            StatusCode5xx < 600 ->
            ?DEBUG("mod_push_notifications: recoverable FCM error: ~p", [ResponseBody]),
            ?ERROR_MSG("mod_push_notifications:
             Failed sending a push notification to user immediately: ~p, reason: ~p",
            [Username, ResponseBody]),
            RetryMessageList = lists:append([State#state.retryMessageList, [MessageItem]]),
            setup_timer({retry, MessageItem}, RetryTimeout);
        {ok, {{_, 200, _}, _, ResponseBody}} ->
            case parse_response(ResponseBody) of
                ok ->
                    ?DEBUG("mod_push_notifications:
                     Successfully sent a push notification to user: ~p, should receive it soon.",
                    [Username]),
                    RetryMessageList = State#state.retryMessageList;
                _ ->
                    ?ERROR_MSG("mod_push_notifications:
                     Failed sending a push notification to user: ~p, token: ~p, reason: ~p",
                    [Username, Token, ResponseBody]),
                    RetryMessageList = lists:append([State#state.retryMessageList, [MessageItem]]),
                    setup_timer({retry, MessageItem}, RetryTimeout)
            end;
        {ok, {{_, _, _}, _, ResponseBody}} ->
            ?DEBUG("mod_push_notifications: non-recoverable FCM error: ~p", [ResponseBody]),
            RetryMessageList = State#state.retryMessageList;
        {error, Reason} ->
            ?ERROR_MSG("mod_push_notifications:
             Failed sending a push notification to user immediately: ~p, reason: ~p",
            [Username, Reason]),
            RetryMessageList = lists:append([State#state.retryMessageList, [MessageItem]]),
            setup_timer({retry, MessageItem}, RetryTimeout)
    end,
    setup_timer({clean_up_internal_state}, ?STATE_CLEANUP_TIMEOUT_MILLISEC),
    State#state{retryMessageList = RetryMessageList}.



-spec setup_timer({any() | _}, integer()) -> reference().
setup_timer(Msg, TimeoutSec) ->
    NewTimer = erlang:send_after(TimeoutSec, self(), Msg),
    NewTimer.



%% Parses response of the request to check if everything worked successfully.
-spec parse_response(binary()) -> ok | any().
parse_response(ResponseBody) ->
    {JsonData} = jiffy:decode(ResponseBody),
    case proplists:get_value(<<"success">>, JsonData) of
        1 ->
            ok;
        0 ->
            [{Result}] = proplists:get_value(<<"results">>, JsonData),
            case proplists:get_value(<<"error">>, Result) of
                <<"NotRegistered">> ->
                    ?ERROR_MSG("mod_push_notifications:
                                FCM error: NotRegistered, unregistered user", []),
                    not_registered;
                <<"InvalidRegistration">> ->
                    ?ERROR_MSG("mod_push_notifications:
                                FCM error: InvalidRegistration, unregistered user", []),
                    invalid_registration;
                _ -> other
            end
    end.



%% Parses message for subject and body, else use default message and body.
%% Better way to parse message maybe? handle all cases?
-spec parse_message(#message{}) -> {binary(), binary()}.
parse_message(#message{} = Message) ->
    Subject = xmpp:get_text(Message#message.subject),
    Body = xmpp:get_text(Message#message.body),
    if
        Subject =/= <<>> orelse Body =/= <<>> ->
            {Subject, Body};
        true ->
            case Message of
                #message{sub_els = [#ps_event{items = ItemsEls}]} ->
                    case ItemsEls of
                        #ps_items{node = _Node,
                                 items = [#ps_item{id = _ItemId,
                                                   type = ItemType,
                                                   timestamp = _Timestamp,
                                                   publisher = _ItemPublisher,
                                                   sub_els = _ItemPayload}]} ->
                            %% Show only plain notification for now.
                            case ItemType of
                                comment -> {<<"New Notification">>, <<"New comment">>};
                                feedpost -> {<<"New Notification">>, <<"New feedpost">>};
                                _ -> {<<"New Message">>, <<"You got a new message.">>}
                            end;
                        _ ->
                            {<<"New Message">>, <<"You got a new message.">>}
                    end;
                _ ->
                    {<<"New Message">>, <<"You got a new message.">>}
            end
    end.



%% Store the necessary options with persistent_term.
%% [https://erlang.org/doc/man/persistent_term.html]
store_options(Opts) ->
    FcmOptions = mod_push_notifications_opt:fcm(Opts),
    ApnsOptions = mod_push_notifications_opt:apns(Opts),

    %% Store FCM Gateway and APIkey as strings.
    FcmGateway = proplists:get_value(gateway, FcmOptions),
    persistent_term:put({?MODULE, fcm_gateway}, binary_to_list(FcmGateway)),
    FcmApiKey = proplists:get_value(apikey, FcmOptions),
    persistent_term:put({?MODULE, fcm_apikey}, binary_to_list(FcmApiKey)),

    %% Store APNS Gateway and APIkey as strings.
    ApnsGateway = proplists:get_value(gateway, ApnsOptions),
    persistent_term:put({?MODULE, apns_gateway}, binary_to_list(ApnsGateway)),
    ApnsCertfile = proplists:get_value(certfile, ApnsOptions),
    persistent_term:put({?MODULE, apns_certfile}, binary_to_list(ApnsCertfile)),
    %% Store APNS port as int.
    ApnsPort = proplists:get_value(port, ApnsOptions),
    persistent_term:put({?MODULE, apns_port}, ApnsPort).

-spec get_fcm_gateway() -> list().
get_fcm_gateway() ->
    persistent_term:get({?MODULE, fcm_gateway}).

-spec get_fcm_apikey() -> list().
get_fcm_apikey() ->
    persistent_term:get({?MODULE, fcm_apikey}).

-spec get_apns_gateway() -> list().
get_apns_gateway() ->
    persistent_term:get({?MODULE, apns_gateway}).

-spec get_apns_certfile() -> list().
get_apns_certfile() ->
    persistent_term:get({?MODULE, apns_certfile}).

-spec get_apns_port() -> integer().
get_apns_port() ->
    persistent_term:get({?MODULE, apns_port}).

-spec get_new_message_id() -> integer().
get_new_message_id() ->
    NewMessageId =
    try persistent_term:get({?MODULE, last_message_id}) of
        %% Check if it is the max-value of 4-byte unsigned integer and reset if it is.
        MessageId when MessageId == (4294967296 - 1) -> 0;
        MessageId -> MessageId + 1
    catch
        _:_ -> 0
    end,
    persistent_term:put({?MODULE, last_message_id}, NewMessageId),
    NewMessageId.


%% Converts the timestamp to an integer and then adds the MESSAGE_EXPIRY_TIME(1 day)
%% seconds and returns the integer.
-spec get_expiry_time(binary())  -> integer().
get_expiry_time(Timestamp) ->
    CurrentTime = util:convert_binary_to_integer(Timestamp),
    ExpiryTime = CurrentTime + ?MESSAGE_EXPIRY_TIME_SEC,
    ExpiryTime.


-spec mod_opt_type(atom()) -> econf:validator().
mod_opt_type(fcm) ->
    econf:map(
      econf:atom(),
      econf:either(
      econf:binary(),
      econf:int()),
      [unique]);
mod_opt_type(apns) ->
    econf:map(
      econf:atom(),
      econf:either(
      econf:binary(),
      econf:int()),
      [unique]).

mod_options(_Host) ->
    [{fcm, []},
     {apns, []}].

