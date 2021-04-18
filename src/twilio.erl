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
    send_voice_call/2,
    fetch_message_info/1,
    normalized_status/1,
    compose_body/2  % for debugging.
]).


-type compose_body_fun() :: fun((phone(), string()) -> string()).

-spec send_sms(Phone :: phone(), Msg :: string()) -> {ok, gateway_response()} | {error, sms_fail}.
send_sms(Phone, Msg) ->
    sending_helper(Phone, Msg, ?BASE_SMS_URL, fun compose_body/2, "SMS").

-spec send_voice_call(Phone :: phone(), Msg :: string()) -> {ok, gateway_response()} | {error, voice_call_fail}.
send_voice_call(Phone, Msg) ->
    sending_helper(Phone, Msg, ?BASE_VOICE_URL, fun compose_voice_body/2, "Voice Call").

-spec sending_helper(Phone :: phone(), Msg :: string(), BaseUrl :: string(),
    ComposeBodyFn :: compose_body_fun(), Purpose :: string()) -> {ok, gateway_response()} | {error, atom()}.
sending_helper(Phone, Msg, BaseUrl, ComposeBodyFn, Purpose) ->
    ?INFO("Phone: ~p, Msg: ~p, Purpose: ~p", [Phone, Msg, Purpose]),
    Headers = fetch_auth_headers(),
    Type = "application/x-www-form-urlencoded",
    Body = ComposeBodyFn(Phone, Msg),
    ?DEBUG("Body: ~p", [Body]),
    HTTPOptions = [],
    Options = [],
    Response = httpc:request(post, {BaseUrl, Headers, Type, Body}, HTTPOptions, Options),
    ?DEBUG("Response: ~p", [Response]),
    case Response of
        {ok, {{_, 201, _}, _ResHeaders, ResBody}} ->
            Json = jiffy:decode(ResBody, [return_maps]),
            Id = maps:get(<<"sid">>, Json),
            Status = normalized_status(maps:get(<<"status">>, Json)),
            {ok, #gateway_response{gateway_id = Id, status = Status, response = ResBody}};
        _ ->
            ?ERROR("Sending ~p failed ~p", [Purpose, Response]),
            {error, list_to_atom(re:replace(string:lowercase(Purpose), " ", "_", [{return, list}]) ++ "_fail")}
    end.

-spec normalized_status(Status :: binary()) -> atom().
normalized_status(<<"accepted">>) ->
    accepted;
normalized_status(<<"queued">>) ->
    queued;
normalized_status(<<"sending">>) ->
    sending;
normalized_status(<<"sent">>) ->
    sent;
normalized_status(<<"delivered">>) ->
    delivered;
normalized_status(<<"delivery_unknown">>) ->
    undelivered;
normalized_status(<<"undelivered">>) ->
    undelivered;
normalized_status(<<"failed">>) ->
    failed;
normalized_status(_) ->
    unknown.


-spec fetch_message_info(SMSId :: binary()) -> {ok, gateway_response()} | {error, sms_fail}.
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
            {ok, #gateway_response{gateway_id = Id, gateway = twilio, method = sms,
                status = normalized_status(Status), price = RealPrice, currency = Currency}};
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


-spec encode_based_on_country(Phone :: phone(), Msg :: string()) -> string().
encode_based_on_country(Phone, Msg) ->
    case mod_libphonenumber:get_cc(Phone) of
        <<"CN">> -> "【 HALLOAPP】" ++ Msg;
        _ -> Msg
    end.


-spec compose_body(Phone :: phone(), Message :: string()) -> uri_string:uri_string().
compose_body(Phone, Message) ->
    Message2 = encode_based_on_country(Phone, Message),
    PlusPhone = "+" ++ binary_to_list(Phone),
    uri_string:compose_query([
        {"To", PlusPhone },
        {"From", ?FROM_PHONE},
        {"Body", Message2},
        {"StatusCallback", ?TWILIOCALLBACK_URL}
    ], [{encoding, utf8}]).

-spec encode_to_twiml(Msg :: string()) -> string().
encode_to_twiml(Msg) ->
    "<Response><Say>" ++ Msg ++ "</Say></Response>".

-spec compose_voice_body(Phone :: phone(), Message :: string()) -> uri_string:uri_string().
compose_voice_body(Phone, Message) ->
    %% TODO(vipin): Add voice callback.
    Message2 = encode_to_twiml(Message),
    PlusPhone = "+" ++ binary_to_list(Phone),
    uri_string:compose_query([
        {"To", PlusPhone },
        {"From", ?FROM_PHONE},
        {"Twiml", Message2}
    ], [{encoding, utf8}]).


