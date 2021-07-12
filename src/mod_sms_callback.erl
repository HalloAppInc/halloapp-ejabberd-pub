%%%-------------------------------------------------------------------
%%% @copyright (C) 2020, HalloApp, Inc.
%%% @doc
%%% HTTP API module for SMS callback.
%%% @end
%%%-------------------------------------------------------------------
-module(mod_sms_callback).
-author("vipin").
-behaviour(gen_mod).

%% Export all functions for unit tests
-ifdef(TEST).
-compile(export_all).
-endif.

-include("time.hrl").
-include("logger.hrl").
-include("ejabberd_http.hrl").
-include("util_http.hrl").
-include("twilio.hrl").
-include("sms.hrl").

-define(CALLBACK_DELAY, 10 * ?SECONDS_MS).


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
        ?INFO("Twilio SMS callback: data:~p ip:~s ua:~s, headers:~p", [Data, ClientIP, UserAgent, Headers]),
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
                Json = jiffy:decode(binary_to_list(mod_aws:get_secret(<<"TwilioMaster">>)), [return_maps]),
                DerivedSignature = base64:encode(
                    crypto:hmac(sha, binary_to_list(maps:get(<<"auth_token">>, Json)), Url)),
                IsSigEqual = (TwilioSignature =:= DerivedSignature),
                ?INFO("Twilio signature: ~s, DerivedSignature: ~s, Match: ~p",
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
        ?INFO("Twilio SMS callback, Id: ~s, To: ~s, From: ~s, Status: ~p, Price: ~p, Currency: ~s",
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
        Price = binary_to_list(proplists:get_value(<<"price[amount]">>, Q)),
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
                Json = jiffy:decode(binary_to_list(mod_aws:get_secret(<<"MBird">>)), [return_maps]),
                DerivedSignature = base64:encode(
                    crypto:hmac(sha256, binary_to_list(maps:get(<<"signing_key">>, Json)), FlatRequest)),
                IsSigEqual = (MBirdSignature =:= DerivedSignature),
                ?INFO("MessageBird signature: ~s, DerivedSignature: ~s, Match: ~p",
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
    end.


%% It turns out the gateway can sometimes give us callback at the same time
%% when responding to our request. Both these run on separate processes.
%% There is a race condition between storing our request and the callback.
%% So, we inject a manual delay here to ensure it works fine.
%% TODO: it would be better to change this datastructure - needs more migration work.
-spec add_gateway_callback_info(SMSResponse :: gateway_response()) -> ok.
add_gateway_callback_info(SMSResponse) ->
    #gateway_response{status = Status} = SMSResponse,
    {ok, VerificationAttemptKey} = model_phone:get_verification_attempt_key(),
    case {Status, VerificationAttemptKey} of
        {undefined, _} -> ok;
        {_, undefined} ->
            timer:apply_after(?CALLBACK_DELAY, model_phone, add_gateway_callback_info, [SMSResponse]);
        _ ->
            model_phone:add_gateway_callback_info(SMSResponse)
    end.

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
