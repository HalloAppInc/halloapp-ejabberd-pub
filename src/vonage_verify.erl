%%%-------------------------------------------------------------------
%%% @copyright (C) 2022, HalloApp, Inc
%%% @doc
%%% SMS module with helper functions to send SMS messages.
%%% @end
%%%-------------------------------------------------------------------
-module(vonage_verify).
-behavior(mod_sms).
-author(thomas).
-include("logger.hrl").
-include("vonage.hrl").
-include("ha_types.hrl").
-include("sms.hrl").

%% See: https://developer.vonage.com/api/verify?theme=dark for info on vonage verify api.

%% API
-export([
    init/0,
    can_send_sms/1,
    can_send_voice_call/1,
    send_sms/4,
    send_voice_call/4,
    send_feedback/2,
    get_api_secret/0,
    verify_code/4,
    verify_code_internal/3
]).

init() -> ok.

-spec can_send_sms(CC :: binary()) -> boolean().
can_send_sms(_CC) ->
    % TODO: This gateway is disabled for now.
    false.
-spec can_send_voice_call(CC :: binary()) -> boolean().
can_send_voice_call(_CC) ->
    % TODO: Voice calls are not implemented yet.
    false.

-spec send_sms(Phone :: phone(), Code :: binary(), LangId :: binary(), UserAgent :: binary()) ->
        {ok, gateway_response()} | {error, sms_fail, retry | no_retry}.
send_sms(Phone, _Code, LangId, _UserAgent) ->
    ?INFO("Phone: ~p", [Phone]),
    URL = ?BASE_VERIFY_URL,
    Headers = [],
    Type = "application/x-www-form-urlencoded",
    Body = compose_body(Phone, LangId),
    ?DEBUG("Body: ~p", [Body]),
    HTTPOptions = [],
    Options = [],
    Response = httpc:request(post, {URL, Headers, Type, Body}, HTTPOptions, Options),
    ?DEBUG("Response: ~p", [Response]),
    case Response of
        {ok, {{_, 200, _}, _ResHeaders, ResBody}} ->
            case decode_response(ResBody) of
                {error, bad_format} ->
                    ?ERROR("Cannot parse Vonage response ~p", [Response]),
                    {error, sms_fail, no_retry};
                {error, Status, ErrorText} ->
                    ?ERROR("SMS send failed: ~p: ~p  Response: ~p",
                        [Status, ErrorText, Response]),
                    {error, sms_fail, no_retry};
                {ok, RequestId} ->
                    ?INFO("send ok Phone:~p RequestId:~p ",
                        [Phone, RequestId]),
                    {ok, #gateway_response{
                        gateway_id = RequestId,
                        response = util:to_binary(ResBody)}}
            end;
        {ok, {{_, HttpStatus, _}, _ResHeaders, _ResBody}}->
            ?ERROR("Sending SMS failed Phone:~p, HTTPCode: ~p, response ~p",
                [Phone, HttpStatus, Response]),
            {error, sms_fail, retry};
        _ ->
            % Some other unknown error occurred
            ?ERROR("Sending SMS failed Phone:~p (no_retry) ~p",
                [Phone, Response]),
            {error, sms_fail, no_retry}
    end.

% TODO: Does not support voice calls yet
send_voice_call(_Phone, _Code, _LangId, _UserAgent) ->
    {error, voice_call_fail, retry}.

-spec decode_response(ResBody :: iolist()) -> {ok, binary()} | {error, bad_format} | {error, binary(), binary()}.
decode_response(ResBody) ->
    Json = jiffy:decode(ResBody, [return_maps]),
    Status = maps:get(<<"status">>, Json, <<"-1">>),
    case Status of
        <<"-1">> -> {error, bad_format};
        <<"0">> ->
            RequestId = maps:get(<<"request_id">>, Json),
            {ok, RequestId};
        _ -> 
            ErrorText = maps:get(<<"error_text">>, Json),
            {error, Status, ErrorText}
    end.


-spec get_api_key() -> string().
get_api_key() ->
    mod_aws:get_secret_value(<<"Vonage">>, <<"api_key">>).

-spec get_api_secret() -> string().
get_api_secret() ->
    mod_aws:get_secret_value(<<"Vonage">>, <<"api_secret">>).


-spec compose_body(Phone, LangId) -> Body when
    Phone :: phone(),
    LangId :: binary(),
    Body :: uri_string:uri_string().
compose_body(Phone, LangId) ->
    uri_string:compose_query([
        {"number", Phone },
        {"api_key", get_api_key()},
        {"api_secret", get_api_secret()},
        {"brand", "HalloApp"},
        {"code_length", "6"},
        {"lg", get_verify_lang(LangId)}
    ], [{encoding, utf8}]).


% TODO: Implement if sending feedback back to gateway
-spec send_feedback(Phone :: phone(), AllVerifyInfo :: list()) -> ok.
send_feedback(_Phone, _AllVerifyInfo) ->
    ok. 

-spec verify_code(Phone :: phone(), AppType :: app_type(), Code :: binary(), AllVerifyInfo :: [verification_info()])
        -> {match, verification_info()} | nomatch.
verify_code(Phone, AppType, Code, AllVerifyInfo) ->
    case find_matching_attempt(Phone, Code, AllVerifyInfo) of
        false ->
            nomatch;
        {value, Match} ->
            ok = model_phone:update_sms_code(Phone, AppType, Code, Match#verification_info.attempt_id),
            {match, Match}
    end.

-spec find_matching_attempt(Phone :: phone(), Code :: binary(), AllVerifyInfo :: [verification_info()]) -> false | {value, verification_info()}.
find_matching_attempt(Phone, Code, AllVerifyInfo) ->
    lists:search(
        fun(Info) -> 
            #verification_info{gateway = Gateway, status = Status, sid = Sid} = Info,
            Gateway =:= <<"vonage_verify">> andalso Status =:= <<"sent">> andalso
            % Look for first matching attempt
            vonage_verify:verify_code_internal(Phone, Code, Sid)
        end, AllVerifyInfo).

-spec verify_code_internal(Phone :: phone(), Code :: binary(), Sid :: binary()) -> boolean().
verify_code_internal(Phone, Code, Sid) ->
    Headers = [],
    Type = "application/x-www-form-urlencoded",
    HTTPOptions = [],
    Options = [],
    Body = compose_verify_code_body(Code, Sid),
    
    URL = ?VERIFY_CHECK_URL,
    ?INFO("Phone:~p URL: ~p Headers:~p", [Phone, URL, Headers]),
    Response = httpc:request(post, {URL, Headers, Type, Body}, HTTPOptions, Options),
    ?INFO("Response: ~p", [Response]),
    case Response of        
        {ok, {{_, 200, _}, _ResHeaders, ResBody}} ->
            case decode_verify_response(ResBody) of
                ok -> 
                    GatewayResponse = #gateway_response{gateway_id = Sid, gateway = vonage_verify, status = accepted},
                    ok = model_phone:add_gateway_callback_info(GatewayResponse),
                    true;
                {error, bad_code} -> 
                    GatewayResponse = #gateway_response{gateway_id = Sid, gateway = vonage_verify, status = delivered},
                    ok = model_phone:add_gateway_callback_info(GatewayResponse),
                    false;
                {error, bad_format} ->
                    % If this occurs, either us or the server made a mistake. Log & return false.
                    ?ERROR("Phone: ~p , Failed validation: ~p", [Phone, Response]),
                    false
            end;
        _ -> % API should always return a 200 code.
            ?ERROR("Phone: ~p , Failed validation: ~p", [Phone, Response]),
            false
    end.

-spec compose_verify_code_body(Code :: binary(), Sid :: binary()) -> binary().
compose_verify_code_body(Code, Sid) -> uri_string:compose_query([
        {"request_id", Sid },
        {"api_key", get_api_key()},
        {"api_secret", get_api_secret()},
        {"code", Code}
    ], [{encoding, utf8}]).


-spec decode_verify_response(ResBody :: iolist()) -> ok | {error, atom()}.
decode_verify_response(ResBody) ->
    Json = jiffy:decode(ResBody,[return_maps]),
    Status = maps:get(<<"status">>, Json, <<"-1">>),
    case Status of
        <<"0">> -> ok;
        <<"16">> -> {error, bad_code};
        <<"17">> -> {error, bad_code};
        _ -> {error, bad_format}
    end.

-spec get_verify_lang(LangId :: binary()) -> string().
get_verify_lang(LangId) ->
    VerifyLangMap = get_verify_lang_map(),
    util_gateway:get_gateway_lang(LangId, VerifyLangMap, <<"en-us">>).





get_verify_lang_map() ->
    #{
        %% Afrikaans
        %<<"af">> => "af",
        %% Arabic
        <<"ar">> => "ar-xa",
        %% Catalan
        %<<"ca">> => "ca",
        %% Chinese (Simplified using mainland terms)
        <<"zh-CN">> => "zh-cn",
        %% Chinese (Simplified using Hong Kong terms)
        <<"zh-HK">> => "zh-cn",
        %% Chinese (Simplified using mainland terms) - fallback
        <<"zh">> => "zh-cn",
        %% Croatian
        %<<"hr">> => "hr",
        %% Czech
        <<"cs">> => "cs-cz",
        %% Danish
        <<"da">> => "da-dk",
        %% Dutch
        <<"nl">> => "nl-nl",
        %% English (American)
        <<"en-US">> => "en-us",
        %% English (British)
        <<"en-GB">> => "en-gb",
        %% English (American) - fallback
        <<"en">> => "en-us",
        %% Finnish
        <<"fi">> => "fi-fi",
        %% French
        <<"fr">> => "fr-fr",
        %% German
        <<"de">> => "de-de",
        %% Greek
        <<"el">> => "el-gr",
        %% Hebrew
        %<<"he">> => "he",
        %% Hindi
        <<"hi">> => "hi-in",
        %% Hungarian
        <<"hu">> => "hu-hu",
        %% Indonesian
        <<"id">> => "id-id",
        %% Italian
        <<"it">> => "it-it",
        %% Japanese
        <<"ja">> => "ja-jp",
        %% Korean
        <<"ko">> => "ko-kr",
        %% Malay
        %<<"ms">> => "ms",
        %% Norwegian
        <<"nb">> => "nb-no",
        %% Polish
        <<"pl">> => "pl-pl",
        %% Portuguese - Brazil
        <<"pt-BR">> => "pt-br",
        %% Portuguese
        <<"pt-PT">> => "pt-pt",
        %% Portuguese - fallback
        <<"pt">> => "pt-pt",
        %% Romanian
        <<"ro">> => "ro-ro",
        %% Russian
        <<"ru">> => "ru-ru",
        %% Spanish
        <<"es">> => "es-es",
        %% Swedish
        <<"sv">> => "sv-se",
        %% Tagalog
        %<<"tl">> => "tl",
        %% Thai
        <<"th">> => "th-th",
        %% Turkish
        <<"tr">> => "tr-tr",
        %% Vietnamese
        <<"vi">> => "vi-vn"
    }.
