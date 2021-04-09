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

%% API
-export([
    send_sms/2,
    send_voice_call/2,
    normalized_status/1,
    compose_voice_body/2  %% for debugging
]).

-spec send_sms(Phone :: phone(), Msg :: string()) -> {ok, sms_response()} | {error, sms_fail}.
send_sms(Phone, Msg) ->
    ?INFO("Phone: ~p, Msg: ~s", [Phone, Msg]),
    URL = ?BASE_SMS_URL,
    Headers = [{"Authorization", "AccessKey " ++ get_access_key()}],
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
            {ok, #sms_response{sms_id = Id, status = Status, response = ResBody}};
        _ ->
            ?ERROR("Sending SMS failed ~p", [Response]),
            {error, sms_fail}
    end.

-spec send_voice_call(Phone :: phone(), Msg :: string()) -> {ok, sms_response()} | {error, voice_call_fail}.
send_voice_call(Phone, Msg) ->
    ?INFO("Phone: ~p, Msg: ~s", [Phone, Msg]),
    URL = ?BASE_VOICE_URL,
    Headers = [{"Authorization", "AccessKey " ++ get_access_key()}],
    Type = "application/json",
    Body = compose_voice_body(Phone, Msg),
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
            {ok, #sms_response{sms_id = Id, status = Status, response = ResBody}};
        _ ->
            ?ERROR("Sending Voice Call failed ~p", [Response]),
            {error, voice_call_fail}
    end.

-spec normalized_status(Status :: binary()) -> atom().
normalized_status(<<"scheduled">>) ->
    accepted;
normalized_status(<<"buffered">>) ->
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

-spec get_access_key() -> string().
get_access_key() ->
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
    ], [{encoding, utf8}]).

-spec compose_voice_body(Phone, Message) -> Body when
    Phone :: phone(),
    Message :: string(),
    Body :: uri_string:uri_string().
compose_voice_body(Phone, Message) ->
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
                    <<"voice">> => <<"male">>,
                    <<"language">> => <<"en-US">>
                }
            }]
        }
    },
    binary_to_list(jiffy:encode(Body)).


get_from_phone(Phone) ->
    case mod_libphonenumber:get_cc(Phone) of
        <<"CA">> -> ?FROM_PHONE_FOR_CANADA;
        _ -> ?FROM_PHONE_FOR_REST
    end.

