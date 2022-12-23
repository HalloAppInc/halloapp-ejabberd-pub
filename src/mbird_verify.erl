%%%-------------------------------------------------------------------
%%% @copyright (C) 2021, HalloApp, Inc
%%% @doc
%%% @end
%%%-------------------------------------------------------------------
-module(mbird_verify).
-behavior(mod_sms).
-author("michelle").
-include("logger.hrl").
-include("mbird_verify.hrl").
-include("ha_types.hrl").
-include("sms.hrl").
-include("time.hrl").


-define(MBIRD_VERIFY_ENG_LANG_ID, <<"en-us">>).

%% API
-export([
    init/0,
    can_send_sms/2,
    can_send_voice_call/2,
    send_sms/4,
    send_voice_call/4,
    send_feedback/2,
    verify_code_internal/3,
    verify_code/4
]).

-spec init() -> ok.
init() ->
    ok.

-spec can_send_sms(AppType :: maybe(app_type()), CC :: binary()) -> boolean().
can_send_sms(katckup, _CC) -> false;
can_send_sms(_, CC) ->
    mbird:is_cc_supported(CC).
-spec can_send_voice_call(AppType :: maybe(app_type()), CC :: binary()) -> boolean().
can_send_voice_call(katchup, _) -> false;
can_send_voice_call(_, CC) ->
    case CC of
        <<"US">> -> false;     %% US needs DLC.
        _ -> mbird:is_cc_supported(CC)
    end.

-spec send_sms(Phone :: phone(), Code :: binary(), LangId :: binary(),
        UserAgent :: binary()) -> {ok, gateway_response()} | {error, sms_fail, retry | no_retry}.
send_sms(Phone, _Code, LangId, _UserAgent) ->
    sending_helper(Phone, LangId, "sms").


-spec send_voice_call(Phone :: phone(), Code :: binary(), LangId :: binary(),
        UserAgent :: binary()) -> {ok, gateway_response()} | {error, tts_fail, retry | no_retry}.
send_voice_call(Phone, _Code, LangId, _UserAgent) ->
    sending_helper(Phone, LangId, "tts").


-spec sending_helper(Phone :: phone(), LangId :: binary(), Method :: string())
        -> {ok, gateway_response()} | {error, sms_fail, retry | no_retry} | {error, tts_fail, retry | no_retry}.
sending_helper(Phone, LangId, Method) ->
    URL = ?BASE_URL,
    Type = "application/x-www-form-urlencoded",
    [Headers, Type, HTTPOptions, Options] = fetch_headers(Phone),
    Body = compose_body(Phone, LangId, Method),
    ?DEBUG("Body: ~p", [Body]),
    Response = httpc:request(post, {URL, Headers, Type, Body}, HTTPOptions, Options),
    ?DEBUG("Response: ~p", [Response]),
    MethodFailMsg = list_to_atom(re:replace(string:lowercase(Method), " ", "_", [{return, list}]) ++ "_fail"),
    case Response of
        {ok, {{_, 201, _}, _ResHeaders, ResBody}} ->
            Json = jiffy:decode(ResBody, [return_maps]),
            Id = maps:get(<<"id">>, Json),  
            Status = normalized_status(maps:get(<<"status">>, Json)),
            ?INFO("Id: ~p Status: ~p Response ~p", [Id, Status, ResBody]),
            {ok, #gateway_response{gateway_id = Id, status = Status, response = ResBody}};
        {ok, {{_, ResponseCode, _}, _ResHeaders, ResBody}} when ResponseCode >= 400 ->
            ErrCode = util_sms:get_mbird_response_code(ResBody),
            case ErrCode of
                ?INVALID_RECIPIENTS_CODE ->
                    ?INFO("Sending ~p failed, Code ~p, response ~p (no_retry)", [Method, ErrCode, Response]),
                    {error, MethodFailMsg, no_retry};
                _ ->
                    ?ERROR("Sending ~p failed, Code ~p, response ~p (retry)", [Method, ErrCode, Response]),
                    {error, MethodFailMsg, retry}
            end;
         _ ->
            ?ERROR("Sending ~p to ~p failed: ~p (retry)", [Method, Phone, Response]),
            {error, MethodFailMsg, retry}
    end.


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
            Gateway =:= <<"mbird_verify">> andalso Status =:= <<"sent">> andalso
            % Run network calls on mbird_verify attempts until first match & update code
            % Must be called with header mbird_verify: to allow for mecking in unit test
            mbird_verify:verify_code_internal(Phone, Code, Sid)
        end, AllVerifyInfo).


-spec verify_code_internal(Phone :: phone(), Code :: binary(), Sid :: binary()) -> boolean().
verify_code_internal(Phone, Code, Sid) ->
    [Headers, _Type, HTTPOptions, Options] = fetch_headers(Phone),
    URL = ?VERIFY_URL(Sid, Code),
    ?INFO("Phone:~p URL: ~p Headers:~p", [Phone, URL, Headers]),
    Response = httpc:request(get, {URL, Headers}, HTTPOptions, Options),
    ?INFO("Response: ~p", [Response]),
    case Response of        
        {ok, {{_, 200, _}, _ResHeaders, _ResBody}} ->
            GatewayResponse = #gateway_response{gateway_id = Sid, gateway = mbird_verify, status = accepted},
            ok = model_phone:add_gateway_callback_info(GatewayResponse),
            true;
        % Invalid codes return a 422 Resource Not Created Error
        {ok, {{_, 422, _}, _ResHeaders, _ResBody}} ->
            GatewayResponse = #gateway_response{gateway_id = Sid, gateway = mbird_verify, status = delivered},
            ok = model_phone:add_gateway_callback_info(GatewayResponse),
            false;
        _ ->
            ?ERROR("Phone: ~p , Failed validation: ~p", [Phone, Response]),
            false
    end.


-spec fetch_headers(Phone :: phone()) -> list().
fetch_headers(Phone) ->
    Headers = [{"Authorization", "AccessKey " ++ get_access_key(util:is_test_number(Phone))}],
    Type = "application/x-www-form-urlencoded",
    [Headers, Type, [], []].


-spec compose_body(Phone :: phone(), LangId :: binary(), Method :: string()) -> uri_string:uri_string().
compose_body(Phone, LangId, Method) ->
    PlusPhone = "+" ++ binary_to_list(Phone),
    Message = [
        {"recipient", PlusPhone},
        {"type", Method},
        {"timeout", util:to_binary(?DAYS)}
    ],
    FullMessage = case Method of
        "tts" -> Message ++ [{"language", get_verify_lang(LangId)}];
        _ -> Message
    end,
    uri_string:compose_query(FullMessage, [{encoding, latin1}]).


% verified - correct code was entered
% sent - code has yet to be verified yet but message was sent
% expired - no attempt to verify code within the set time (currently 24hrs)
% failed - wrong code was entered
-spec normalized_status(Status :: binary()) -> atom().
normalized_status(<<"verified">>) ->
    accepted;
normalized_status(<<"sent">>) ->
    sent;
normalized_status(<<"expired">>) ->
    delivered;
normalized_status(<<"failed">>) ->
    delivered;
normalized_status(_) ->
    unknown.


-spec get_access_key(IsTest :: boolean()) -> string().
get_access_key(true) ->
    mod_aws:get_secret_value(<<"MBirdTest">>, <<"access_key">>);
get_access_key(false) ->
    mod_aws:get_secret_value(<<"MBird">>, <<"access_key">>).


% Todo: Implement if sending feedback back to mbird_verify
-spec send_feedback(Phone :: phone(), AllVerifyInfo :: list()) -> ok.
send_feedback(_Phone, _AllVerifyInfo) ->
    ok. 


%% Doc: https://developers.messagebird.com/api/verify/#request-a-verify (language)
-spec get_verify_lang(LangId :: binary()) -> binary().
get_verify_lang(LangId) ->
    VerifyLangMap = get_verify_lang_map(),
    util_gateway:get_gateway_lang(LangId, VerifyLangMap, ?MBIRD_VERIFY_ENG_LANG_ID).


get_verify_lang_map() ->
    #{
        %% Welsh (United Kingdom)
        <<"cy">> => <<"cy-gb">>,
        %% Danish (Denmark)
        <<"da">> => <<"da-dk">>,
        %% German (Germany)
        <<"de">> => <<"de-de">>,
        %% Greek (Greece)
        <<"el">> => <<"el-gr">>,
        %% Australian English
        <<"en-AU">> => <<"en-au">>,
        %% British English
        <<"en-GB">> => <<"en-gb">>,
        %% English (Welsh)
        <<"en-GB-WLS">> => <<"en-gb-wls">>,
        %% English (India)
        <<"en-IN">> => <<"en-in">>,
        %% American English
        <<"en-US">> => <<"en-us">>,
        %% American English - fallback
        <<"en">> => <<"en-us">>,
        %% European Spanish
        <<"es">> => <<"es-es">>,
        %% Spanish (Mexico)
        <<"es-MX">> => <<"es-mx">>,
        %% Spanish (United States)
        <<"es-US">> => <<"es-us">>,
        %% French (Canada)
        <<"fr-CA">> => <<"fr-ca">>,
        %% French (France)
        <<"fr">> => <<"fr-fr">>,
        %% Indonesian (Indonesia)
        <<"id">> => <<"id-id">>,
        %% Icelandic (Iceland)
        <<"is">> => <<"is-is">>,
        %% Italian (Italy)
        <<"it">> => <<"it-it">>,
        %% Japanese (Japan)
        <<"ja">> => <<"ja-jp">>,
        %% Korean (South Korea)
        <<"ko">> => <<"ko-kr">>,
        %% Malay (Malaysia)
        <<"ms">> => <<"ms-my">>,
        %% Norwegian Bokmål (Norway)
        <<"nb">> => <<"nb-no">>,
        %% Dutch (Netherlands)
        <<"nl">> => <<"nl-nl">>,
        %% Polish (Poland)
        <<"pl">> => <<"pl-pl">>,
        %% Brazilian Portuguese
        <<"pt-BR">> => <<"pt-br">>,
        %% European Portuguese
        <<"pt-PT">> => <<"pt-pt">>,
        %% European Portuguese - fallback
        <<"pt">> => <<"pt-pt">>,
        %% Romanian (Romania)
        <<"ro">> => <<"ro-ro">>,
        %% Russian (Russia)
        <<"ru">> => <<"ru-ru">>,
        %% Swedish (Sweden)
        <<"sv">> => <<"sv-se">>,
        %% Tamil (India)
        <<"ta">> => <<"ta-in">>,
        %% Thai (Thailand)
        <<"th">> => <<"th-th">>,
        %% Turkish (Turkey)
        <<"tr">> => <<"tr-tr">>,
        %% Vietnamese (Vietnam)
        <<"vi">> => <<"vi-vn">>,
        %% Chinese (China)
        <<"zh-CN">> => <<"zh-cn">>,
        %% Chinese (Hong Kong SAR China)
        <<"zh-HK">> => <<"zh-hk">>,
        %% Chinese (China) - fallback
        <<"zh">> => <<"zh-cn">>
    }.

