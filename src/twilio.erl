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


-define(TWILIO_ENG_LANG_ID, "en-US").

%% TODO(vipin): Maybe improve Msg for voice_call. Talk to Dugyu.
%% TODO: optimize calls for get_lang_id.

-export([
    init/0,
    can_send_sms/1,
    can_send_voice_call/1,
    send_sms/4,
    send_voice_call/4,
    fetch_message_info/1,
    normalized_status/1,
    send_feedback/2,
    compose_body/3,     %% for debugging.
    compose_voice_body/3    %% for debugging
]).

init() ->
    FromPhoneList = [
        "+14152339113", "+14155733553", "+14155733627", "+14153636140", "+14155392793",
        "+14155733851", "+14156254554", "+14154495283", "+14155733859", "+14155733842"
    ],
    util_sms:init_helper(twilio_options, FromPhoneList).


-spec can_send_sms(CC :: binary()) -> boolean().
can_send_sms(CC) ->
    is_cc_supported(CC).
-spec can_send_voice_call(CC :: binary()) -> boolean().
can_send_voice_call(CC) ->
    is_cc_supported(CC).

is_cc_supported(CC) ->
    case CC of
        <<"CH">> -> false;     %% Switzerland
        <<"CN">> -> false;     %% China
        <<"CU">> -> false;     %% Cuba
        <<"TD">> -> false;     %% Chad
        <<"CZ">> -> false;     %% Czech Republic
        <<"JP">> -> false;     %% Japan
        <<"ID">> -> false;     %% Indonesia
        <<"KZ">> -> false;     %% Kazakhstan
        <<"KE">> -> false;     %% Kenya
        <<"MA">> -> false;     %% Morocco
        <<"MM">> -> false;     %% Myanmar
        <<"NZ">> -> false;     %% New Zealand
        <<"QA">> -> false;     %% Qatar
        <<"RU">> -> false;     %% Russia
        <<"TZ">> -> false;     %% Tanzania
        <<"VN">> -> false;     %% Vietnam
        _ -> true
    end.


%% TODO: check about refactoring prepare_msg code in twilio.hrl and mbird.hrl
-spec send_sms(Phone :: phone(), Code :: binary(), LangId :: binary(),
        UserAgent :: binary()) -> {ok, gateway_response()} | {error, sms_fail, retry | no_retry}.
send_sms(Phone, Code, LangId, UserAgent) ->
    AccountSid = get_account_sid(util:is_test_number(Phone)),
    {Msg, TranslatedLangId} = util_sms:get_sms_message(UserAgent, Code, LangId),
    TwilioLangId = get_twilio_lang(TranslatedLangId),
    sending_helper(Phone, Msg, TwilioLangId, ?BASE_SMS_URL(AccountSid), fun compose_body/3, "SMS").


-spec send_voice_call(Phone :: phone(), Code :: binary(), LangId :: binary(),
        UserAgent :: binary()) -> {ok, gateway_response()} | {error, voice_call_fail, retry | no_retry}.
send_voice_call(Phone, Code, LangId, _UserAgent) ->
    AccountSid = get_account_sid(util:is_test_number(Phone)),
    {VoiceMsgBin, TranslatedLangId} = case is_voice_lang_available(LangId) of
        true ->
            mod_translate:translate(<<"server.voicecall.verification">>, LangId);
        false ->
            mod_translate:translate(<<"server.voicecall.verification">>, ?ENG_LANG_ID)
    end,
    TwilioLangId = get_twilio_lang(TranslatedLangId),
    DigitByDigit = string:trim(re:replace(Code, ".", "& . . ", [global, {return,list}])),
    VoiceMsg = io_lib:format("~s . . ~s . ", [VoiceMsgBin, DigitByDigit]),
    FinalMsg = io_lib:format("~s ~s ~s ~s", [VoiceMsg, VoiceMsg, VoiceMsg, VoiceMsg]),
    sending_helper(Phone, FinalMsg, TwilioLangId, ?BASE_VOICE_URL(AccountSid), fun compose_voice_body/3, "Voice Call").


-spec sending_helper(Phone :: phone(), Msg :: string(), TwilioLangId :: binary(), BaseUrl :: string(),
    ComposeBodyFn :: term(), Purpose :: string()) -> {ok, gateway_response()} | {error, atom(), atom()}.
sending_helper(Phone, Msg, TwilioLangId, BaseUrl, ComposeBodyFn, Purpose) ->
    ?INFO("Phone: ~p, Msg: ~p, Purpose: ~p", [Phone, Msg, Purpose]),
    Headers = fetch_auth_headers(util:is_test_number(Phone)),
    Type = "application/x-www-form-urlencoded",
    Body = ComposeBodyFn(Phone, Msg, TwilioLangId),
    ?DEBUG("Body: ~p", [Body]),
    HTTPOptions = [],
    Options = [],
    Request = {BaseUrl, Headers, Type, Body},
    ?DEBUG("Request: ~p", [Request]),
    Response = httpc:request(post, Request, HTTPOptions, Options),
    ?DEBUG("Response: ~p", [Response]),
    ErrMsg = list_to_atom(re:replace(string:lowercase(Purpose), " ", "_", [{return, list}]) ++ "_fail"),
    case Response of
        {ok, {{_, 201, _}, _ResHeaders, ResBody}} ->
            Json = jiffy:decode(ResBody, [return_maps]),
            Id = maps:get(<<"sid">>, Json),
            Status = normalized_status(maps:get(<<"status">>, Json)),
            {ok, #gateway_response{gateway_id = Id, status = Status, response = ResBody}};
        {ok, {{_, ResponseCode, _}, _ResHeaders, ResBody}} when ResponseCode >= 400 ->
            ErrCode = util_sms:get_response_code(ResBody),
            case {ErrCode, util:is_test_number(Phone)} of
                {_, true} ->
                    %% TODO: hardcoding params here is not great.
                    Id = util:random_str(20),
                    Status = queued,
                    {ok, #gateway_response{gateway_id = Id, status = Status, response = ResBody}};
                {?INVALID_TO_PHONE_CODE, false} ->
                    ?INFO("Sending ~p failed, Code ~p, response ~p (no_retry)", [Purpose, ErrCode, Response]),
                    {error, ErrMsg, no_retry};
                {?NOT_ALLOWED_CALL_CODE, false} ->
                    ?INFO("Sending ~p failed, Code ~p, response ~p (no_retry)", [Purpose, ErrCode, Response]),
                    {error, ErrMsg, no_retry};
                _ ->
                    ?ERROR("Sending ~p failed, Code ~p, response ~p (retry)", [Purpose, ErrCode, Response]),
                    {error, ErrMsg, retry}
            end;
        _ ->
            ?ERROR("Sending ~p failed (retry) ~p", [Response]),
            {error, ErrMsg, retry}
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
    Headers = fetch_auth_headers(false),
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

-spec fetch_tokens(IsTest :: boolean()) -> {string(), string()}.
fetch_tokens(true) ->
    Json = jiffy:decode(binary_to_list(mod_aws:get_secret(<<"TwilioTest">>)), [return_maps]),
    {binary_to_list(maps:get(<<"account_sid">>, Json)),
        binary_to_list(maps:get(<<"auth_token">>, Json))};
fetch_tokens(false) ->
    Json = jiffy:decode(binary_to_list(mod_aws:get_secret(<<"Twilio">>)), [return_maps]),
    {binary_to_list(maps:get(<<"account_sid">>, Json)),
        binary_to_list(maps:get(<<"auth_token">>, Json))}.


-spec fetch_auth_headers(IsTest :: boolean()) -> string().
fetch_auth_headers(IsTest) ->
    {AccountSid, AuthToken} = fetch_tokens(IsTest),
    AuthStr = base64:encode_to_string(AccountSid ++ ":" ++ AuthToken),
    [{"Authorization", "Basic " ++ AuthStr}].


-spec encode_based_on_country(Phone :: phone(), Msg :: string()) -> string().
encode_based_on_country(Phone, Msg) ->
    case mod_libphonenumber:get_cc(Phone) of
        <<"CN">> -> "【 HALLOAPP】" ++ Msg;
        _ -> Msg
    end.


-spec compose_body(Phone :: phone(), Message :: string(),
        TwilioLangId :: binary()) -> uri_string:uri_string().
compose_body(Phone, Message, _TwilioLangId) ->
    Message2 = encode_based_on_country(Phone, Message),
    PlusPhone = "+" ++ binary_to_list(Phone),
    uri_string:compose_query([
        {"To", PlusPhone },
        {"MessagingServiceSid", ?MESSAGE_SERVICE_SID},
        {"Body", Message2},
        {"StatusCallback", ?TWILIOCALLBACK_URL}
    ], [{encoding, latin1}]).

-spec encode_to_twiml(Msg :: string(), TwilioLangId :: string()) -> string().
encode_to_twiml(Msg, TwilioLangId) ->
    "<Response><Say voice=\"alice\" language=\"" ++ TwilioLangId ++ "\">" ++ Msg ++ "</Say></Response>".

-spec compose_voice_body(Phone :: phone(), Message :: string(),
        TwilioLangId :: string()) -> uri_string:uri_string().
compose_voice_body(Phone, Message, TwilioLangId) ->
    %% TODO(vipin): Add voice callback.
    Message2 = encode_to_twiml(Message, TwilioLangId),
    PlusPhone = "+" ++ binary_to_list(Phone),
    uri_string:compose_query([
        {"To", PlusPhone },
        {"From", get_from_phone(util:is_test_number(Phone))},
        {"Twiml", Message2}
    ], [{encoding, utf8}]).

-spec get_account_sid(IsTestNum :: boolean()) -> string().
get_account_sid(IsTestNum) ->
    case IsTestNum of
        true -> ?TEST_ACCOUNT_SID;
        false -> ?PROD_ACCOUNT_SID
    end.

-spec get_from_phone(IsTestNum :: boolean()) -> phone().
get_from_phone(IsTestNum) ->
    case IsTestNum of
        true -> ?FROM_TEST_PHONE;
        false -> util_sms:lookup_from_phone(twilio_options)
    end.

-spec is_voice_lang_available(LangId :: binary()) -> boolean().
is_voice_lang_available(LangId) ->
    %% If a corresponding twilio language other than en-US is available,
    %% then we must translate the message.
    get_twilio_lang(LangId) =/= "en-US".


%% Doc: https://www.twilio.com/docs/voice/twiml/say#attributes-alice
-spec get_twilio_lang(LangId :: binary()) -> binary().
get_twilio_lang(LangId) ->
    TwilioLangMap = get_twilio_lang_map(),
    util_gateway:get_gateway_lang(LangId, TwilioLangMap, ?TWILIO_ENG_LANG_ID).


get_twilio_lang_map() ->
    #{
        %% Danish, Denmark
        <<"da">> => "da-DK",
        %% German, Germany
        <<"de">> => "de-DE",
        %% English, Australia
        <<"en-AU">> => "en-AU",
        %% English, Canada
        <<"en-CA">> => "en-CA",
        %% English, UK
        <<"en-GB">> => "en-GB",
        %% English, India
        <<"en-IN">> => "en-IN",
        %% English, United States
        <<"en-US">> => "en-US",
        %% English, United States - fallback
        <<"en">> => "en-US",
        %% Catalan, Spain
        <<"ca">> => "ca-ES",
        %% Spanish, Spain
        <<"es">> => "es-ES",
        %% Finnish, Finland
        <<"fi">> => "fi-FI",
        %% French, France
        <<"fr">> => "fr-FR",
        %% Italian, Italy
        <<"it">> => "it-IT",
        %% Japanese, Japan
        <<"ja">> => "ja-JP",
        %% Korean, Korea
        <<"ko">> => "ko-KR",
        %% Norwegian, Norway
        <<"nb">> => "nb-NO",
        %% Dutch, Netherlands
        <<"nl">> => "nl-NL",
        %% Polish-Poland
        <<"pl">> => "pl-PL",
        %% Portuguese, Brazil
        <<"pt-BR">> => "pt-BR",
        %% Portuguese, Portugal
        <<"pt-PT">> => "pt-PT",
        %% Portuguese, Portugal - fallback
        <<"pt">> => "pt-PT",
        %% Russian, Russia
        <<"ru">> => "ru-RU",
        %% Swedish, Sweden
        <<"sv">> => "sv-SE",
        %% Chinese (Mandarin)
        <<"zh-CN">> => "zh-CN",
        %% Chinese (Cantonese)
        <<"zh-HK">> => "zh-HK",
        %% Chinese (Taiwanese Mandarin)
        <<"zh-TW">> => "zh-TW",
        %% Chinese (Mandarin) - fallback
        <<"zh">> => "zh-CN"
    }.


% Todo: Implement if sending feedback back to twilio
-spec send_feedback(Phone :: phone(), AllVerifyInfo :: list()) -> ok.
send_feedback(_Phone, _AllVerifyInfo) ->
    ok. 

