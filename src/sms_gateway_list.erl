%%%-------------------------------------------------------------------
%%% @author vipin
%%% @copyright (C) 2021, HalloApp, Inc
%%% @doc
%%% List of valid SMS Gateways.
%%% @end
%%%-------------------------------------------------------------------
-module(sms_gateway_list).
-author("vipin").

-export([
    all/0,
    enabled/0
]).

-define(ALL_GATEWAYS, [
    twilio,
    twilio_verify,
    mbird,
    mbird_verify,
    vonage,
    infobip,
    telesign,
    clickatell,
    mod_sms_app
]).


-define(ENABLED_GATEWAYS, [
    twilio,
    mbird,
    twilio_verify,
    mbird_verify,
    telesign,
    clickatell
]).

% Returns list of all gateways
-spec all() -> [atom()].
all() ->
    ?ALL_GATEWAYS.

%% Returns gateways we currently use in production
-spec enabled() -> [atom()].
enabled() ->
    ?ENABLED_GATEWAYS.

