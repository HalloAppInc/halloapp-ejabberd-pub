%%%-------------------------------------------------------------------
%%% @author nikola
%%% @copyright (C) 2021, Halloapp Inc.
%%% @doc
%%%
%%% @end
%%% Created : 15. Sep 2021 2:42 PM
%%%-------------------------------------------------------------------
-module(otp_checker_ip).
-author("nikola").
-behavior(otp_checker).

-include("logger.hrl").

-define(IP_BACKOFF_THRESHOLD, 5).
-define(IP_RETURN_ERROR_THRESHOLD, 10).

%% API
-export([
    check_otp_request/6,
    otp_delivered/4
]).


check_otp_request(_Phone, IP, _UserAgent, _Method, _Protocol, _RemoteStaticKey) ->
    CurrentTs = util:now(),
    {ok, {Count, LastTs}} = model_ip_addresses:get_ip_address_info(IP),
    Result = case {Count, LastTs} of
        {undefined, _} ->
            ok;
        {_, undefined} ->
            ok;
        {_, _} when Count =< ?IP_BACKOFF_THRESHOLD ->
            ok;
        {_, _} ->
            NextTs = util_sms:good_next_ts_diff(Count - ?IP_BACKOFF_THRESHOLD) + LastTs,
            case NextTs > CurrentTs of
                true ->
                    case Count > ?IP_RETURN_ERROR_THRESHOLD of
                        true -> {block, ip_block, {IP, Count, LastTs}};
                        false -> {error, retried_too_soon, NextTs - CurrentTs}
                    end;
                false -> ok
            end
    end,
    ok = model_ip_addresses:add_ip_address(IP, CurrentTs),
    Result.


otp_delivered(Phone, IP, _Protocol, _RemoteStaticKey) ->
    {ok, {Count, _LastTs}} = model_ip_addresses:get_ip_address_info(IP),
    case Count =/= undefined andalso Count > ?IP_RETURN_ERROR_THRESHOLD of
        true -> ?ERROR("OTP delivered to Phone ~s but IP ~s has ~s Attempts", [Phone, IP, Count]);
        false -> ok
    end,
    model_ip_addresses:delete_ip_address(IP).
