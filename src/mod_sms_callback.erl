%%%-------------------------------------------------------------------
%%% @copyright (C) 2020, HalloApp, Inc.
%%% @doc
%%% HTTP API module for SMS callback.
%%% @end
%%%-------------------------------------------------------------------
-module(mod_sms_callback).
-author("vipin").
-behaviour(gen_mod).


-include("time.hrl").
-include("logger.hrl").
-include("ejabberd_http.hrl").
-include("util_http.hrl").
-include("twilio.hrl").
-include("sms.hrl").

-define(CALLBACK_DELAY, 10 * ?SECONDS_MS).

% called after
-export([add_gateway_callback_info/1, add_gateway_callback_info/2]).

%% API
-export([start/2, stop/1, reload/3, init/1, depends/2, mod_options/1]).
-export([process/2]).

%%%----------------------------------------------------------------------
%%% API
%%%----------------------------------------------------------------------


% https://api.halloapp.net/api/smscallback/twilio
% https://www.twilio.com/docs/usage/security#validating-requests
process([<<"twilio">>],
        #request{method = 'POST', data = Data, ip = IP, headers = Headers}) ->
    try
        ClientIP = util_http:get_ip(IP, Headers),
        UserAgent = util_http:get_user_agent(Headers),
        ?INFO("Twilio SMS callback: data: ~p ip: ~s ua: ~s headers: ~p", [Data, ClientIP, UserAgent, Headers]),
        QueryList = uri_string:dissect_query(Data),
        Id = proplists:get_value(<<"SmsSid">>, QueryList),
        To = proplists:get_value(<<"To">>, QueryList),
        From = proplists:get_value(<<"From">>, QueryList),
        Status = twilio:normalized_status(proplists:get_value(<<"SmsStatus">>, QueryList)),
        TwilioSignature = util_http:get_header(<<"X-Twilio-Signature">>, Headers),
        {SMSPrice, SMSCurrency} = case TwilioSignature of
            undefined -> {undefined, <<"null">>};
            _ ->
                SortedQP = lists:keysort(1, QueryList),
                Q = [[Key, Value] || {Key, Value} <- SortedQP],
                Url = lists:flatten(?TWILIOCALLBACK_URL, Q),
                AuthToken = mod_aws:get_secret_value(<<"TwilioMaster">>, <<"auth_token">>),
                DerivedSignature = base64:encode(crypto:mac(hmac, sha, AuthToken, Url)),
                IsSigEqual = (TwilioSignature =:= DerivedSignature),
                ?DEBUG("Twilio signature: ~s DerivedSignature: ~s Match: ~p",
                    [TwilioSignature, DerivedSignature, IsSigEqual]),
                SMSResponse2 = case {IsSigEqual, Status} of
                    {true, sent} ->
                        case twilio:fetch_message_info(Id) of
                            {ok, SMSResponse} -> SMSResponse#gateway_response{status = Status};
                            {error, _} -> #gateway_response{gateway_id = Id, gateway = twilio}
                        end;
                    {true, _} -> #gateway_response{gateway_id = Id, gateway = twilio, status = Status};
                    _ -> #gateway_response{gateway_id = Id, gateway = twilio}
                end,
                add_gateway_callback_info(SMSResponse2),
                #gateway_response{price = Price, currency = Currency} = SMSResponse2,
                {Price, Currency}
        end,
        ?INFO("Twilio SMS callback, Id: ~s To: ~s From: ~s Status: ~p Price: ~p Currency: ~s",
            [Id, To, From, Status, SMSPrice, SMSCurrency]),
        {200, ?HEADER(?CT_JSON), jiffy:encode({[{result, ok}]})}
    catch
        error : Reason : Stacktrace  ->
            ?ERROR("Twilio SMS callback error: ~p, ~p", [Reason, Stacktrace]),
            util_http:return_500()
    end;

% Reference: https://developers.messagebird.com/api/sms-messaging/#handle-a-status-report
% https://developers.messagebird.com/api/#what-is-request-signing?
process([<<"mbird">>],
        #request{method = 'GET', q = Q, ip = IP, headers = Headers}) ->
    try
        ClientIP = util_http:get_ip(IP, Headers),
        UserAgent = util_http:get_user_agent(Headers),
        ?INFO("MessageBird SMS callback: Query:~p ip:~s ua:~s, headers:~p", [Q, ClientIP, UserAgent, Headers]),
        Id = proplists:get_value(<<"id">>, Q),
        Recipient = proplists:get_value(<<"recipient">>, Q),
        Status = mbird:normalized_status(proplists:get_value(<<"status">>, Q)),
        Price = binary_to_list(proplists:get_value(<<"price[amount]">>, Q, <<>>)),
        RealPrice = case string:to_float(Price) of
            {error, _} -> undefined;
            {RealPrice2, []} -> RealPrice2
        end,
        Currency = proplists:get_value(<<"price[currency]">>, Q),
        MBirdSignature = util_http:get_header(<<"Messagebird-Signature">>, Headers),
        MBirdTimestamp = util_http:get_header(<<"Messagebird-Request-Timestamp">>, Headers),
        case {MBirdSignature, MBirdTimestamp} of
            {undefined, _} -> ok;
            {_, undefined} -> ok;
            {_, _} ->
                SortedQP = lists:keysort(1, Q),
                SortedQ = uri_string:compose_query(SortedQP),
                %% The body empty for the 'GET' request.
                Request = [binary_to_list(MBirdTimestamp), $\n, binary_to_list(SortedQ), $\n, crypto:hash(sha256, <<"">>)],
                FlatRequest = lists:flatten(Request),
                SignatureKey = mod_aws:get_secret_value(<<"MBird">>, <<"signing_key">>),
                DerivedSignature = base64:encode(
                    crypto:mac(hmac, sha256, SignatureKey, FlatRequest)),
                IsSigEqual = (MBirdSignature =:= DerivedSignature),
                ?DEBUG("MessageBird signature: ~s, DerivedSignature: ~s, Match: ~p",
                    [MBirdSignature, DerivedSignature, IsSigEqual]),
                case IsSigEqual andalso Status =/= undefined of
                    true ->
                        add_gateway_callback_info(
                            #gateway_response{gateway_id = Id, gateway = mbird, status = Status,
                            price = RealPrice, currency = Currency});
                    false -> ok
                end
        end,
        ?INFO("MessageBird SMS callback, Id: ~s, To: ~s, Status: ~p, Price: ~p, Currency: ~s",
            [Id, Recipient, Status, RealPrice, Currency]),
        {200, ?HEADER(?CT_JSON), jiffy:encode({[{result, ok}]})}
    catch
        error : Reason : Stacktrace  ->
            ?ERROR("MessageBird SMS callback error: ~p, ~p", [Reason, Stacktrace]),
            util_http:return_500()
    end;

% https://api.halloapp.net/api/smscallback/vonage
%% https://developer.nexmo.com/concepts/guides/webhooks
%% https://developer.nexmo.com/messaging/sms/guides/delivery-receipts
%% Example Receipt:
%%{
%%    "msisdn": "12066585586",
%%    "to": "18445443434",
%%    "network-code": "310260",
%%    "messageId": "15000001FDB8525C",
%%    "price": "0.00828000",
%%    "status": "delivered",
%%    "scts": "2109022321",
%%    "err-code": "0",
%%    "api-key": "77939d62",
%%    "message-timestamp": "2021-09-02 23:21:22"
%%}
process([<<"vonage">>],
    #request{method = 'POST', data = Data, ip = IP, headers = Headers} = Request) ->
    try
        ClientIP = util_http:get_ip(IP, Headers),
        UserAgent = util_http:get_user_agent(Headers),
        ?INFO("Vonage SMS callback: Data:~p ip:~s ua:~s, headers:~p",
            [Data, ClientIP, UserAgent, Headers]),
        Payload = jiffy:decode(Data, [return_maps]),
        MsgId = maps:get(<<"messageId">>, Payload),
        Phone = maps:get(<<"msisdn">>, Payload),
        MCCMNC = maps:get(<<"network-code">>, Payload, undefined),
        RealStatus = maps:get(<<"status">>, Payload),
        Status = vonage:normalized_status(RealStatus),
        ErrCode = maps:get(<<"err-code">>, Payload),
        Price = binary_to_list(maps:get(<<"price">>, Payload)),
        RealPrice = case string:to_float(Price) of
            {error, _} -> undefined;
            {RealPrice2, []} -> RealPrice2
        end,
        Currency = <<"EUR">>,
        ?INFO("Delivery receipt Vonage: Phone: ~s Status: ~s MsgId:~s ErrCode:~s MCCMNC:~s Price:~p(~s)",
            [Phone, RealStatus, MsgId, ErrCode, MCCMNC, RealPrice, Currency]),
        add_gateway_callback_info(
            #gateway_response{gateway_id = MsgId, gateway = vonage, status = Status,
                price = RealPrice, currency = Currency}),
        {200, ?HEADER(?CT_JSON), jiffy:encode({[{result, ok}]})}
    catch
        error : Reason : Stacktrace  ->
            ?ERROR("Vonage SMS callback error: ~p, ~p~nRequest:~p", [Reason, Stacktrace, Request]),
            util_http:return_500()
    end;

%%https://www.infobip.com/docs/api#channels/sms/receive-outbound-sms-message-report
%%https://www.infobip.com/docs/essentials/response-status-and-error-codes
%%{
%%    "bulkId": "BULK-ID-123-xyz",
%%    "messageId": "12db39c3-7822-4e72-a3ec-c87442c0ffc5",
%%    "to": "41793026834",
%%    "sentAt": "2019-11-09T17:00:00.000+0000",
%%    "doneAt": "2019-11-09T17:00:00.000+0000",
%%    "smsCount": 1,
%%    "price": {
%%        "pricePerMessage": 0.01,
%%        "currency": "EUR"
%%    },
%%    "status": {
%%        "groupId": 3,
%%        "groupName": "DELIVERED",
%%        "id": 5,
%%        "name": "DELIVERED_TO_HANDSET",
%%        "description": "Message delivered to handset"
%%    },
%%    "error": {
%%        "groupId": 0,
%%        "groupName": "Ok",
%%        "id": 0,
%%        "name": "NO_ERROR",
%%        "description": "No Error",
%%        "permanent": false
%%    }
%%}
process([<<"infobip">>],
    #request{method = 'POST', data = Data, ip = IP, headers = Headers} = Request) ->
    try
        ClientIP = util_http:get_ip(IP, Headers),
        UserAgent = util_http:get_user_agent(Headers),
        ?INFO("Infobip SMS callback: Data:~p ip:~s ua:~s, headers:~p",
            [Data, ClientIP, UserAgent, Headers]),
        DataJson = jiffy:decode(Data, [return_maps]),
        Results = maps:get(<<"results">>, DataJson),
        % Response from infobip is array. We expect just one item. If we get more or less make it
        % error to investigate
        Payload = case Results of
            [] -> erlang:error({badarg, {empty_payload, Data}});
            [OnePayload] -> OnePayload;
            [_FirstPayload | _Rest] -> erlang:error({badarg, {multi_item_payload, Data}})
        end,
        MsgId = maps:get(<<"messageId">>, Payload),
        Phone = maps:get(<<"to">>, Payload),
        StatusObj = maps:get(<<"status">>, Payload, #{}),
        RealStatusGroup = maps:get(<<"groupName">>, StatusObj, undefined),
        RealStatus = maps:get(<<"name">>, StatusObj, undefined),
        Status = infobip:normalized_status(RealStatusGroup),
        ErrorObj = maps:get(<<"error">>, Payload, #{}),
        ErrorGroup = maps:get(<<"groupName">>, ErrorObj, undefined),
        ErrorName = maps:get(<<"name">>, ErrorObj, undefined),
        ErrorDesc = maps:get(<<"description">>, ErrorObj, undefined),
        RealPrice = maps:get(<<"pricePerMessage">>, maps:get(<<"price">>, Payload, #{}), none),
        Currency = maps:get(<<"currency">>, maps:get(<<"price">>, Payload, #{}), <<"EUR">>),

        ?INFO("Delivery receipt Infobip: Phone:~s Status:~s:~s MsgId:~s Price:~p(~s)",
            [Phone, RealStatusGroup, RealStatus, MsgId, RealPrice, Currency]),
        case ErrorGroup of
            <<"Ok">> -> ok;
            % Only print error if it is an error
            _ -> ?INFO("Delivery receipt Infobip Error: Phone:~s Status:~s MsgId:~s ~s:~s ~s",
                [Phone, RealStatusGroup, MsgId, ErrorGroup, ErrorName, ErrorDesc])
        end,

        add_gateway_callback_info(
            #gateway_response{gateway_id = MsgId, gateway = infobip, status = Status,
                price = RealPrice, currency = Currency}),
        {200, ?HEADER(?CT_JSON), jiffy:encode({[{result, ok}]})}
    catch
        error : Reason : Stacktrace  ->
            ?ERROR("Infobip SMS callback error: ~p, ~p~nRequest:~p", [Reason, Stacktrace, Request]),
            util_http:return_500()
    end;

%% https://docs.clickatell.com/archive/channels/advanced-message-send-archived/callback-push-status-and-cost-notification/
%% {
%% "data": {
%% "apiId": 105511,
%% "apiMessageId": "b61bef4ab5aeb2770607c1c49721b440",
%% "clientMessageId": "",
%% "timestamp": 1437470173,
%% "to": "27999044453",
%% "from": "",
%% "charge": 2.0,
%% "messageStatus": "004"
%% }
%% }
%% Clickatell tests validity of the callback by using HTTP GET.
process([<<"clickatell">>],
        #request{method = 'GET', q = Q, ip = IP, headers = Headers}) ->
    ?INFO("Clickatell SMS callback, Http Get, q: ~p, IP: ~p, Headers: ~p",
        [Q, IP, Headers]),
    {200, ?HEADER(?CT_JSON), jiffy:encode({[{result, ok}]})};

process([<<"clickatell">>],
    #request{method = 'POST', data = Data, ip = IP, headers = Headers} = Request) ->
    try
        ClientIP = util_http:get_ip(IP, Headers),
        UserAgent = util_http:get_user_agent(Headers),
        ?INFO("Clickatell SMS callback: Data:~p ip:~s ua:~s, headers:~p",
            [Data, ClientIP, UserAgent, Headers]),
        Payload = jiffy:decode(Data, [return_maps]),
        Data2 = maps:get(<<"data">>, Payload),
        ApiId = maps:get(<<"apiId">>, Data2),
        MessageId = maps:get(<<"apiMessageId">>, Data2),
        Timestamp = maps:get(<<"timestamp">>, Data2),
        To = maps:get(<<"to">>, Data2),
        Charge = util:to_float_maybe(maps:get(<<"charge">>, Data2)),
        Currency = <<"TBD">>,
        Status = util:to_integer_maybe(maps:get(<<"messageStatus">>, Data2)),
        Status2 = clickatell:normalized_status(Status),
        ?INFO("Delivery receipt Clickatell: Phone(to): ~s Status: ~p "
              "Status2: ~p MessageId: ~s Charge: ~p ApiId: ~p Timestamp: ~p",
            [To, Status, Status2, MessageId, Charge, ApiId, Timestamp]),
        add_gateway_callback_info(
            #gateway_response{gateway_id = MessageId, gateway = clickatell, status = Status2,
                price = Charge, currency = Currency}),
        {200, ?HEADER(?CT_JSON), jiffy:encode({[{result, ok}]})}
    catch
        error : Reason : Stacktrace  ->
            ?ERROR("Clickatell SMS callback error: ~p, ~p~nRequest:~p", [Reason, Stacktrace, Request]),
            util_http:return_500()
    end;

%% https://enterprise.telesign.com/api-reference/apis/sms-verify-api/reference/callback-service
%% POST /callback_endpoint HTTP/1.1
%% Host: your-callback-url.com
%% { 
%%   "status": { 
%%      "updated_on": "2016-07-08T20:52:46.417428Z", 
%%      "code": 200, 
%%      "description": "Delivered to handset" 
%%    }, 
%%    "submit_timestamp": "2016-07-08T20:52:41.203000Z", 
%%    "errors": [], 
%%    "reference_id": "2557312299CC1304904080F4BE17BFB4",
%%    "verify": { 
%%      "code_state": "UNKNOWN", 
%%      "code_entered": null 
%%    }, 
%%    "sub_resource": "sms", 
%%    "additional_info": {
%%     "message_parts_count": 1,
%%     "price": "0.5112",
%%     "mnc": "03",
%%     "mcc": "220",
%%     "currency": "USD"
%%   }
%% }
process([<<"telesign">>],
    #request{method = 'POST', data = Data, ip = IP, headers = Headers} = Request) ->
    try
        ClientIP = util_http:get_ip(IP, Headers),
        UserAgent = util_http:get_user_agent(Headers),
        ?INFO("Telesign SMS callback: Data:~p ip:~s ua:~s, headers:~p",
            [Data, ClientIP, UserAgent, Headers]),
        Payload = jiffy:decode(Data, [return_maps]),
        StatusMap = maps:get(<<"status">>, Payload),
        StatusCode = maps:get(<<"code">>, StatusMap),
        Status = telesign:normalized_status(StatusCode),
        StatusDescription = maps:get(<<"description">>, StatusMap),
        ReferenceId = maps:get(<<"reference_id">>, Payload),
        AdditionalInfo = maps:get(<<"additional_info">>, Payload),
        Price = util:to_float_maybe(maps:get(<<"price">>, AdditionalInfo)),
        Currency = maps:get(<<"currency">>, AdditionalInfo),
        Mnc = maps:get(<<"mnc">>, AdditionalInfo),
        Mcc = maps:get(<<"mcc">>, AdditionalInfo),
        SubmitTimestamp = maps:get(<<"submit_timestamp">>, Payload),
        %% TODO(vipin): Need to check auth to make sure we get legitimate callbacks.
        ?INFO("Delivery receipt Telesign: Status: ~p StatusDescr: ~s MsgId: ~s Price: ~p(~s) "
            "Mnc: ~s Mcc: ~s SubmitTimestamp: ~s",
            [Status, StatusDescription, ReferenceId, Price, Currency, Mnc, Mcc, SubmitTimestamp]),
        add_gateway_callback_info(
            #gateway_response{gateway_id = ReferenceId, gateway = telesign, status = Status,
                price = Price, currency = Currency}),
        {200, ?HEADER(?CT_JSON), jiffy:encode({[{result, ok}]})}
    catch
        error : Reason : Stacktrace  ->
            ?ERROR("Telesign SMS callback error: ~p, ~p~nRequest:~p", [Reason, Stacktrace, Request]),
            util_http:return_500()
    end;


process(Path, Request) ->
    ?INFO("404 Not Found path: ~p, r:~p", [Path, Request]),
    util_http:return_404().


%% It turns out the gateway can sometimes give us callback at the same time
%% when responding to our request. Both these run on separate processes.
%% There is a race condition between storing our request and the callback.
%% So, we inject a manual delay here to ensure it works fine.
%% TODO: it would be better to change this datastructure - needs more migration work.
-spec add_gateway_callback_info(SMSResponse :: gateway_response()) -> ok.
add_gateway_callback_info(SMSResponse) ->
    add_gateway_callback_info(SMSResponse, 0).

-spec add_gateway_callback_info(SMSResponse :: gateway_response(), Retries :: integer()) -> ok.
add_gateway_callback_info(SMSResponse, Retries) when Retries > 2 ->
    ?WARNING("Failed to store receipt ~p", [SMSResponse]),
    ok;
add_gateway_callback_info(SMSResponse, Retries) ->
    #gateway_response{status = Status} = SMSResponse,
    {ok, VerificationAttemptKey} = model_phone:get_verification_attempt_key(SMSResponse),
    case {Status, VerificationAttemptKey} of
        {undefined, _} -> ok;
        {_, undefined} ->
            timer:apply_after(?CALLBACK_DELAY, ?MODULE, add_gateway_callback_info, [SMSResponse, Retries + 1]);
        _ ->
            model_phone:add_gateway_callback_info(SMSResponse)
    end,
    ok.

start(Host, Opts) ->
    ?INFO("start ~w ~p", [?MODULE, Opts]),
    gen_mod:start_child(?MODULE, Host, Opts).

stop(Host) ->
    ?INFO("stop ~w", [?MODULE]),
    gen_mod:stop_child(?MODULE, Host).

reload(_Host, _NewOpts, _OldOpts) ->
    ok.

depends(_Host, _Opts) ->
    [{mod_sms, hard}].

init(_Stuff) ->
    ?INFO("mod_sms_callback init ~p", [_Stuff]),
    {ok, {}}.

-spec mod_options(binary()) -> [{atom(), term()}].
mod_options(_Host) ->
    [].
