%%%-------------------------------------------------------------------
%%% @author vipin
%%% @copyright (C) 2022, Halloapp Inc.
%%%-------------------------------------------------------------------
-module(otp_checker_google).
-author("vipin").
-behavior(otp_checker).

-include("logger.hrl").
-include("sms.hrl").

%% API
-export([
    check_otp_request/6,
    otp_delivered/4
]).


check_otp_request(Phone, IP, _UserAgent, _Method, Protocol, _RemoteStaticKey) ->
    Result = util_sms:is_google_request(Phone, IP, Protocol),
    case Result of
        true -> allow;
        false -> ok
    end.

otp_delivered(_Phone, _ClientIP, _Protocol, _RemoteStaticKey) ->
    ok.

