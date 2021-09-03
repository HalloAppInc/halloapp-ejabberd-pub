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
    can_send_sms/1,
    can_send_voice_call/1,
    send_sms/4,
    send_voice_call/4,
    send_feedback/2,
    compose_body/3     %% for debugging
]).

init() ->
    ok.

-spec can_send_sms(CC :: binary()) -> boolean().
can_send_sms(_CC) ->
    % TODO: This gateway is disabled for now. We will enable it slowly
    false.
-spec can_send_voice_call(CC :: binary()) -> boolean().
can_send_voice_call(_CC) ->
    % TODO: Voice calls are not implemented yet.
    false.

%% https://enterprise.telesign.com/api-reference/apis/sms-verify-api/reference/post-verify-sms
-spec send_sms(Phone :: phone(), Code :: binary(), LangId :: binary(), UserAgent :: binary()) ->
        {ok, gateway_response()} | {error, sms_fail, retry | no_retry}.
send_sms(Phone, Code, LangId, UserAgent) ->
    {SmsMsgBin, _TranslatedLangId} = mod_translate:translate(<<"server.sms.verification">>, LangId),
    AppHash = util_ua:get_app_hash(UserAgent),
    Msg = io_lib:format("~s: $$CODE$$~n~n~n~s", [SmsMsgBin, AppHash]),

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
            Code2 = maps:get(<<"code">>, Status),
            Status2 = normalized_status(Code2),
            {ok, #gateway_response{gateway_id = Id, status = Status2, response = ResBody}};
        {ok, {{_, HttpStatus, _}, _ResHeaders, ResBody}}->
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
    ?ERROR("Telesign voice calls are not implemented. Phone: ~s", [Phone]),
    {error, voice_call_fail, retry}.

-spec normalized_status(Code :: integer()) -> atom().
normalized_status(200) ->
    delivered;
normalized_status(203) ->
    sent;
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
    CustomerId = get_secret(<<"Telesign">>, <<"customer_id">>),
    ApiKey = get_secret(<<"Telesign">>, <<"api_key">>),
    util:to_list(base64:encode(<<CustomerId/binary, <<":">>/binary, ApiKey/binary>>)).
    

-spec get_secret(Name :: binary(), Key :: binary()) -> string().
get_secret(Name, Key) ->
    Json = jiffy:decode(binary_to_list(mod_aws:get_secret(Name)), [return_maps]),
    maps:get(Key, Json).

-spec compose_body(Phone, Template, Code) -> Body when
    Phone :: phone(),
    Template :: string(),
    Code :: string(),
    Body :: uri_string:uri_string().
compose_body(Phone, Template, Code) ->
    uri_string:compose_query([
        {"phone_number", Phone},
        {"verify_code", Code},
        {"template", Template}
    ], [{encoding, latin1}]).

-spec get_originator() -> string().
get_originator() ->
    get_from_phone().

get_from_phone() ->
    util_sms:lookup_from_phone(clickatell_options).

% TODO: Implement if sending feedback back to gateway
-spec send_feedback(Phone :: phone(), AllVerifyInfo :: list()) -> ok.
send_feedback(_Phone, _AllVerifyInfo) ->
    ok. 

