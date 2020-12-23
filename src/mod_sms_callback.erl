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

-include("logger.hrl").
-include("ejabberd_http.hrl").
-include("util_http.hrl").

-define(TWILIO_SMS_CALLBACK_URL, "https://api.halloapp.net/api/smscallback/twilio?").

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
        ?INFO("Twilio SMS callback: r:~p ip:~s ua:~s", [Data, ClientIP, UserAgent]),
        Payload = jiffy:decode(Data, [return_maps]),
        To = maps:get(<<"to">>, Payload),
        From = maps:get(<<"from">>, Payload),
        Status = maps:get(<<"status">>, Payload),
        TwilioSignature = util_http:get_header('X-Twilio-Signature', Headers),
        case TwilioSignature of
            undefined -> ok;
            _ ->
                QueryParams = maps:to_list(Payload),
                SortedQP = lists:keysort(1, QueryParams),
                Q = util_http:convert_to_querystring(SortedQP),
                Url = lists:flatten(?TWILIO_SMS_CALLBACK_URL, Q),
                Json = jiffy:decode(binary_to_list(mod_aws:get_secret(<<"Twilio">>)), [return_maps]),
                DerivedSignature = base64:encode(
                    crypto:hmac(sha, binary_to_list(maps:get(<<"auth_token">>, Json)), Url)),
                IsSigEqual = (TwilioSignature =:= DerivedSignature),
                ?INFO("Twilio signature: ~s, DerivedSignature: ~s, Match: ~p",
                    [TwilioSignature, DerivedSignature, IsSigEqual])
        end,
        ?INFO("Twilio SMS callback, To: ~s, From: ~s, Status: ~s", [To, From, Status]),
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
        ?INFO("MessageBird SMS callback: Query:~p ip:~s ua:~s", [Q, ClientIP, UserAgent]),
        Id = proplists:get_value(<<"id">>, Q),
        Recipient = proplists:get_value(<<"recipient">>, Q),
        Status = proplists:get_value(<<"status">>, Q),
        MBirdSignature = util_http:get_header('MessageBird-Signature', Headers),
        MBirdTimestamp = util_http:get_header('MessageBird-Timestamp', Headers),
        case {MBirdSignature, MBirdTimestamp} of
            {undefined, _} -> ok;
            {_, undefined} -> ok;
            {_, _} ->
                SortedQP = lists:keysort(1, Q),
                SortedQ = uri_string:compose_query(SortedQP),
                %% The body empty for the 'GET' request.
                Request = [MBirdTimestamp, $\n, SortedQ, $\n, crypto:hash(sha256, <<"">>)],
                FlatRequest = lists:flatten(Request),
                DerivedSignature = base64:encode(
                    crypto:hmac(sha256, mod_aws:get_secret(<<"MBird">>), FlatRequest)),
                IsSigEqual = (MBirdSignature =:= DerivedSignature),
                ?INFO("MessageBird signature: ~s, DerivedSignature: ~s, Match: ~p",
                    [MBirdSignature, DerivedSignature, IsSigEqual])
        end,
        ?INFO("MessageBird SMS callback, Id: ~s, To: ~s, Status: ~s", [Id, Recipient, Status]),
        {200, ?HEADER(?CT_JSON), jiffy:encode({[{result, ok}]})}
    catch
        error : Reason : Stacktrace  ->
            ?ERROR("MessageBird SMS callback error: ~p, ~p", [Reason, Stacktrace]),
            util_http:return_500()
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
