%%%-------------------------------------------------------------------
%%% @author josh
%%% @copyright (C) 2023, Halloapp Inc.
%%% @doc
%%%
%%% @end
%%% Created : 6. Sep 2023 4:45 PM
%%%-------------------------------------------------------------------
-module(otp_checker_phone_ban).
-author("josh").
-behavior(otp_checker).

%% API
-export([
    check_otp_request/6,
    otp_delivered/4
]).

% see spec in otp_checker
check_otp_request(Phone, _IP, _UserAgent, _Method, _Protocol, _RemoteStaticKey) ->
    case model_accounts:is_banned(Phone) of
        true -> {block, banned_phone, undefined};
        false -> ok
    end.


otp_delivered(_Phone, _IP, _Protocol, _RemoteStaticKey) ->
    ok.

