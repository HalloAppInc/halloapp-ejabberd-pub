%%%-------------------------------------------------------------------
%%% @author nikola
%%% @copyright (C) 2021, Halloapp Inc.
%%% @doc
%%%
%%% @end
%%% Created : 15. Sep 2021 3:37 PM
%%%-------------------------------------------------------------------
-module(otp_checker_invited_or_test).
-author("nikola").
-behavior(otp_checker).

%% API
-export([check_otp_request/6, otp_delivered/4]).


check_otp_request(Phone, _IP, _UserAgent, _Method, _Protocol, _RemoteStaticKey) ->
    case util:is_test_number(Phone) orelse model_invites:is_invited(Phone) of
        true -> allow;
        false -> ok
    end.

otp_delivered(_Phone, _ClientIP, _Protocol, _RemoteStaticKey) ->
    ok.

