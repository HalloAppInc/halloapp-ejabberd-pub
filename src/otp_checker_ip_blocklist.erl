%%%-------------------------------------------------------------------
%%% @author nikola
%%% @copyright (C) 2021, Halloapp Inc.
%%% @doc
%%%
%%% @end
%%% Created : 15. Sep 2021 2:25 PM
%%%-------------------------------------------------------------------
-module(otp_checker_ip_blocklist).
-author("nikola").
-behavior(otp_checker).

-include("time.hrl").
-include("logger.hrl").

-define(BLOCK_IP_BACKOFF_TIME, 12 * ?HOURS).

%% API
-export([
    check_otp_request/6,
    is_blocked/1,
    otp_delivered/4
]).

% see spec in otp_checker
check_otp_request(_Phone, IP, _UserAgent, _Method, _Protocol, _RemoteStaticKey) ->
    case is_blocked(IP) of
        true -> {block, ip_blocklist, undefined};
        false -> ok
    end.


-spec is_blocked(IP :: binary()) -> boolean().
%% Never block our relay registration requests by ip address.
is_blocked(<<"15.188.48.215">>) -> false;
is_blocked(IP) ->
    CurrentTs = util:now(),
    case model_ip_addresses:is_ip_blocked(IP) of
        false -> false;
        {true, undefined} ->
            model_ip_addresses:record_blocked_ip_address(IP, CurrentTs),
            false;
        {true, Timestamp} ->
            %% IP is in our blocklist - so allow only 1 per block_ip_backoff_time.
            TimeDiff = CurrentTs - Timestamp - ?BLOCK_IP_BACKOFF_TIME,
            case TimeDiff >= 0 of
                true ->
                    model_ip_addresses:record_blocked_ip_address(IP, CurrentTs),
                    false;
                false ->
                    true
            end
    end.


otp_delivered(Phone, IP, _Protocol, _RemoteStaticKey) ->
    % check if users are able to register from blocked ips
    case model_ip_addresses:is_ip_blocked(IP) of
        {true, _} ->
            ?ERROR("OTP delivered to Phone ~s on blocklisted IP ~p", [Phone, IP]);
        false -> ok
    end,
    model_ip_addresses:clear_blocked_ip_address(IP).

