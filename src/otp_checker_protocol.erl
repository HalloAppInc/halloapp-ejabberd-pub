%%%-------------------------------------------------------------------
%%% @author vipin
%%% @copyright (C) 2022, Halloapp Inc.
%%%-------------------------------------------------------------------
-module(otp_checker_protocol).
-author("vipin").
-behavior(otp_checker).

-include("logger.hrl").
-include("sms.hrl").

%% API
-export([
    check_otp_request/6,
    otp_delivered/4
]).



check_otp_request(_Phone, _IP, _UserAgent, _Method, noise, _RemoteStaticKey) ->
    ok;
check_otp_request(_Phone, _IP, _UserAgent, _Method, https, _RemoteStaticKey) ->
    {block, protocol_block, none};
check_otp_request(_Phone, _IP, _UserAgent, _Method, _Protocol, _RemoteStaticKey) ->
    {block, undefined_protocol, none}.

otp_delivered(_Phone, _ClientIP, _Protocol, _RemoteStaticKey) ->
    ok.

