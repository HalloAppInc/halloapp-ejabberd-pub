%%%-------------------------------------------------------------------
%%% @copyright (C) 2020, HalloApp, Inc
%%% @doc
%%% SMS module with helper functions to send SMS messages.
%%% @end
%%%-------------------------------------------------------------------
-module(mbird).
-behavior(sms_provider).
-author("vipin").
-include("logger.hrl").
-include("mbird.hrl").
-include("ha_types.hrl").

%% API
-export([
    send_sms/2
]).

-spec send_sms(Phone :: phone(), Msg :: string()) -> {ok, binary()} | {error, sms_fail}.
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
            {ok, ResBody};
        _ ->
            ?ERROR("Sending SMS failed ~p", [Response]),
            {error, sms_fail}
    end.

-spec get_access_key() -> string().
get_access_key() ->
    binary_to_list(mod_aws:get_secret(<<"MBird">>)).

-spec compose_body(Phone, Message) -> Body when
    Phone :: phone(),
    Message :: string(),
    Body :: uri_string:uri_string().
compose_body(Phone, Message) ->
    PlusPhone = "+" ++ binary_to_list(Phone),
    uri_string:compose_query([{"recipients", PlusPhone }, {"originator", ?FROM_PHONE},
        {"body", Message}], [{encoding, utf8}]).

