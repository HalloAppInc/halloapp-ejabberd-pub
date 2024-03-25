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
    enabled/0,
    external_code_gateways/0,
    uses_external_code/1
]).

-define(ALL_GATEWAYS, [
    twilio,
    twilio_verify
]).


-define(ENABLED_GATEWAYS, [
    twilio,
    twilio_verify
]).

-define(EXTERNAL_CODE_GATEWAYS, []).

% Returns list of all gateways
-spec all() -> [atom()].
all() ->
    ?ALL_GATEWAYS.

%% Returns gateways we currently use in production
-spec enabled() -> [atom()].
enabled() ->
    ?ENABLED_GATEWAYS.

-spec external_code_gateways() -> [atom()].
external_code_gateways() ->
    ?EXTERNAL_CODE_GATEWAYS.


-spec uses_external_code(Gateway :: term()) -> boolean().
uses_external_code(_) -> false.
