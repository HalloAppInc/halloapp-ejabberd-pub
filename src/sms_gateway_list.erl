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
    get_sms_gateway_list/0
]).

%% Allows ability to turn off specific gateways.
-spec get_sms_gateway_list() -> [atom()].
get_sms_gateway_list() ->
    [twilio, mbird].

