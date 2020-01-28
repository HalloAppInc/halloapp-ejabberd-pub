%%%----------------------------------------------------------------------
%%% File    : mod_push_notifications.erl
%%%
%%% Copyright (C) 2019 halloappinc.
%%%
%%% This module handles all the push notification related queries and hooks. 
%%% - Capable of sending push notifications for offline messages to android users through FCM
%%% - Capable of sending push notifications for offline messages to iOS users using the binary API for APNS.
%%%----------------------------------------------------------------------

-module(mod_push_notifications).

-behaviour(gen_mod).

-include("logger.hrl").
-include("xmpp.hrl").
-include("translate.hrl").

-define(NS_PUSH, <<"halloapp:push:notifications">>).
-define(APNS_MESSAGE_PRIORITY, 10).
-define(SSL_TIMEOUT, 10000).
-define(HTTP_TIMEOUT, 10000).
-define(HTTP_CONNECT_TIMEOUT, 10000).

-export([start/2, stop/1, depends/2, mod_opt_type/1, mod_options/1, process_local_iq/1, handle_message/1, handle_push_message/1]).

start(Host, Opts) ->
    xmpp:register_codec(push_notifications),
    store_options(Opts),
    mod_push_notifications_mnesia:init(Host, Opts),
    gen_iq_handler:add_iq_handler(ejabberd_local, Host, ?NS_PUSH, ?MODULE, process_local_iq),
    ejabberd_hooks:add(offline_message_hook, Host, ?MODULE, handle_message, 48),
    %% Start necessary modules from erlang.
    inets:start(),
    crypto:start(),
    ssl:start(),
    %% The above modules are not ejabberd modules. Hence, we manually start them.
    ok.

stop(Host) ->
    xmpp:unregister_codec(push_notifications),
    gen_iq_handler:remove_iq_handler(ejabberd_local, Host, ?NS_PUSH),
    ejabberd_hooks:delete(offline_message_hook, Host, ?MODULE, handle_message, 48),
    mod_push_notifications:close(),
    ok.

depends(_Host, _Opts) ->
    [].

reload(_Host, _NewOpts, _OldOpts) ->
    ok.


-spec process_local_iq(#iq{}) -> #iq{}.
%% iq-stanza with get: retrieves the push token for the user if available and sends it back to the user.
process_local_iq(#iq{from = #jid{luser = User, lserver = Server}, type = get, lang = Lang, to = _Host} = IQ) ->
    ?DEBUG("Processing local iq ~p", [IQ]),
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
process_local_iq(#iq{from = #jid{luser = User, lserver = Server}, type = set, lang = Lang, to = _Host,
                 sub_els = [#push_register{push_token = {Os, Token}}]} = IQ) ->
    ?DEBUG("Processing local iq ~p", [IQ]),
    case Token of
        <<>> ->
            Txt = ?T("Invalid value for token."),
            xmpp:make_error(IQ, xmpp:err_bad_request(Txt, Lang));
        _ELse ->
            Timestamp = convert_timestamp_to_binary(erlang:timestamp()),
            case mod_push_notifications_mnesia:register_push({User, Server}, Os, Token, Timestamp) of
                {ok, _} ->
                    xmpp:make_iq_result(IQ);
                {error, _} ->
                    Txt = ?T("Database failure"),
                    xmpp:make_error(IQ, xmpp:err_internal_server_error(Txt, Lang))
            end
    end.


%% handle_message is the hook that is invoked on the event 'offline_message_hook'.
-spec handle_message({any(), #message{}}) -> {any(), #message{}}.
%% Currently ignoring types, but probably need to handle different types separately!
handle_message({_, #message{} = Message} = Acc) ->
    ?DEBUG("Handling Offline message ~p", [Message]),
    _Pid = spawn(mod_push_notifications, handle_push_message, [Message]),
    ?DEBUG("Spawning a separate process to send a push notification ~p", [Message]),
    Acc.

%% Handles the push message: determines the os for the user and sends a request to either fcm or apns accordingly.
-spec handle_push_message(#message{}) -> ok | error.
handle_push_message(#message{from = From, to = To} = Message) ->
    JFrom = jid:encode(jid:remove_resource(From)),
    _JTo = jid:encode(jid:remove_resource(To)),
    ToUser = To#jid.luser,
    ToServer = To#jid.lserver,
    {Subject, Body} = parse_message(Message),
    ?DEBUG("Obtaining push token for user: ~p", [To]),
    case mod_push_notifications_mnesia:list_push_registrations({ToUser, ToServer}) of
        {ok, none} ->
            ?DEBUG("No push token available for user: ~p", [To]),
            ok;
        {ok, {{ToUser, ToServer}, Os, Token, _Timestamp}} ->
            case Os of
                <<"ios">> ->
                    ?DEBUG("Trying to send an ios push notification for user: ~p through apns", [To]),
                    send_apns_push_notification(JFrom, {ToUser, ToServer}, Subject, Body, Token);
                <<"android">> ->
                    ?DEBUG("Trying to send an android push notification for user: ~p through fcm", [To]),
                    send_fcm_push_notification(JFrom, {ToUser, ToServer}, Subject, Body, Token);
                _ ->
                    ?ERROR_MSG("Invalid OS: ~p and token for the user: ~p ~p", [Os, ToUser, ToServer]),
                    ok
            end;
        {error, _} ->
            error
    end.

%% Sends an apns push notification to the user with a subject and body using that token of the user.
%% Using the legacy binary API for now: link below for details
%% [https://developer.apple.com/library/archive/documentation/NetworkingInternet/Conceptual/RemoteNotificationsPG/BinaryProviderAPI.html#//apple_ref/doc/uid/TP40008194-CH13-SW1]
%% TODO(murali@): switch to the modern API soon.
-spec send_apns_push_notification(binary(), {binary(), binary()}, binary(), binary(), binary()) -> ok.
send_apns_push_notification(_From, Username, Subject, Body, Token) ->
    ApnsGateway = get_apns_gateway(),
    ApnsCertfile = get_apns_certfile(),
    ApnsPort = get_apns_port(),
    Options = [{certfile, ApnsCertfile},
               {mode, binary}],
    Payload = lists:append(["{\"aps\":",
                                        "{\"alert\":",
                                                        "{\"title\":\"", binary_to_list(Subject), "\","
                                                        "\"body\":\"", binary_to_list(Body), "\"",
                                                        "},",
                                        "\"sound\":\"default\",",
                                        "\"content-available\":\"1\",",
                            "}}"]),
    case ssl:connect(ApnsGateway, ApnsPort, Options, ?SSL_TIMEOUT) of
        {ok, Socket} ->
            PayloadBin = list_to_binary(Payload),
            PayloadLength = size(PayloadBin),
            %% Token length is hardcoded for now.
            TokenLength = 32,
            TokenNum = erlang:binary_to_integer(Token, 16),
            TokenBin = <<TokenNum:TokenLength/integer-unit:8>>,
            %% Packet structure is described in the link above for binary API in APNS.
            Frame =
             <<1:1/unit:8, TokenLength:2/unit:8, TokenBin/binary,
               2:1/unit:8, PayloadLength:2/unit:8, PayloadBin/binary,
               5:1/unit:8, 1:16/big, ?APNS_MESSAGE_PRIORITY:8>>,
            FrameLength = size(Frame),
            Packet = <<2:1/unit:8, FrameLength:4/unit:8, Frame/binary>>,
            Result = ssl:send(Socket, Packet),
            case Result of
                ok ->
                    ?DEBUG("Successfully sent payload to the APNS server, result: ~p for the user: ~p", [Result, Username]);
                {error, Reason} ->
                    ?ERROR_MSG("Failed sending a push notification to the APNS server: ~p, reason: ~p", [Username, Reason]),
                    ?DEBUG("No logic to retry yet!!", [])
            end,
            ssl:close(Socket);
            %%%%%%%%%%%%%%%%%%%%%%%%%%%%
            %% Add logic to handle errors!!
            %%%%%%%%%%%%%%%%%%%%%%%%%%%%
        {error, Reason} = Err ->
            ?ERROR_MSG("Unable to connect to the APNS server: ~s for the user: ~p", [ssl:format_error(Reason), Username]),
            Err
    end.

%% Sends an fcm push notification to the user with a subject and body using that token of the user.
-spec send_fcm_push_notification(binary(), {binary(), binary()}, binary(), binary(), binary()) -> ok.
send_fcm_push_notification(_From, Username, Subject, Body, Token) ->
    %%%%%%%%%%%%%%%%%%%%%%%%%%%%
    %% Set timeout options here.
    %%%%%%%%%%%%%%%%%%%%%%%%%%%%
    HTTPOptions = [],
    Options = [],
    FcmGateway = get_fcm_gateway(),
    FcmApiKey = get_fcm_apikey(),
    Payload = [{body, Body}, {title, Subject}],
    PushMessage = {[{to,           Token},
                    {priority,     <<"high">>},
                    {data, {Payload}}
                   ]},
    Request = {FcmGateway, [{"Authorization", "key="++FcmApiKey}], "application/json", jiffy:encode(PushMessage)},
    Response = httpc:request(post, Request, HTTPOptions, Options),
    case Response of
        {ok, {{_, StatusCode5xx, _}, _, ResponseBody}} when StatusCode5xx >= 500, StatusCode5xx < 600 ->
            ?DEBUG("recoverable FCM error: ~p", [ResponseBody]),
            ?ERROR_MSG("Failed sending a push notification to user immediately: ~p, reason: ~p", [Username, ResponseBody]),
            ?DEBUG("No logic to retry yet!!", []);
            %%%%%%%%%%%%%%%%%%%%%%%%%%%%
            %% Add logic to retry again!!
            %%%%%%%%%%%%%%%%%%%%%%%%%%%%
        {ok, {{_, 200, _}, _, ResponseBody}} ->
            case parse_response(ResponseBody) of
                ok ->
                    ?DEBUG("Successfully sent a push notification to user: ~p, should receive it soon.", [Username]),
                    ok;
                _ ->
                    ?ERROR_MSG("Failed sending a push notification to user: ~p, token: ~p, reason: ~p", [Username, Token, ResponseBody]),
                    ?DEBUG("No logic to retry yet!!", []),
                    mod_push_notifications:unregister_push(Username)
                    %%%%%%%%%%%%%%%%%%%%%%%%%%%%
                    %% Add logic to retry again if possible!!
                    %%%%%%%%%%%%%%%%%%%%%%%%%%%%
            end;
        {ok, {{_, _, _}, _, ResponseBody}} ->
            ?DEBUG("non-recoverable FCM error: ~p", [ResponseBody]),
            ?DEBUG("No logic to retry yet!!", []);
            %%%%%%%%%%%%%%%%%%%%%%%%%%%%
            %% Add logic to retry again if possible!!
            %%%%%%%%%%%%%%%%%%%%%%%%%%%%
        {error, Reason} ->
            ?ERROR_MSG("Failed sending a push notification to user immediately: ~p, reason: ~p", [Username, Reason]),
            ?DEBUG("No logic to retry yet!!", [])
            %%%%%%%%%%%%%%%%%%%%%%%%%%%%
            %% Add logic to retry again if possible!!
            %%%%%%%%%%%%%%%%%%%%%%%%%%%%
    end.


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
                    ?ERROR_MSG("FCM error: NotRegistered, unregistered user", []),
                    not_registered;
                <<"InvalidRegistration">> ->
                    ?ERROR_MSG("FCM error: InvalidRegistration, unregistered user", []),
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
                                                   timestamp = _Timestamp,
                                                   publisher = ItemPublisher,
                                                   sub_els = _ItemPayload}]} ->
                            {<<"New Message">>, ItemPublisher};
                        _ ->
                            {<<"New Message">>, <<"">>}
                    end;
                _ ->
                    {<<"New Message">>, <<"">>}
            end
    end.


%% Store the necessary options with persistent_term. [https://erlang.org/doc/man/persistent_term.html]
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

%% Combines the MegaSec and Seconds part of the timestamp into a binary and returns it.
-spec convert_timestamp_to_binary(erlang:timestamp()) -> binary().
convert_timestamp_to_binary(Timestamp) ->
    {T1, T2, _} = Timestamp,
    list_to_binary(integer_to_list(T1)++integer_to_list(T2)).


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

