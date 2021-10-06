%%%-------------------------------------------------------------------
%%% @copyright (C) 2021, HalloApp, Inc
%%% @doc
%%% SMS module with helper functions to send SMS messages.
%%% @end
%%%-------------------------------------------------------------------
-module(vonage).
-behavior(mod_sms).
-author(nikola).
-include("logger.hrl").
-include("vonage.hrl").
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
    get_api_secret/0,
    normalized_status/1,
    compose_body/2     %% for debugging
]).

init() ->
    FromPhoneList = ["18445443434"],
    util_sms:init_helper(vonage_options, FromPhoneList).

-spec can_send_sms(CC :: binary()) -> boolean().
can_send_sms(_CC) ->
    % TODO: This gateway is disabled for now. We will enable it slowly
    false.
-spec can_send_voice_call(CC :: binary()) -> boolean().
can_send_voice_call(_CC) ->
    % TODO: Voice calls are not implemented yet.
    false.

-spec send_sms(Phone :: phone(), Code :: binary(), LangId :: binary(), UserAgent :: binary()) ->
        {ok, gateway_response()} | {error, sms_fail, retry | no_retry}.
send_sms(Phone, Code, LangId, UserAgent) ->
    {Msg, _TranslatedLangId} = util_sms:get_sms_message(UserAgent, Code, LangId),

    ?INFO("Phone: ~p, Msg: ~p", [Phone, Msg]),
    URL = ?BASE_SMS_URL,
    Headers = [],
    Type = "application/x-www-form-urlencoded",
    Body = compose_body(Phone, Msg),
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
                {error, Status, ErrorText, Network} ->
                    ?ERROR("SMS send failed: ~p: ~p Network:~p Response: ~p",
                        [Status, ErrorText, Network, Response]),
                    {error, sms_fail, no_retry};
                {ok, MsgId, Price, Network} ->
                    ?INFO("send ok Phone:~p MsgId:~p Price:~p Network:~p",
                        [Phone, MsgId, Price, Network]),
                    {ok, #gateway_response{
                        gateway_id = MsgId,
                        price = Price,
                        currency = <<"EUR">>,
                        status = accepted,
                        response = ResBody}}
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
send_voice_call(_Phone, _Code, _LangId, _UserAgent) ->
    {error, voice_call_fail, retry}.

-spec decode_response(ResBody :: iolist()) -> integer().
decode_response(ResBody) ->
    Json = jiffy:decode(ResBody, [return_maps]),
    Messages = maps:get(<<"messages">>, Json, []),
    case Messages of
        [] -> {error, bad_format};
        [Message] ->
            Status = maps:get(<<"status">>, Message, undefined),
            Network = maps:get(<<"network">>, Message, undefined),
            case Status of
                <<"0">> ->
                    MsgId = maps:get(<<"message-id">>, Message, undefined),
                    Price = maps:get(<<"message-price">>, Message, 0.0),
                    {ok, MsgId, Price, Network};
                _ ->
                    ErrorText = maps:get(<<"error-text">>, Message, <<"">>),
                    {error, Status, ErrorText, Network}
            end
    end.

-spec normalized_status(Status :: binary()) -> atom().
normalized_status(<<"accepted">>) ->
    accepted;
normalized_status(<<"delivered">>) ->
    delivered;
normalized_status(<<"buffered">>) ->
    queued;
normalized_status(<<"expired">>) ->
    failed;
normalized_status(<<"failed">>) ->
    failed;
normalized_status(<<"rejected">>) ->
    failed;
normalized_status(<<"unknown">>) ->
    unknown;
normalized_status(_) ->
    unknown.


-spec get_api_key() -> string().
get_api_key() ->
    mod_aws:get_secret_value(<<"Vonage">>, <<"api_key">>).

-spec get_api_secret() -> string().
get_api_secret() ->
    mod_aws:get_secret_value(<<"Vonage">>, <<"api_secret">>).


-spec compose_body(Phone, Message) -> Body when
    Phone :: phone(),
    Message :: string(),
    Body :: uri_string:uri_string().
compose_body(Phone, Message) ->
    uri_string:compose_query([
        {"to", Phone },
        {"from", get_originator()},
        {"text", Message},
        {"type", "unicode"},
        {"api_key", get_api_key()},
        {"api_secret", get_api_secret()}
    ], [{encoding, unicode}]).

-spec get_originator() -> string().
get_originator() ->
    get_from_phone().

get_from_phone() ->
    util_sms:lookup_from_phone(vonage_options).

% TODO: Implement if sending feedback back to gateway
-spec send_feedback(Phone :: phone(), AllVerifyInfo :: list()) -> ok.
send_feedback(_Phone, _AllVerifyInfo) ->
    ok. 

