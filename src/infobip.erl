%%%-------------------------------------------------------------------
%%% @copyright (C) 2021, HalloApp, Inc
%%% @doc
%%% SMS module with helper functions to send SMS messages.
%%% @end
%%%-------------------------------------------------------------------
-module(infobip).
-behavior(mod_sms).
-author(nikola).
-include("logger.hrl").
-include("ha_types.hrl").
-include("sms.hrl").

%% API
-export([
    init/0,
    can_send_sms/1,
    can_send_voice_call/1,
    send_sms/4,
    send_voice_call/4,
    normalized_status/1,
    get_api_key/0,
    send_feedback/2,
    compose_body/2     %% for debugging
]).

-define(BASE_SMS_URL, "https://k36v11.api.infobip.com/sms/2/text/advanced").
-define(CALLBACK_URL, "https://api.halloapp.net/api/smscallback/infobip").

init() ->
    ok.
%%    FromPhoneList = [],
%%    util_sms:init_helper(infobip_options, FromPhoneList).


-spec can_send_sms(CC :: binary()) -> boolean().
can_send_sms(_CC) ->
    false.
-spec can_send_voice_call(CC :: binary()) -> boolean().
can_send_voice_call(_CC) ->
    false.

%%Example request
%%POST /sms/2/text/single
%%Host: k36v11.api.infobip.com
%%Authorization: App 86...
%%Content-Type: application/json
%%Accept: application/json
%%
%%{
%%"from":"447491163443",
%%"to":"12066585586",
%%"text":"Hello Nikola"
%%}

%% Example response
%%{
%%"messages": [
%%{
%%"to": "12066585586",
%%"status": {
%%"groupId": 1,
%%"groupName": "PENDING",
%%"id": 26,
%%"name": "PENDING_ACCEPTED",
%%"description": "Message sent to next instance"
%%},
%%"messageId": "33053596995305284925"
%%}
%%]
%%}
-spec send_sms(Phone :: phone(), Code :: binary(), LangId :: binary(), UserAgent :: binary()) ->
    {ok, gateway_response()} | {error, sms_fail, retry | no_retry}.
send_sms(Phone, Code, LangId, UserAgent) ->
    {Msg, _TranslatedLangId} = util_sms:get_sms_message(UserAgent, Code, LangId),

    ?INFO("Phone: ~p, Msg: ~p", [Phone, Msg]),
    URL = ?BASE_SMS_URL,
    Headers = [
        {"Authorization", "App " ++ get_api_key()},
        {"Content-Type", "application/json"},
        {"Accept", "application/json"}
    ],
    Type = "application/json",
    Body = compose_body(Phone, Msg),
    ?DEBUG("Body: ~p", [Body]),
    HTTPOptions = [],
    Options = [],
    Response = httpc:request(post, {URL, Headers, Type, Body}, HTTPOptions, Options),
    ?DEBUG("Response: ~p", [Response]),
    case Response of
        {ok, {{_, 200, _}, _ResHeaders, ResBody}} ->
            Json = jiffy:decode(ResBody, [return_maps]),
            [Message] = maps:get(<<"messages">>, Json),
            Id = maps:get(<<"messageId">>, Message),
            StatusObj = maps:get(<<"status">>, Message),
            StatusGroupName = maps:get(<<"groupName">>, StatusObj),
            StatusName = maps:get(<<"name">>, StatusObj),
            StatusDesc = maps:get(<<"description">>, StatusObj),
            Status = normalized_status(StatusGroupName),
            OkResponse = {ok, #gateway_response{gateway_id = Id, status = Status, response = ResBody}},
            FailedResponse = {error, sms_fail, retry},
            ?INFO("SMS to Phone: ~s ~p:~p Id: ~p", [Phone, StatusGroupName, StatusName, Id]),
            case Status of
                accepted -> OkResponse;
                delivered -> OkResponse;
                _ ->
                    ?INFO("Sending SMS failed Phone: ~s ~p:~p Desc: ~p response: ~p (retry)",
                        [Phone, StatusGroupName, StatusName, StatusDesc, ResBody]),
                    FailedResponse
            end;
        {ok, {{_, ResponseCode, _}, _ResHeaders, _ResBody}} when ResponseCode >= 400 ->
            ?ERROR("Sending SMS failed, Phone: ~s Code ~p, response ~p (retry)", [Phone, ResponseCode, Response]),
            {error, sms_fail, retry};
        _ ->
            ?ERROR("Sending SMS failed, Phone: ~s (retry) ~p", [Phone, Response]),
            {error, sms_fail, retry}
    end.

-spec send_voice_call(Phone :: phone(), Code :: binary(), LangId :: binary(), UserAgent :: binary()) ->
    {ok, gateway_response()} | {error, voice_call_fail, retry | no_retry}.
send_voice_call(Phone, _Code, _LangId, _UserAgent) ->
    ?ERROR("Infobip voice calls are not implemented. Phone: ~s", [Phone]),
    {error, voice_call_fail, retry}.

-spec normalized_status(Status :: binary()) -> atom().
normalized_status(<<"PENDING">>) ->
    accepted;
normalized_status(<<"UNDELIVERABLE">>) ->
    undelivered;
normalized_status(<<"DELIVERED">>) ->
    delivered;
normalized_status(<<"EXPIRED">>) ->
    failed;
normalized_status(<<"REJECTED">>) ->
    failed;
normalized_status(_) ->
    unknown.

-spec get_api_key() -> string().
get_api_key() ->
    mod_aws:get_secret_value(<<"Infobip">>, <<"api_key">>).

-spec compose_body(Phone :: phone(), Message :: binary()) -> Body :: string().
compose_body(Phone, Message) ->
    PlusPhone = "+" ++ binary_to_list(Phone),
    jiffy:encode(#{
        messages => [#{
            from => <<"HalloApp">>, % TODO: maybe do phone numbers?
            destinations => [#{to => util:to_binary(PlusPhone)}],
            text => util:to_binary(Message),
            notifyUrl => ?CALLBACK_URL,
            notifyContentType => <<"application/json">>
    }]}).


% Todo: Implement if sending feedback back to mbird
-spec send_feedback(Phone :: phone(), AllVerifyInfo :: list()) -> ok.
send_feedback(_Phone, _AllVerifyInfo) ->
    ok.

