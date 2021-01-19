%%%----------------------------------------------------------------------
%%% File    : twilio.erl
%%%
%%% Copyright (C) 2020 halloappinc.
%%%
%%% This module implements API needed to interface with Twilio
%%% various providers.
%%%----------------------------------------------------------------------

-module(twilio).
-behavior(mod_sms).
-author('vipin').
-include("logger.hrl").
-include("twilio.hrl").
-include("ha_types.hrl").
-include("sms.hrl").

-export([
    send_sms/2,
    fetch_message_info/1
]).


-spec send_sms(Phone :: phone(), Msg :: string()) -> {ok, sms_response()} | {error, sms_fail}.
send_sms(Phone, Msg) ->
    ?INFO("~p", [Phone]),
    URL = ?BASE_URL,
    Headers = fetch_auth_headers(),
    Type = "application/x-www-form-urlencoded",
    Body = compose_body(Phone, Msg),
    HTTPOptions = [],
    Options = [],
    Response = httpc:request(post, {URL, Headers, Type, Body}, HTTPOptions, Options),
    ?DEBUG("Response: ~p", [Response]),
    case Response of
        {ok, {{_, 201, _}, _ResHeaders, ResBody}} ->
            %% TODO(vipin): Try to check status and send SMS using another provider if needed.
            Json = jiffy:decode(ResBody, [return_maps]),
            Id = maps:get(<<"sid">>, Json),
            Status = maps:get(<<"status">>, Json),
            {ok, #sms_response{sms_id = Id, status = Status, response = ResBody}};
        _ ->
            %% TODO(vipin): Try sending the SMS using the second provider.
            ?ERROR("Sending SMS failed ~p", [Response]),
            {error, sms_fail}
    end.

-spec fetch_message_info(SMSId :: binary()) -> {ok, sms_response()} | {error, sms_fail}.
fetch_message_info(SMSId) ->
    ?INFO("~p", [SMSId]),
    URL = ?SMS_INFO_URL ++ binary_to_list(SMSId) ++ ".json",
    ?INFO("URL: ~s", [URL]),
    Headers = fetch_auth_headers(),
    HTTPOptions = [],
    Options = [],
    Response = httpc:request(get, {URL, Headers}, HTTPOptions, Options),
    ?DEBUG("Response: ~p", [Response]),
    case Response of
        {ok, {{_, 200, _}, _ResHeaders, ResBody}} ->
            Json = jiffy:decode(ResBody, [return_maps]),
            Id = maps:get(<<"sid">>, Json),
            Status = maps:get(<<"status">>, Json),
            Price = maps:get(<<"price">>, Json),
            RealPrice = case try string:to_float(binary_to_list(Price))
            catch _:_ -> {error, no_float}
            end of
                {error, _} -> undefined;
                {XX, []} -> abs(XX)
            end,
            Currency = maps:get(<<"price_unit">>, Json),
            {ok, #sms_response{sms_id = Id, status = Status, price = RealPrice,
                currency = Currency}};
        _ ->
            ?ERROR("SMS fetch info failed ~p", [Response]),
            {error, sms_fail}
    end.

-spec fetch_tokens() -> {string(), string()}.
fetch_tokens() ->
    Json = jiffy:decode(binary_to_list(mod_aws:get_secret(<<"Twilio">>)), [return_maps]),
    {binary_to_list(maps:get(<<"account_sid">>, Json)),
     binary_to_list(maps:get(<<"auth_token">>, Json))}.


-spec fetch_auth_headers() -> string().
fetch_auth_headers() ->
    {AccountSid, AuthToken} = fetch_tokens(),
    AuthStr = base64:encode_to_string(AccountSid ++ ":" ++ AuthToken),
    [{"Authorization", "Basic " ++ AuthStr}].


-spec compose_body(Phone :: phone(), Message :: string()) -> uri_string:uri_string().
compose_body(Phone, Message) ->
    PlusPhone = "+" ++ binary_to_list(Phone),
    uri_string:compose_query([
        {"To", PlusPhone },
        {"From", ?FROM_PHONE},
        {"Body", Message},
        {"StatusCallback", ?TWILIOCALLBACK_URL}
    ], [{encoding, utf8}]).


