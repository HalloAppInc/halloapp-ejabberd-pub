%%%-------------------------------------------------------------------
%%% @author nikola
%%% @copyright (C) 2021, Halloapp Inc.
%%% @doc
%%%
%%% @end
%%% Created : 15. Sep 2021 2:12 PM
%%%-------------------------------------------------------------------
-module(otp_checker).
-author("nikola").

-include("logger.hrl").

-export([
    check/6,
    otp_delivered/4
]).

% Check the OTP request agains various blocks filters decide if we are going
% to send an otp code to the user or block this attempt. This function can also
% return error to be returned to the user. If we return error then the error
% is returned to the client, but if we return block the client is told the request was
% successful.
-callback check_otp_request(Phone :: binary(), IP :: binary(), UserAgent :: binary(),
        Method :: sms | voice_call | undefined, Protocol :: https | noise,
        RemoteStaticKey :: binary())
    ->
        ok | % this check passed, continue with the other check
        allow | % this check wants to allow this request, no further checks are made
        {block, BlockReason :: atom(), Details :: any()} | % blocked, reason not returned to client
        {error, ErrorReason :: atom(), Details :: any()}. % reason returned to client

% To be called when a client comes back with the right otp code. This tells us the otp was delivered
-callback otp_delivered(Phone :: binary(), ClientIP :: binary(), Protocol :: atom(),
        RemoteStaticKey :: binary()) -> ok.


-define(CHECKERS, [
    otp_checker_phone,
    otp_checker_invited_or_test,
    otp_checker_remote_static_key,
    otp_checker_ip_blocklist,
    otp_checker_ip,
    otp_checker_phone_pattern
]).

-spec check(Phone :: binary(), IP :: binary(), UserAgent :: binary(),
        Method :: sms | voice_call | undefined, Protocol :: https | noise,
        RemoteStaticKey :: binary())
    ->
        ok |
        {block, BlockReason :: atom(), Details :: any()} |
        {error, ErrorReason :: atom(), Details :: any()}.
check(Phone, IP, UserAgent, Method, Protocol, RemoteStaticKey) ->
    Result = lists:foldl(
        fun(Checker, Acc) ->
            case Acc of
                {block, _, _} = Block -> Block;
                {error, _, _} = Error -> Error;
                allow -> allow;
                ok -> Checker:check_otp_request(Phone, IP, UserAgent, Method, Protocol, RemoteStaticKey)
            end
        end, ok, ?CHECKERS),

    CC = mod_libphonenumber:get_region_id(Phone),
    ?INFO("IP: ~s Phone: ~s CC: ~s UA: ~s ~s Remote Static Key: ~p Result: ~p",
        [IP, Phone, CC, UserAgent, Protocol, util:maybe_base64_encode(RemoteStaticKey), Result]),
    case Result of
        allow -> ok;
        Any -> Any
    end.

otp_delivered(Phone, IP, Protocol, RemoteStaticKey) ->
    lists:foreach(
        fun(Checker) ->
            Checker:otp_delivered(Phone, IP, Protocol, RemoteStaticKey)
        end,
        ?CHECKERS),
    ok.

