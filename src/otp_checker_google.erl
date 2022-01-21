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
    Result1 = case Phone of
        <<"16504992804">> -> true;
        _ -> false
    end,
    Result2 = case inet:parse_address(util:to_list(IP)) of
        {ok, {108,177,6,_}} -> true;
        {ok, {108,177,7,_}} -> true;
        _ -> false
    end,
    case {Result1, Result2, Protocol} of
        {true, true, noise} -> allow;
        _ -> ok
    end.

otp_delivered(_Phone, _ClientIP, _Protocol, _RemoteStaticKey) ->
    ok.

