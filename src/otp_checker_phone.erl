%%%-------------------------------------------------------------------
%%% @author nikola
%%% @copyright (C) 2021, Halloapp Inc.
%%% @doc
%%%
%%% @end
%%% Created : 15. Sep 2021 3:18 PM
%%%-------------------------------------------------------------------
-module(otp_checker_phone).
-author("nikola").
-behavior(otp_checker).

-incldue("ha_types.hrl").
-include("logger.hrl").
-include("sms.hrl").

%% API
-export([
    check_otp_request/6,
    otp_delivered/4,
    is_too_soon/2
]).


check_otp_request(Phone, _IP, UserAgent, Method, _Protocol, _RemoteStaticKey) ->
    AppType = util_ua:get_app_type(UserAgent),
    case check_otp_request_too_soon(Phone, AppType, Method) of
        false -> ok;
        block -> {block, voice_call_before_sms, undefined};
        {true, Seconds} -> {error, retried_too_soon, Seconds}
    end.

otp_delivered(_Phone, _ClientIP, _Protocol, _RemoteStaticKey) ->
    ok.


-spec check_otp_request_too_soon(Phone :: binary(), AppType :: app_type(), Method :: atom()) -> block | false | {true, integer()}.
check_otp_request_too_soon(Phone, AppType, Method) ->
    Check = case {config:get_hallo_env(), util:is_test_number(Phone)} of
        {prod, true} -> check;
        {prod, _} -> check;
        {stress, _} -> check;
        {_, _} -> ok
    end,
    case Check of
        ok -> false;
        check ->
            {ok, OldResponses} = model_phone:get_all_gateway_responses(Phone, AppType),
            is_too_soon(Method, OldResponses)
    end.


-spec is_too_soon(Method :: atom(), OldResponses :: [gateway_response()]) -> block | false | {true, integer()}.
is_too_soon(Method, OldResponses) ->
    ReverseOldResponses = lists:reverse(OldResponses),
    SmsResponses = lists:filter(
        fun(#gateway_response{method = Method2}) ->
            Method2 =/= voice_call
        end, ReverseOldResponses),
    ?DEBUG("Sms: ~p", [SmsResponses]),
    Len = length(SmsResponses),
    case {Method, Len} of
        {voice_call, 0} ->
            ?INFO("Rejecting: ~p, Prev non voice len: ~p, OldResponses: ~p", [Method, Len, OldResponses]),
            block;
        {_, _} ->
            NextTs = mod_sms:find_next_ts(OldResponses),
            case NextTs > util:now() of
                true -> {true, NextTs - util:now()};
                false -> false
            end
    end.
