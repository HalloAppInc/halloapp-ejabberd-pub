%%%-------------------------------------------------------------------
%%% @author nikola
%%% @copyright (C) 2021, Halloapp Inc.
%%% @doc
%%%
%%% @end
%%% Created : 16. Sep 2021 12:32 PM
%%%-------------------------------------------------------------------
-module(otp_checker_phone_tests).
-author("nikola").

-include("sms.hrl").
-include_lib("eunit/include/eunit.hrl").


simple_test() ->
    ?assert(true).


is_too_soon_test() ->
    Now = util:now(),

    false = otp_checker_phone:is_too_soon(sms, []),
    OldResponses = [#gateway_response{method = sms, attempt_ts = util:to_binary(Now - 10), status = sent}],
    %% Need 30 seconds gap.
    {true, _} = otp_checker_phone:is_too_soon(sms, OldResponses),
    OldResponses1 = [#gateway_response{method = sms, attempt_ts = util:to_binary(Now - 30 * ?SECONDS)}],
    false = otp_checker_phone:is_too_soon(sms, OldResponses1),

    OldResponses2 = [#gateway_response{method = sms, attempt_ts = util:to_binary(Now - 50 * ?SECONDS), status = sent},
        #gateway_response{method = sms, attempt_ts = util:to_binary(Now - 21 * ?SECONDS), status = sent}],
    %% Need 60 seconds gap.
    {true, _} = otp_checker_phone:is_too_soon(sms, OldResponses2),
    OldResponses3 = [#gateway_response{method = sms, attempt_ts = util:to_binary(Now - 120 * ?SECONDS)},
        #gateway_response{method = sms, attempt_ts = util:to_binary(Now - 60 * ?SECONDS)}],
    false = otp_checker_phone:is_too_soon(sms, OldResponses3),

    % blocked because no voice call before sms
    block = otp_checker_phone:is_too_soon(voice_call, []),
    OldResponses4 = [#gateway_response{method = voice_call, attempt_ts = util:to_binary(Now - 10), status = sent}],

    % still not sms
    block = otp_checker_phone:is_too_soon(voice_call, OldResponses4).
