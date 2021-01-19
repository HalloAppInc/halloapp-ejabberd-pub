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
    send_sms/2
]).

-spec send_sms(Phone :: phone(), Msg :: string()) -> {ok, sms_response()} | {error, sms_fail}.
send_sms(Phone, Msg) ->
    ?INFO("send_sms via MessageBird ~p", [Phone]),
    URL = ?BASE_URL,
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
            Status = maps:get(<<"status">>, Item),
            {ok, #sms_response{sms_id = Id, status = Status, response = ResBody}};
        _ ->
            ?ERROR("Sending SMS failed ~p", [Response]),
            {error, sms_fail}
    end.

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
    %% reference is used during callback. TODO(vipin): Need a more useful ?REFERENCE.
    uri_string:compose_query([
        {"recipients", PlusPhone },
        {"originator", ?FROM_PHONE},
        {"reference", ?REFERENCE},
        {"body", Message}
    ], [{encoding, utf8}]).

