%%%-------------------------------------------------------------------
%%% @copyright (C) 2020, HalloApp, Inc
%%% @doc
%%% SMS module with helper functions to send SMS messages.
%%% @end
%%%-------------------------------------------------------------------
-module(mbird).
-behavior(mod_sms).
-author("vipin").
-include("logger.hrl").
-include("mbird.hrl").
-include("ha_types.hrl").
-include("sms.hrl").

-define(MBIRD_ENG_LANG_ID, <<"en-US">>).

%% TODO: optimize calls for get_lang_id.

%% API
-export([
    init/0,
    send_sms/4,
    send_voice_call/4,
    normalized_status/1,
    send_feedback/2,
    compose_body/2,     %% for debugging
    compose_voice_body/3  %% for debugging
]).

init() ->
    FromPhoneList = ["+12022213975", "+12029511227", "+12029511244"],
    util_sms:init_helper(mbird_options, FromPhoneList).


-spec send_sms(Phone :: phone(), Code :: binary(), LangId :: binary(), UserAgent :: binary()) ->
        {ok, gateway_response()} | {error, sms_fail, retry | no_retry}.
send_sms(Phone, Code, LangId, UserAgent) ->
    {SmsMsgBin, _TranslatedLangId} = mod_translate:translate(<<"server.sms.verification">>, LangId),
    AppHash = util_ua:get_app_hash(UserAgent),
    Msg = io_lib:format("~s: ~s~n~n~n~s", [SmsMsgBin, Code, AppHash]),

    ?INFO("Phone: ~p, Msg: ~p", [Phone, Msg]),
    URL = ?BASE_SMS_URL,
    Headers = [{"Authorization", "AccessKey " ++ get_access_key(util:is_test_number(Phone))}],
    Type = "application/x-www-form-urlencoded",
    Body = compose_body(Phone, Msg),
    HTTPOptions = [],
    Options = [],
    Response = httpc:request(post, {URL, Headers, Type, Body}, HTTPOptions, Options),
    ?DEBUG("Response: ~p", [Response]),
    case Response of
        {ok, {{_, 201, _}, _ResHeaders, ResBody}} ->
            Json = jiffy:decode(ResBody, [return_maps]),
            Id = maps:get(<<"id">>, Json),
            Receipients = maps:get(<<"recipients">>, Json),
            Items = maps:get(<<"items">>, Receipients),
            [Item] = Items,
            Status = normalized_status(maps:get(<<"status">>, Item)),
            {ok, #gateway_response{gateway_id = Id, status = Status, response = ResBody}};
        {ok, {{_, ResponseCode, _}, _ResHeaders, _ResBody}} when ResponseCode >= 400 ->
            ?ERROR("Sending SMS failed (retry) ~p", [Response]),
            {error, sms_fail, retry};
        _ ->
            ?ERROR("Sending SMS failed (no_retry) ~p", [Response]),
            {error, sms_fail, no_retry}
    end.

-spec send_voice_call(Phone :: phone(), Code :: binary(), LangId :: binary(), UserAgent :: binary()) ->
        {ok, gateway_response()} | {error, voice_call_fail, retry | no_retry}.
send_voice_call(Phone, Code, LangId, UserAgent) ->
    {VoiceMsgBin, TranslatedLangId} = case is_voice_lang_available(LangId) of
        true ->
            mod_translate:translate(<<"server.voicecall.verification">>, LangId);
        false ->
            mod_translate:translate(<<"server.voicecall.verification">>, ?ENG_LANG_ID)
    end,
    MbirdLangId = get_mbird_lang(TranslatedLangId),
    DigitByDigit = string:trim(re:replace(Code, ".", "& . . ", [global, {return,list}])),
    VoiceMsg = io_lib:format("~s . . ~s . ", [VoiceMsgBin, DigitByDigit]),
    FinalMsg = io_lib:format("~s ~s ~s ~s", [VoiceMsg, VoiceMsg, VoiceMsg, VoiceMsg]),

    ?INFO("Phone: ~p, FinalMsg: ~s", [Phone, FinalMsg]),
    URL = ?BASE_VOICE_URL,
    Headers = [{"Authorization", "AccessKey " ++ get_access_key(util:is_test_number(Phone))}],
    Type = "application/json",
    Body = compose_voice_body(Phone, FinalMsg, MbirdLangId),
    ?DEBUG("Body: ~p", [Body]),
    HTTPOptions = [],
    Options = [],
    Response = httpc:request(post, {URL, Headers, Type, Body}, HTTPOptions, Options),
    ?DEBUG("Response: ~p", [Response]),
    case Response of
        {ok, {{_, 201, _}, _ResHeaders, ResBody}} ->
            Json = jiffy:decode(ResBody, [return_maps]),
            [Data] = maps:get(<<"data">>, Json),
            Id = maps:get(<<"id">>, Data),
            Status = normalized_status(maps:get(<<"status">>, Data)),
            {ok, #gateway_response{gateway_id = Id, status = Status, response = ResBody}};
        {ok, {{_, ResponseCode, _}, _ResHeaders, _ResBody}} when ResponseCode >= 400 ->
            ?ERROR("Sending Voice Call failed (retry) ~p", [Response]),
            {error, voice_call_fail, retry};
        _ ->
            ?ERROR("Sending Voice Call failed (no_retry) ~p", [Response]),
            {error, voice_call_fail, no_retry}
    end.

-spec normalized_status(Status :: binary()) -> atom().
normalized_status(<<"scheduled">>) ->
    accepted;
normalized_status(<<"buffered">>) ->
    queued;
normalized_status(<<"queued">>) ->
    queued;
normalized_status(<<"sent">>) ->
    sent;
normalized_status(<<"delivered">>) ->
    delivered;
normalized_status(<<"delivery_failed">>) ->
    undelivered;
normalized_status(<<"expired">>) ->
    failed;
normalized_status(_) ->
    unknown.

-spec get_access_key(IsTest :: boolean()) -> string().
get_access_key(true) ->
    Json = jiffy:decode(binary_to_list(mod_aws:get_secret(<<"MBirdTest">>)), [return_maps]),
    binary_to_list(maps:get(<<"access_key">>, Json));
get_access_key(false) ->
    Json = jiffy:decode(binary_to_list(mod_aws:get_secret(<<"MBird">>)), [return_maps]),
    binary_to_list(maps:get(<<"access_key">>, Json)).

-spec compose_body(Phone, Message) -> Body when
    Phone :: phone(),
    Message :: string(),
    Body :: uri_string:uri_string().
compose_body(Phone, Message) ->
    PlusPhone = "+" ++ binary_to_list(Phone),
    FromPhone = get_from_phone(Phone),
    %% reference is used during callback. TODO(vipin): Need a more useful ?REFERENCE.
    uri_string:compose_query([
        {"recipients", PlusPhone },
        {"originator", FromPhone},
        {"reference", ?REFERENCE},
        {"body", Message}
    ], [{encoding, latin1}]).

-spec compose_voice_body(Phone, Message, MbirdLangId) -> Body when
    Phone :: phone(),
    Message :: string(),
    MbirdLangId :: binary(),
    Body :: uri_string:uri_string().
compose_voice_body(Phone, Message, MbirdLangId) ->
    PlusPhone = "+" ++ binary_to_list(Phone),
    FromPhone = get_from_phone(Phone),
    %% TODO(vipin): 1. Add the callback.
    %% Ref: https://developers.messagebird.com/api/voice-calling/#calls
    Body = #{
        <<"source">> => list_to_binary(FromPhone),
        <<"destination">> => list_to_binary(PlusPhone),
        <<"callFlow">> => #{
            <<"title">> => <<"Say message">>,
            <<"steps">> => [#{
                <<"action">> => <<"say">>,
                <<"options">> => #{
                    <<"payload">> => list_to_binary(Message),
                    %% This preference is ignored if the desired voice is not available for the selected language.
                    <<"voice">> => <<"male">>,
                    <<"language">> => MbirdLangId
                }
            }]
        }
    },
    binary_to_list(jiffy:encode(Body)).


get_from_phone(Phone) ->
    case mod_libphonenumber:get_cc(Phone) of
        <<"CA">> -> ?FROM_PHONE_FOR_CANADA;
        _ -> util_sms:lookup_from_phone(mbird_options)
    end.


-spec is_voice_lang_available(LangId :: binary()) -> boolean().
is_voice_lang_available(LangId) ->
    %% If a corresponding mbird language other than en-US is available,
    %% then we must translate the message.
    get_mbird_lang(LangId) =/= <<"en-US">>.


%% Doc: https://developers.messagebird.com/api/voice-calling/#supported-languages
-spec get_mbird_lang(LangId :: binary()) -> binary().
get_mbird_lang(LangId) ->
    MbirdLangMap = get_mbird_lang_map(),
    util_gateway:get_gateway_lang(LangId, MbirdLangMap, ?MBIRD_ENG_LANG_ID).


get_mbird_lang_map() ->
    #{
        %% Arabic (Saudi Arabia)
        <<"ar">> => <<"ar-SA">>,
        %% Bulgarian (Bulgaria)
        <<"bg">> => <<"bg-BG">>,
        %% Catalan (Spain)
        <<"ca">> => <<"ca-ES">>,
        %% Czech (Czechia)
        <<"cs">> => <<"cs-CZ">>,
        %% Welsh (United Kingdom)
        <<"cy">> => <<"cy-GB">>,
        %% Danish (Denmark)
        <<"da">> => <<"da-DK">>,
        %% German (Germany)
        <<"de">> => <<"de-DE">>,
        %% Greek (Greece)
        <<"el">> => <<"el-GR">>,
        %% Australian English
        <<"en-AU">> => <<"en-AU">>,
        %% Canadian English
        <<"en-CA">> => <<"en-CA">>,
        %% British English
        <<"en-GB">> => <<"en-GB">>,
        %% English (Ireland)
        <<"en-IE">> => <<"en-IE">>,
        %% English (India)
        <<"en-IN">> => <<"en-IN">>,
        %% American English
        <<"en-US">> => <<"en-US">>,
        %% American English - fallback
        <<"en">> => <<"en-US">>,
        %% European Spanish
        <<"es">> => <<"es-ES">>,
        %% Finnish (Finland)
        <<"fi">> => <<"fi-FI">>,
        %% Filipino (Philippines)
        <<"fil">> => <<"fil-PH">>,
        %% French (France)
        <<"fr">> => <<"fr-FR">>,
        %% Gujarati (India)
        <<"gu">> => <<"gu-IN">>,
        %% Hebrew (Israel)
        <<"he">> => <<"he-IL">>,
        %% Hindi (India)
        <<"hi">> => <<"hi-IN">>,
        %% Croatian (Croatia)
        <<"hr">> => <<"hr-HR">>,
        %% Hungarian (Hungary)
        <<"hu">> => <<"hu-HU">>,
        %% Indonesian (Indonesia)
        <<"id">> => <<"id-ID">>,
        %% Icelandic (Iceland)
        <<"is">> => <<"is-IS">>,
        %% Italian (Italy)
        <<"it">> => <<"it-IT">>,
        %% Japanese (Japan)
        <<"ja">> => <<"ja-JP">>,
        %% Kannada (India)
        <<"kn">> => <<"kn-IN">>,
        %% Korean (South Korea)
        <<"ko">> => <<"ko-KR">>,
        %% Malayalam (India)
        <<"ml">> => <<"ml-IN">>,
        %% Malay (Malaysia)
        <<"ms">> => <<"ms-MY">>,
        %% Norwegian Bokmål (Norway)
        <<"nb">> => <<"nb-NO">>,
        %% Dutch (Netherlands)
        <<"nl">> => <<"nl-NL">>,
        %% Polish (Poland)
        <<"pl">> => <<"Polish (Poland)">>,
        %% Brazilian Portuguese
        <<"pt-BR">> => <<"pt-BR">>,
        %% European Portuguese
        <<"pt-PT">> => <<"pt-PT">>,
        %% European Portuguese - fallback
        <<"pt">> => <<"pt-PT">>,
        %% Romanian (Romania)
        <<"ro">> => <<"ro-RO">>,
        %% Russian (Russia)
        <<"ru">> => <<"ru-RU">>,
        %% Slovak (Slovakia)
        <<"sk">> => <<"sk-SK">>,
        %% Slovenian (Slovenia)
        <<"sl">> => <<"sl-SI">>,
        %% Swedish (Sweden)
        <<"sv">> => <<"sv-SE">>,
        %% Tamil (India)
        <<"ta">> => <<"ta-IN">>,
        %% Telugu (India)
        <<"te">> => <<"te-IN">>,
        %% Thai (Thailand)
        <<"th">> => <<"th-TH">>,
        %% Turkish (Turkey)
        <<"tr">> => <<"tr-TR">>,
        %% Ukrainian (Ukraine)
        <<"uk">> => <<"uk-UA">>,
        %% Vietnamese (Vietnam)
        <<"vi">> => <<"vi-VN">>,
        %% Chinese (China)
        <<"zh-CN">> => <<"zh-CN">>,
        %% Chinese (Hong Kong SAR China)
        <<"zh-HK">> => <<"zh-HK">>,
        %% Chinese (Taiwan)
        <<"zh-TW">> => <<"zh-TW">>,
        % Chinese (China) - fallback
        <<"zh">> => <<"zh-CN">>
    }.


% Todo: Implement if sending feedback back to mbird
-spec send_feedback(Phone :: phone(), AllVerifyInfo :: list()) -> ok.
send_feedback(_Phone, _AllVerifyInfo) ->
    ok. 

