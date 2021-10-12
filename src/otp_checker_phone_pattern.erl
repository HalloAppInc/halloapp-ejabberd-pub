%%%-------------------------------------------------------------------
%%% @author nikola
%%% @copyright (C) 2021, Halloapp Inc.
%%% @doc
%%%
%%% @end
%%% Created : 15. Sep 2021 2:55 PM
%%%-------------------------------------------------------------------
-module(otp_checker_phone_pattern).
-author("nikola").
-behavior(otp_checker).

-include("logger.hrl").

-define(PHONE_PATTERN_BACKOFF_THRESHOLD, 15).

%% API
-export([check_otp_request/6, otp_delivered/4]).


check_otp_request(Phone, _IP, _UserAgent, _Method, Protocol, _RemoteStaticKey) ->
    % TODO: pass the CC as argument
    CC = mod_libphonenumber:get_cc(Phone),
    PhonePattern = extract_phone_pattern(Phone, CC, Protocol),
    ?DEBUG("Phone Pattern: ~p", [PhonePattern]),
    case PhonePattern =:= Phone of
        true -> ok;
        false ->
            case is_phone_pattern_blocked(PhonePattern, CC, Protocol) of
                false -> ok;
                true -> {block, phone_pattern, {PhonePattern}}
            end
    end.


-spec is_phone_pattern_blocked(PhonePattern :: binary(), CC :: binary(), Protocol :: atom()) -> boolean().
is_phone_pattern_blocked(PhonePattern, CC, Protocol) ->
    BackoffThreshold = case Protocol of
        noise -> ?PHONE_PATTERN_BACKOFF_THRESHOLD;
        https -> 0
    end,
    CurrentTs = util:now(),
    {ok, {Count, LastTs}} = model_phone:get_phone_pattern_info(PhonePattern),
    ?DEBUG("PhonePattern: ~p, CC: ~p, Count: ~p, LastTs: ~p, CurrentTs: ~p, BackoffThreshold: ~p",
        [PhonePattern, CC, Count, LastTs, CurrentTs, BackoffThreshold]),
    IsBlocked = case {Count, LastTs} of
        {undefined, _} ->
            false;
        {_, undefined} ->
            false;
        {_, _} when Count =< BackoffThreshold ->
            false;
        {_, _} ->
            NextTs = util_sms:good_next_ts_diff(Count - BackoffThreshold) + LastTs,
            NextTs > CurrentTs
    end,
    case IsBlocked of
        false ->
            % TODO: consider incrementing the counter when we block the request as well.
            ok = model_phone:add_phone_pattern(PhonePattern, CurrentTs),
            false;
        true -> true
    end.

% TODO: maybe better to organaize thie countries in a high risk country list.
extract_phone_pattern(Phone, CC, Protocol) ->
    TruncateLen = case {CC, Protocol =:= https} of
        {<<"AD">>, true} -> 7;
        {<<"AF">>, true} -> 7;
        {<<"AZ">>, true} -> 7;
        {<<"BE">>, true} -> 7;
        {<<"BF">>, true} -> 7;
        {<<"BS">>, true} -> 7;
        {<<"BY">>, true} -> 7;
        {<<"CH">>, true} -> 7;
        {<<"CW">>, true} -> 7;
        {<<"EE">>, true} -> 7;
        {<<"ES">>, true} -> 7;
        {<<"GB">>, true} -> 7;
        {<<"GW">>, true} -> 7;
        {<<"GN">>, true} -> 7;
        {<<"GG">>, true} -> 7;
        {<<"DZ">>, true} -> 7;
        {<<"IQ">>, true} -> 7;
        {<<"IR">>, true} -> 7;
        {<<"KG">>, true} -> 7;
        {<<"KZ">>, true} -> 7;
        {<<"KW">>, true} -> 7;
        {<<"KE">>, true} -> 7;
        {<<"LT">>, true} -> 7;
        {<<"LV">>, true} -> 7;
        {<<"LS">>, true} -> 7;
        {<<"LK">>, true} -> 7;
        {<<"MD">>, true} -> 7;
        {<<"ML">>, true} -> 7;
        {<<"MR">>, true} -> 7;
        {<<"MK">>, true} -> 7;
        {<<"PK">>, true} -> 7;
        {<<"RU">>, true} -> 7;
        {<<"SD">>, true} -> 7;
        {<<"SN">>, true} -> 7;
        {<<"TN">>, true} -> 7;
        {<<"TR">>, true} -> 7;
        {<<"TZ">>, true} -> 7;
        {<<"TW">>, true} -> 7;
        {<<"UZ">>, true} -> 7;
        {<<"UA">>, true} -> 7;
        {_, true} -> 5;
        {_, false} -> 3
    end,
    PhonePatternLength = byte_size(Phone) - TruncateLen,
    <<PhonePattern:PhonePatternLength/binary, _Last/binary>> = Phone,
    PhonePattern.


otp_delivered(Phone, _ClientIP, Protocol, _RemoteStaticKey) ->
    CC = mod_libphonenumber:get_region_id(Phone),
    model_phone:delete_phone_pattern(extract_phone_pattern(Phone, CC, Protocol)).

