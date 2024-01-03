%%%-------------------------------------------------------------------
%%% @copyright (C) 2021, Halloapp Inc.
%%% @doc
%%%
%%% @end
%%%-------------------------------------------------------------------
-module(otp_checker_ip_geo).
-author("vipin").
-behavior(otp_checker).

-include("logger.hrl").

%% For travelers.
-define(BACKOFF_THRESHOLD, 25).

%% For spammers.
-define(ERROR_THRESHOLD, 40).

%% API
-export([
    check_otp_request/6,
    otp_delivered/4
]).


check_otp_request(Phone, IP, _UserAgent, _Method, _Protocol, _RemoteStaticKey) ->
    PhoneCC = mod_libphonenumber:get_region_id(Phone),
    IPCC = mod_geodb:lookup(IP),
    check_otp_request(Phone, IP, PhoneCC, IPCC).

% Block AZ in all cases.
check_otp_request(_Phone, _IP, <<"AZ">>, CC) ->
    {block, phone_cc_block, {<<"AZ">>, CC}};
%% Allow in case IP of Phone and CC is same.
check_otp_request(_Phone, _IP, PhoneCC, PhoneCC) ->
    ok;
check_otp_request(_Phone, _IP, <<"SD">>, CC) ->
    {block, phone_cc_block, {<<"SD">>, CC}};
check_otp_request(_Phone, _IP, <<"VN">>, CC) ->
    {block, phone_cc_block, {<<"VN">>, CC}};
check_otp_request(_Phone, _IP, <<"LK">>, CC) ->
    {block, phone_cc_block, {<<"LK">>, CC}};
check_otp_request(_Phone, _IP, <<"BD">>, CC) ->
    {block, phone_cc_block, {<<"BD">>, CC}};
check_otp_request(_Phone, _IP, <<"JO">>, CC) ->
    {block, phone_cc_block, {<<"JO">>, CC}};
check_otp_request(_Phone, _IP, <<"OM">>, CC) ->
    {block, phone_cc_block, {<<"OM">>, CC}};
check_otp_request(_Phone, _IP, <<"SN">>, CC) ->
    {block, phone_cc_block, {<<"SN">>, CC}};
check_otp_request(_Phone, _IP, <<"KG">>, CC) ->
    {block, phone_cc_block, {<<"KG">>, CC}};
check_otp_request(_Phone, _IP, <<"PH">>, CC) ->
    {block, phone_cc_block, {<<"PH">>, CC}};
check_otp_request(_Phone, _IP, <<"UZ">>, CC) ->
    {block, phone_cc_block, {<<"UZ">>, CC}};
check_otp_request(_Phone, _IP, <<"RU">>, CC) ->
    {block, phone_cc_block, {<<"RU">>, CC}};
check_otp_request(_PHONE, IP, _PhoneCC, <<"ZZ">>) ->
    ?WARNING("Unable to find cc for ip: ~s", [IP]),
    ok;
check_otp_request(Phone, _IP, PhoneCC, IPCC) ->
    CurrentTs = util:now(),
    {ok, {Count, LastTs}} = model_phone:get_phone_cc_info(PhoneCC),
    Result = case {Count, LastTs} of
        {undefined, _} ->
            ok;
        {_, undefined} ->
            ok;
        {_, _} when Count =< ?BACKOFF_THRESHOLD ->
            ok;
        {_, _} ->
            NextTs = util_sms:good_next_ts_diff(Count - ?BACKOFF_THRESHOLD) + LastTs,
            case NextTs > CurrentTs of
                true ->
                    case Count > ?ERROR_THRESHOLD of
                        true ->
                            ?INFO("Need to block phone: ~s CC: ~s count: ~p last ts: ~p IP CC: ~s",
                                [Phone, PhoneCC, Count, LastTs, IPCC]),
                            {block, ip_geo_block, {PhoneCC, Count, LastTs}};
                        false ->
                            ?INFO("Need to slow down phone: ~s CC: ~s count: ~p last ts: ~p IP CC: ~s",
                                [Phone, PhoneCC, Count, LastTs, IPCC]),
                            {error, retried_too_soon, NextTs - CurrentTs}
                    end;
                false -> ok
            end
    end,
    ok = model_phone:add_phone_cc(PhoneCC, CurrentTs),
    Result.


otp_delivered(Phone, IP, _Protocol, _RemoteStaticKey) ->
    PhoneCC = mod_libphonenumber:get_region_id(Phone),
    IPCC = mod_geodb:lookup(IP),
    otp_delivered(Phone, PhoneCC, IPCC).

otp_delivered(_Phone, PhoneCC, PhoneCC) ->
    ok;
otp_delivered(_Phone, _PhoneCC, <<"ZZ">>) ->
    ok;
otp_delivered(Phone, PhoneCC, _IPCC) ->
    {ok, {Count, _LastTs}} = model_phone:get_phone_cc_info(PhoneCC),
    case Count =/= undefined andalso Count > ?ERROR_THRESHOLD of
        true -> ?ERROR("OTP delivered to Phone ~s but CC ~s has ~B Attempts",
                    [Phone, PhoneCC, Count]);
        false -> ok
    end,
    model_phone:delete_phone_cc(PhoneCC).

