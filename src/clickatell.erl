%%%-------------------------------------------------------------------
%%% @copyright (C) 2021, HalloApp, Inc
%%% @doc
%%% SMS module with helper functions to send SMS messages.
%%% @end
%%%-------------------------------------------------------------------
-module(clickatell).
-behavior(mod_sms).
-author(vipin).
-include("logger.hrl").
-include("clickatell.hrl").
-include("ha_types.hrl").
-include("sms.hrl").


%% API
-export([
    init/0,
    can_send_sms/1,
    can_send_voice_call/1,
    send_sms/4,
    send_voice_call/4,
    send_feedback/2,
    compose_body/2,     %% for debugging
    normalized_status/1
]).

init() ->
    FromPhoneList = ["12026842029"],
    util_sms:init_helper(clickatell_options, FromPhoneList).

-spec can_send_sms(CC :: binary()) -> boolean().
can_send_sms(CC) ->
    case CC of
        <<"BY">> -> false;     %% Belarus
        <<"CN">> -> false;     %% China
        <<"CU">> -> false;     %% Cuba
        <<"EG">> -> false;     %% Egypt
        <<"GH">> -> false;     %% Ghana
        <<"IN">> -> false;     %% India
        <<"ID">> -> false;     %% Indonesia
        <<"IR">> -> false;     %% Iran
        <<"JO">> -> false;     %% Jordan
        <<"KE">> -> false;     %% Kenya
        <<"KW">> -> false;     %% Kuwait
        <<"MW">> -> false;     %% Malawi
        <<"MA">> -> false;     %% Morocco
        <<"NG">> -> false;     %% Nigeria
        <<"OM">> -> false;     %% Oman
        <<"PK">> -> false;     %% Pakistan
        <<"PH">> -> false;     %% Philippines
        <<"QA">> -> false;     %% Qatar
        <<"RO">> -> false;     %% Romania
        <<"RU">> -> false;     %% Russia
        <<"SA">> -> false;     %% Saudi Arabia
        <<"LK">> -> false;     %% Sri Lanka
        <<"TZ">> -> false;     %% Tanzania
        <<"TH">> -> false;     %% Thailand
        <<"TR">> -> false;     %% Turkey
        <<"AE">> -> false;     %% UAE
        <<"US">> -> false;     %% USA
        <<"VN">> -> false;     %% Vietnam
        _ -> true
    end.

-spec can_send_voice_call(CC :: binary()) -> boolean().
can_send_voice_call(_CC) ->
    % TODO: Voice calls are not implemented yet.
    false.

%% https://docs.clickatell.com/channels/sms-channels/sms-api-reference/#operation/sendMessageREST_1
-spec send_sms(Phone :: phone(), Code :: binary(), LangId :: binary(), UserAgent :: binary()) ->
        {ok, gateway_response()} | {error, sms_fail, retry | no_retry}.
send_sms(Phone, Code, LangId, UserAgent) ->
    {SmsMsgBin, _TranslatedLangId} = mod_translate:translate(<<"server.sms.verification">>, LangId),
    AppHash = util_ua:get_app_hash(UserAgent),
    Msg = io_lib:format("~s: ~s~n~n~n~s", [SmsMsgBin, Code, AppHash]),

    ?INFO("Phone: ~p, Msg: ~p", [Phone, Msg]),
    URL = ?BASE_SMS_URL,
    Headers = [{"X-Version", "1"}, {"Authorization", "bearer " ++ get_auth_token()}],
    Type = "application/json",
    Body = compose_body(Phone, Msg),
    ?DEBUG("Body: ~p", [Body]),
    HTTPOptions = [],
    Options = [],
    Response = httpc:request(post, {URL, Headers, Type, Body}, HTTPOptions, Options),
    ?DEBUG("Response: ~p", [Response]),
    case Response of
        {ok, {{_, 202, _}, _ResHeaders, ResBody}} ->
            Json = jiffy:decode(ResBody, [return_maps]),
            Data = maps:get(<<"data">>, Json),
            Messages = maps:get(<<"message">>, Data),
            [Message] = Messages,
            Id = maps:get(<<"apiMessageId">>, Message),
            Status = case maps:get(<<"accepted">>, Message) of
                true -> accepted;
                false -> undelivered
            end,
            %% TODO: Inspect error codes.
            %% https://www.clickatell.com/developers/api-documentation/error-codes/
            ErrorCode = maps:get(<<"errorCode">>, Message, undefined),
            Error = maps:get(<<"error">>, Message, undefined),
            ErrorDescr = maps:get(<<"errorDescription">>, Message, undefined),
            ?INFO("SMS to Phone: ~p, gw: clickatell, Status: ~p, Id: ~p, ErrorCode: ~p, Error: ~p, "
                "Error descr: ~p", [Phone, Status, Id, ErrorCode, Error, ErrorDescr]),
            case Status of
                accepted ->
                    {ok, #gateway_response{gateway_id = Id, status = Status, response = ResBody}};
                _ ->
                    {error, sms_fail, retry}
            end;
        {ok, {{_, HttpStatus, _}, _ResHeaders, _ResBody}}->
            ?ERROR("Sending SMS failed Phone:~p, HTTPCode: ~p, response ~p",
                [Phone, HttpStatus, Response]),
            {error, sms_fail, retry};
        _ ->
            % TODO: In all the gateways we don't retry in this case. But I'm not sure why.
            ?ERROR("Sending SMS failed Phone:~p (no_retry) ~p",
                [Phone, Response]),
            {error, sms_fail, no_retry}
    end.

% TODO: Does not support voice calls yet
send_voice_call(Phone, _Code, _LangId, _UserAgent) ->
    ?ERROR("Clickatell voice calls are not implemented. Phone: ~s", [Phone]),
    {error, voice_call_fail, retry}.

%% https://www.clickatell.com/developers/api-documentation/message-status-codes/
-spec normalized_status(StatusCode :: integer()) -> atom().
normalized_status(1) ->
    unknown;
normalized_status(2) ->
    queued;
normalized_status(3) ->
    delivered;
normalized_status(4) ->
    delivered;
normalized_status(5) ->
    failed;
normalized_status(6) ->
    canceled;
normalized_status(7) ->
    failed;
normalized_status(9) ->
    failed;
normalized_status(10) ->
    undelivered;
normalized_status(11) ->
    queued;
normalized_status(12) ->
    failed;
normalized_status(13) ->
    canceled;
normalized_status(14) ->
    undelivered;
normalized_status(_) ->
    unknown.

-spec get_auth_token() -> string().
get_auth_token() ->
    mod_aws:get_secret_value(<<"Clickatell">>, <<"auth_token">>).

%% `from` and `mo` weren't found in the actual documentation.
%% https://stackoverflow.com/questions/36584831/clickatell-http-api-send-message-fails-with-routing-error-status-9
%% `callback` = `7` indicates to clickatell to return all 7 parameters in the callback
-spec compose_body(Phone, Message) -> Body when
    Phone :: phone(),
    Message :: string(),
    Body :: string().
compose_body(Phone, Message) ->
    Mp = #{
       <<"to">> => [Phone],
       <<"from">> => util:to_binary(get_originator()),
       <<"text">> => util:to_binary(Message),
       <<"mo">> => <<"1">>,
       <<"callback">> => <<"7">>
    },
    jiffy:encode(Mp).

-spec get_originator() -> string().
get_originator() ->
    get_from_phone().

get_from_phone() ->
    util_sms:lookup_from_phone(clickatell_options).

% TODO: Implement if sending feedback back to gateway
-spec send_feedback(Phone :: phone(), AllVerifyInfo :: list()) -> ok.
send_feedback(_Phone, _AllVerifyInfo) ->
    ok. 

