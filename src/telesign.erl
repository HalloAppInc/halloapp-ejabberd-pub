%%%-------------------------------------------------------------------
%%% @copyright (C) 2021, HalloApp, Inc
%%% @doc
%%% SMS module with helper functions to send SMS messages.
%%% @end
%%%-------------------------------------------------------------------
-module(telesign).
-behavior(mod_sms).
-author(vipin).
-include("logger.hrl").
-include("telesign.hrl").
-include("ha_types.hrl").
-include("sms.hrl").


%% API
-export([
    init/0,
    can_send_sms/2,
    can_send_voice_call/2,
    send_sms/4,
    send_voice_call/4,
    send_feedback/2,
    compose_body/3,     %% for debugging
    normalized_status/1
]).

init() ->
    ok.

-spec can_send_sms(AppType :: maybe(app_type()), CC :: binary()) -> boolean().
can_send_sms(katchup, _CC) -> false;
can_send_sms(_, CC) ->
    case CC of
        <<"BE">> -> false;     %% Belgium
        <<"CN">> -> false;     %% China
        <<"SA">> -> false;     %% Saudi Arabia
        <<"VN">> -> false;     %% Vietnam
        _ -> true
    end.

-spec can_send_voice_call(AppType :: maybe(app_type()), CC :: binary()) -> boolean().
can_send_voice_call(_AppType, _CC) ->
    % TODO: Voice calls are not implemented yet.
    false.

%% https://enterprise.telesign.com/api-reference/apis/sms-verify-api/reference/post-verify-sms
-spec send_sms(Phone :: phone(), Code :: binary(), LangId :: binary(), UserAgent :: binary()) ->
        {ok, gateway_response()} | {error, sms_fail, retry | no_retry}.
send_sms(Phone, Code, LangId, UserAgent) ->
    {SmsMsgBin, _TranslatedLangId} = util_sms:resolve_sms_lang(LangId, UserAgent), 
    AppHash = util_ua:get_app_hash(UserAgent),
    Msg = io_lib:format("~ts: $$CODE$$~n~n~n~s", [SmsMsgBin, AppHash]),

    ?INFO("Phone: ~p, Msg: ~p", [Phone, Msg]),
    URL = ?BASE_SMS_URL,
    ?DEBUG("Auth: ~p", [get_auth_token()]),
    Headers = [{"authorization", "Basic " ++ get_auth_token()}],
    Type = "application/x-www-form-urlencoded",
    Body = compose_body(Phone, Msg, Code),
    ?DEBUG("Body: ~p", [Body]),
    HTTPOptions = [],
    Options = [],
    Response = httpc:request(post, {URL, Headers, Type, Body}, HTTPOptions, Options),
    ?DEBUG("Response: ~p", [Response]),
    case Response of
        {ok, {{_, 200, _}, _ResHeaders, ResBody}} ->
            Json = jiffy:decode(ResBody, [return_maps]),
            Id = maps:get(<<"reference_id">>, Json),
            Status = maps:get(<<"status">>, Json),
            StatusCode = maps:get(<<"code">>, Status),
            Status2 = normalized_status(StatusCode),
            OkResponse = {ok, #gateway_response{gateway_id = Id, status = Status2, response = ResBody}},
            FailedResponse = {error, sms_fail, retry},
            case Status2 of
                Status3 when Status3 =:= accepted orelse Status3 =:= queued orelse Status3 =:= sent orelse
                    Status3 =:= delivered ->
                    ?INFO("Success: ~s", [Phone]),
                    OkResponse;
                _ ->
                    ?INFO("Sending SMS failed, Phone: ~s Id: ~s StatusCode: ~p, Status: ~p (retry)",
                          [Phone, Id, StatusCode, Status2]),
                    FailedResponse
            end;
        {ok, {{_, HttpStatus, _}, _ResHeaders, _ResBody}} ->
            ?ERROR("Sending SMS failed Phone:~p (retry), HTTPCode: ~p, response ~p",
                [Phone, HttpStatus, Response]),
            {error, sms_fail, retry};
        _ ->
            ?ERROR("Sending SMS failed Phone:~p (retry) ~p", [Phone, Response]),
            {error, sms_fail, retry}
    end.

% TODO: Does not support voice calls yet
send_voice_call(Phone, _Code, _LangId, _UserAgent) ->
    ?ERROR("Telesign voice calls are not implemented. Phone: ~s", [Phone]),
    {error, voice_call_fail, retry}.

%% https://enterprise.telesign.com/api-reference/apis/sms-verify-api/how-to-guides/verify-by-sms-with-your-own-code
-spec normalized_status(Code :: integer()) -> atom().
normalized_status(200) ->
    delivered;
normalized_status(201) ->
    delivered;
normalized_status(203) ->
    sent;
normalized_status(207) ->
    undelivered;
%% TODO: temporary phone error, maybe retry.
normalized_status(210) ->
    undelivered;
normalized_status(211) ->
    undelivered;
normalized_status(220) ->
    undelivered;
normalized_status(221) ->
    undelivered;
normalized_status(222) ->
    undelivered;
normalized_status(229) ->
    undelivered;
normalized_status(230) ->
    undelivered;
normalized_status(231) ->
    undelivered;
normalized_status(233) ->
    undelivered;
normalized_status(234) ->
    undelivered;
normalized_status(237) ->
    undelivered;
normalized_status(238) ->
    undelivered;
normalized_status(250) ->
    undelivered;
normalized_status(251) ->
    undelivered;
normalized_status(286) ->
    undelivered;
normalized_status(290) ->
    accepted;
normalized_status(291) ->
    queued;
normalized_status(292) ->
    queued;
normalized_status(295) ->
    queued;
normalized_status(_) ->
    unknown.

-spec get_auth_token() -> string().
get_auth_token() ->
    CustomerId = mod_aws:get_secret_value(<<"Telesign">>, <<"customer_id">>),
    ApiKey = mod_aws:get_secret_value(<<"Telesign">>, <<"api_key">>),
    util:to_list(base64:encode(CustomerId ++  ":" ++  ApiKey)).
    
-spec compose_body(Phone :: phone(), Template :: string(), Code :: binary()) -> Body :: uri_string:uri_string().
compose_body(Phone, Template, Code) ->
    SenderId = get_sender_id(Phone),
    uri_string:compose_query([
        {"phone_number", Phone},
        {"sender_id", SenderId},
        {"verify_code", Code},
        {"template", Template}
    ], [{encoding, utf8}]).

% TODO: Implement if sending feedback back to gateway
-spec send_feedback(Phone :: phone(), AllVerifyInfo :: list()) -> ok.
send_feedback(_Phone, _AllVerifyInfo) ->
    ok. 

get_sender_id(Phone) ->
   case mod_libphonenumber:get_cc(Phone) of
        <<"US">> -> ?TFN;
        _ -> ?HALLOAPP_SENDER_ID
    end.

