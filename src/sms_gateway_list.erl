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
    twilio_verify,
    mbird,
    mbird_verify,
    vonage,
    vonage_verify,
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

-define(EXTERNAL_CODE_GATEWAYS, [
    vonage_verify,
    mbird_verify
]).

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
uses_external_code(vonage_verify) -> true;
uses_external_code(mbird_verify) -> true;
uses_external_code(X) when is_binary(X) -> uses_external_code(util:to_atom(X));
uses_external_code(_) -> false. 
