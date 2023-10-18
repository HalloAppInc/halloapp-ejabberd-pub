%%%-------------------------------------------------------------------
%%% @copyright (C) 2021, Halloapp Inc.
%%% @doc
%%%
%%% @end
%%%-------------------------------------------------------------------
-module(otp_checker_remote_static_key).
-author("vipin").
-behavior(otp_checker).

-include("logger.hrl").

%% For typing mistakes.
-define(BACKOFF_THRESHOLD, 3).

%% For spammers.
-define(ERROR_THRESHOLD, 10).

%% API
-export([
    check_otp_request/6,
    otp_delivered/4
]).


check_otp_request(_Phone, _IP, _UserAgent, _Method, _Protocol, undefined) ->
    ok;
check_otp_request(_Phone, _IP, _UserAgent, _Method, _Protocol, RemoteStaticKey) ->
    CurrentTs = util:now(),
    {ok, {Count, LastTs}} = model_phone:get_static_key_info(RemoteStaticKey),
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
                            {block, static_key_block, {util:maybe_base64_encode(RemoteStaticKey), Count, LastTs}};
                        false ->
                            {error, retried_too_soon, NextTs - CurrentTs}
                    end;
                false -> ok
            end
    end,
    ok = model_phone:add_static_key(RemoteStaticKey, CurrentTs),
    Result.


otp_delivered(_Phone, _IP, _Protocol, undefined) ->
    ok;
otp_delivered(Phone, _IP, _Protocol, RemoteStaticKey) ->
    {ok, {Count, _LastTs}} = model_phone:get_static_key_info(RemoteStaticKey),
    case Count =/= undefined andalso Count > ?ERROR_THRESHOLD of
        true -> ?ERROR("OTP delivered to Phone ~s but StaticKey ~s has ~B Attempts",
                    [Phone, base64:encode(RemoteStaticKey), Count]);
        false -> ok
    end,
    model_phone:delete_static_key(RemoteStaticKey).
