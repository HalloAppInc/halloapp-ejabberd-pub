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

check_otp_request(_Phone, _IP, PhoneCC, PhoneCC) ->
    ok;
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
                            %% TODO, uncomment
                            %% {block, ip_geo_block, {PhoneCC, Count, LastTs}};
                            ok;
                        false ->
                            ?INFO("Need to slow down phone: ~s CC: ~s count: ~p last ts: ~p IP CC: ~s",
                                [Phone, PhoneCC, Count, LastTs, IPCC]),
                            %% TODO, uncomment
                            %% {error, retried_too_soon, NextTs - CurrentTs}
                            ok
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
        true -> ?ERROR("OTP delivered to Phone ~s but CC ~s has ~s Attempts",
                    [Phone, PhoneCC, Count]);
        false -> ok
    end,
    model_phone:delete_phone_cc(PhoneCC).
