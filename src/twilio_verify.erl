%%%----------------------------------------------------------------------
%%% File    : twilio_verify.erl
%%%
%%% Copyright (C) 2021 halloappinc.
%%%
%%% This module implements API needed to interface with Twilio Verify
%%%----------------------------------------------------------------------

-module(twilio_verify).
-behavior(mod_sms).
-author('michelle').
-include("logger.hrl").
-include("twilio_verify.hrl").
-include("ha_types.hrl").
-include("sms.hrl").

-export([
    init/0,
    can_send_sms/2,
    can_send_voice_call/2,
    send_sms/4,
    send_voice_call/4,
    send_feedback/2,
    compose_send_body/5,  %% Need for testing.
    get_latest_verify_info/1   %% Need for test.
]).

-define(TWILIO_VERIFY_ENG_LANG_ID, "en").
-define(TTL_SMS_SID, 600).


-spec init() -> ok.
init() ->
    ok.

-spec can_send_sms(AppType :: maybe(app_type()), CC :: binary()) -> boolean().
can_send_sms(_AppType, CC) ->
    is_cc_supported(CC).
-spec can_send_voice_call(AppType :: maybe(app_type()), CC :: binary()) -> boolean().
can_send_voice_call(_AppType, CC) ->
    is_cc_supported(CC).

is_cc_supported(CC) ->
    case CC of
        <<"NG">> -> false;     %% Nigeria
        _ -> true
    end.

-spec send_sms(Phone :: phone(), Code :: binary(), LangId :: binary(),
        UserAgent :: binary()) -> {ok, gateway_response()} | {error, sms_fail, retry | no_retry}.
send_sms(Phone, Code, LangId, UserAgent) ->
    sending_helper(Phone, Code, LangId, UserAgent, "sms").


-spec send_voice_call(Phone :: phone(), Code :: binary(), LangId :: binary(),
        UserAgent :: binary()) -> {ok, gateway_response()} | {error, call_fail, retry | no_retry}.
send_voice_call(Phone, Code, LangId, UserAgent) -> 
    sending_helper(Phone, Code, LangId, UserAgent, "call").


-spec sending_helper(Phone :: phone(), Code :: binary(), LangId :: binary(), UserAgent :: binary(),
        Method :: string()) -> {ok, gateway_response()} | {error, sms_fail, atom()} | {error, call_fail, atom()}.
sending_helper(Phone, Code, LangId, UserAgent, Method) ->
    URL = ?VERIFICATION_URL,
    [Headers, Type, HTTPOptions, Options] = fetch_headers(),
    Body = compose_send_body(Phone, Code, LangId, UserAgent, Method),
    ?DEBUG("Body: ~p", [Body]),
    Response = httpc:request(post, {URL, Headers, Type, Body}, HTTPOptions, Options),
    ?DEBUG("Response: ~p", [Response]),
    case Response of
        {ok, {{_, 201, _}, _ResHeaders, ResBody}} ->
            Json = jiffy:decode(ResBody, [return_maps]),
            Id = maps:get(<<"sid">>, Json),  
            Status = normalized_status(maps:get(<<"status">>, Json)),
            {ok, #gateway_response{gateway_id = Id, status = Status, response = ResBody}};
        {ok, {{_, ResponseCode, _}, _ResHeaders, ResBody}} when ResponseCode >= 400 ->
            ErrCode = util_sms:get_response_code(ResBody),
            ErrMsg = list_to_atom(re:replace(string:lowercase(Method), " ", "_", [{return, list}]) ++ "_fail"),
            case lists:member(ErrCode, ?OK_ERROR_CODES) of
                true ->
                    ?INFO("Sending ~p to ~p failed, Code ~p, response ~p (no_retry)", [Method, Phone, ErrCode, Response]),
                    {error, ErrMsg, no_retry};
                false ->
                    ?ERROR("Sending ~p to ~p failed, Code ~p, response ~p (retry)", [Method, Phone, ErrCode, Response]),
                    {error, ErrMsg, retry}
            end;
        _ ->
            ?ERROR("Sending ~p to ~p failed (retry): ~p", [Method, Phone, Response]),
            ErrMsg = list_to_atom(re:replace(string:lowercase(Method), " ", "_", [{return, list}]) ++ "_fail"),
            {error, ErrMsg, retry}
    end.


-spec send_feedback(Phone :: phone(), AllVerifyInfo :: list()) -> ok.
send_feedback(Phone, AllVerifyInfo) ->
    case get_latest_verify_info(AllVerifyInfo) of
        [] -> ok;
        [AttemptId, Sid] ->
            case send_feedback_internal(Phone, AttemptId, Sid) of
                ok -> ok;
                {error, _Response} ->
                    %% Try exactly one more time incase we fail to send feedback and log an error.
                    case send_feedback_internal(Phone, AttemptId, Sid) of
                        ok -> ok;
                        {error, Response2} ->
                            ?INFO("Feedback info failed, Phone:~p AttemptId: ~p Response: ~p",
                                [Phone, AttemptId, Response2])
                    end
            end
    end.


-spec send_feedback_internal(Phone :: phone(), AttemptId :: binary(),
    Sid :: binary()) -> ok | {error, any()}.
send_feedback_internal(Phone, AttemptId, Sid) ->
    URL = ?VERIFICATION_URL ++ binary_to_list(Sid),
    [Headers, Type, HTTPOptions, Options] = fetch_headers(),
    Body = compose_feedback_body(),
    ?DEBUG("Body: ~p", [Body]),
    Response = httpc:request(post, {URL, Headers, Type, Body}, HTTPOptions, Options),
    ?DEBUG("Response: ~p", [Response]),
    case Response of
        {ok, {{_, 200, _}, _ResHeaders, ResBody}} ->
            Json = jiffy:decode(ResBody, [return_maps]),
            Id = maps:get(<<"sid">>, Json),
            Price = maps:get(<<"amount">>, Json),
            RealPrice = case try string:to_float(binary_to_list(Price))
            catch _:_ -> {error, no_float}
            end of
                {error, _} -> undefined;
                {XX, []} -> abs(XX)
            end,
            GatewayResponse = #gateway_response{gateway_id = Id, gateway = twilio_verify,
                status = accepted, price = RealPrice},
            ok = model_phone:add_gateway_callback_info(GatewayResponse),
            ok;
        {ok, {{_, 404, _}, _ResHeaders, _ResBody}} ->
            ?INFO("Feedback info failed, Phone:~p AttemptId: ~p Response: ~p",
                [Phone, AttemptId, Response]),
            ok;
        _ ->
            ?INFO("Feedback info failed, Phone:~p AttemptId: ~p Response: ~p",
                [Phone, AttemptId, Response]),
            {error, Response}
    end.


-spec fetch_headers() -> list().
fetch_headers() ->
    Headers = fetch_auth_headers(),
    Type = "application/x-www-form-urlencoded",
    [Headers, Type, [], []].


-spec compose_send_body(Phone :: phone(), Code :: binary(), LangId :: binary(), UserAgent :: binary(),
        Method :: string()) -> uri_string:uri_string().
compose_send_body(Phone, Code, LangId, UserAgent, Method) ->
    PlusPhone = "+" ++ binary_to_list(Phone),
    InputParams =[
        {"To", PlusPhone },
        {"Channel", Method},
        {"CustomFriendlyName", get_friendly_name(UserAgent)},
        {"CustomCode", Code},
        {"Locale", get_verify_lang(LangId)}
    ],
    AppHash = case Method of
        "sms" -> util_ua:get_app_hash(UserAgent);
        "call" -> <<"">>
    end,
    InputParams2 = case AppHash of
        <<"">> -> InputParams;
        _ -> InputParams ++ [{"AppHash", binary_to_list(AppHash)}]
    end,
    uri_string:compose_query(InputParams2, [{encoding, utf8}]).

get_friendly_name(UserAgent) ->
    case util_ua:get_app_type(UserAgent) of
        halloapp -> ?HALLOAPP_SENDER_ID;
        katchup -> ?KATCHUP_SENDER_ID;
        _ ->
            ?ERROR("Invalid UA: ~p", [UserAgent]),
            ?HALLOAPP_SENDER_ID
    end.


-spec compose_feedback_body() -> uri_string:uri_string().
compose_feedback_body() ->
    uri_string:compose_query([
        {"Status", <<"approved">>}
    ], [{encoding, utf8}]).


-spec fetch_tokens() -> {string(), string()}.
fetch_tokens() ->
    % TODO: reuse this function from twilio module
    Json = jiffy:decode(binary_to_list(mod_aws:get_secret(<<"Twilio">>)), [return_maps]),
    {binary_to_list(maps:get(<<"account_sid">>, Json)),
     binary_to_list(maps:get(<<"auth_token">>, Json))}.


-spec fetch_auth_headers() -> [{string(), string()}].
fetch_auth_headers() ->
    {AccountSid, AuthToken} = fetch_tokens(),
    AuthStr = base64:encode_to_string(AccountSid ++ ":" ++ AuthToken),
    [{"Authorization", "Basic " ++ AuthStr}].


-spec normalized_status(Status :: binary()) -> atom().
normalized_status(<<"approved">>) ->
    accepted;
normalized_status(<<"pending">>) ->
    queued;
normalized_status(<<"canceled">>) ->
    failed;
normalized_status(_) ->
    unknown.


-spec get_latest_verify_info(AllVerifyInfoList :: list()) -> list().
get_latest_verify_info(AllVerifyInfoList) ->
    TwilioVerifyList = lists:dropwhile(
        fun(Info) ->
            Info#verification_info.gateway =/= <<"twilio_verify">>
        end, lists:reverse(AllVerifyInfoList)),
    Deadline = util:now() - ?TTL_SMS_SID,
    case TwilioVerifyList of
        [] -> [];
        _ ->
            [Latest | _Rest] = TwilioVerifyList,
            #verification_info{attempt_id = AttemptId, sid = Sid, ts = Timestamp, status = Status} = Latest,
            % If status is accepted, approval was previously sent - avoid duplicate feedback
            case Deadline < Timestamp andalso Status =/= <<"accepted">> of
                true -> [AttemptId, Sid];
                false -> []
            end
    end.


%% Doc: https://www.twilio.com/docs/verify/supported-languages
-spec get_verify_lang(LangId :: binary()) -> string().
get_verify_lang(LangId) ->
    VerifyLangMap = get_verify_lang_map(),
    util_gateway:get_gateway_lang(LangId, VerifyLangMap, ?TWILIO_VERIFY_ENG_LANG_ID).


get_verify_lang_map() ->
    #{
        %% Afrikaans
        <<"af">> => "af",
        %% Arabic
        <<"ar">> => "ar",
        %% Catalan
        <<"ca">> => "ca",
        %% Chinese (Simplified using mainland terms)
        <<"zh-CN">> => "zh-CN",
        %% Chinese (Simplified using Hong Kong terms)
        <<"zh-HK">> => "zh-HK",
        %% Chinese (Simplified using mainland terms) - fallback
        <<"zh">> => "zh",
        %% Croatian
        <<"hr">> => "hr",
        %% Czech
        <<"cs">> => "cs",
        %% Danish
        <<"da">> => "da",
        %% Dutch
        <<"nl">> => "nl",
        %% English (American)
        <<"en-US">> => "en",
        %% English (British)
        <<"en-GB">> => "en-GB",
        %% English (American) - fallback
        <<"en">> => "en",
        %% Finnish
        <<"fi">> => "fi",
        %% French
        <<"fr">> => "fr",
        %% German
        <<"de">> => "de",
        %% Greek
        <<"el">> => "el",
        %% Hebrew
        <<"he">> => "he",
        %% Hindi
        <<"hi">> => "hi",
        %% Hungarian
        <<"hu">> => "hu",
        %% Indonesian
        <<"id">> => "id",
        %% Italian
        <<"it">> => "it",
        %% Japanese
        <<"ja">> => "ja",
        %% Korean
        <<"ko">> => "ko",
        %% Malay
        <<"ms">> => "ms",
        %% Norwegian
        <<"nb">> => "nb",
        %% Polish
        <<"pl">> => "pl",
        %% Portuguese - Brazil
        <<"pt-BR">> => "pt-BR",
        %% Portuguese
        <<"pt-PT">> => "pt",
        %% Portuguese - fallback
        <<"pt">> => "pt",
        %% Romanian
        <<"ro">> => "ro",
        %% Russian
        <<"ru">> => "ru",
        %% Spanish
        <<"es">> => "es",
        %% Swedish
        <<"sv">> => "sv",
        %% Tagalog
        <<"tl">> => "tl",
        %% Thai
        <<"th">> => "th",
        %% Turkish
        <<"tr">> => "tr",
        %% Vietnamese
        <<"vi">> => "vi"
    }.

