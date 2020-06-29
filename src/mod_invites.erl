%%%----------------------------------------------------------------------
%%% File    : mod_invites.erl
%%%
%%% Copyright (C) 2020 halloappinc.
%%%
%%% This file handles the iq packet queries for the invite system.
%%% For information about specific requests see: server/doc/invites_api.md
%%%
%%%----------------------------------------------------------------------
-module(mod_invites).
-author("josh").
-behavior(gen_mod).

-include("invites.hrl").
-include("time.hrl").
-include("xmpp.hrl").

%% Export all functions for unit tests
-ifdef(TEST).
-compile(export_all).
-endif.

%% gen_mod API.
-export([start/2, stop/1, reload/3, depends/2, mod_options/1]).

-define(NS_INVITE, <<"halloapp:invites">>).

%%====================================================================
%% gen_mod functions
%%====================================================================

start(_Host, _Opts) ->
    ok.

stop(_Host) ->
    ok.

depends(_Host, _Opts) ->
    [].

reload(_Host, _NewOpts, _OldOpts) ->
    ok.

mod_options(_Host) ->
    [].


%%====================================================================
%% IQ handlers
%%====================================================================

%% TODO: to implement
process_local_iq(#iq{} = _IQ) ->
    ok.


%%====================================================================
%% Internal functions
%%====================================================================

%% Only use this function to poll current invites left
%% Do not use info from this function to do anything except relay info to the user
-spec get_invites_remaining(Uid :: binary()) -> integer().
get_invites_remaining(Uid) ->
    MidnightSunday = get_last_sunday_midnight(),
    {ok, Num, Ts} = model_invites:get_invites_remaining(Uid),
    if
        Ts == undefined -> ?MAX_NUM_INVITES;
        MidnightSunday > Ts -> ?MAX_NUM_INVITES;
        MidnightSunday =< Ts -> Num
    end.


-spec get_time_until_refresh() -> integer().
get_time_until_refresh() ->
    get_time_until_refresh(util:now()).

get_time_until_refresh(CurrEpochTime) ->
    get_next_sunday_midnight(CurrEpochTime) - CurrEpochTime.


% this function should return {ok, NumInvitesRemaining}
-spec request_invite(FromUid :: binary(), ToPhoneNum :: binary()) ->
    {ok, integer()} | {error, no_account | no_invites_left | existing_user}.
request_invite(FromUid, ToPhoneNum) ->
    case can_send_invite(FromUid, ToPhoneNum) of
        {error, Reason} -> {error, Reason};
        {ok, InvitesLeft} ->
            model_invites:record_invite(FromUid, ToPhoneNum, InvitesLeft - 1),
            {ok, InvitesLeft - 1}
    end.


can_send_invite(FromUid, ToPhone) ->
    case model_accounts:account_exists(FromUid) of
        false -> {error, no_account};
        true ->
            InvsRem = get_invites_remaining(FromUid),
            case InvsRem of
                0 -> {error, no_invites_left};
                _ ->
                  case model_phone:get_uid(ToPhone) of
                      {ok, undefined} -> {ok, InvsRem};
                      {ok, _} -> {error, existing_user}
                  end
            end
    end.


% returns timestamp (in seconds) for either the most recent of the upcoming Sunday at 00:00 GMT
% if it is currently sunday at midnight, then get_last_sunday_midnight() == CurrentTime
-spec get_last_sunday_midnight() -> integer().
get_last_sunday_midnight() ->
    get_last_sunday_midnight(util:now()).
get_last_sunday_midnight(CurrTime) ->
    % Jan 1, 1970 was a Thursday, which was 3 days away from Sunday 00:00
    Offset = 3 * ?DAYS,
    Offset + ((CurrTime - Offset) div ?WEEKS) * ?WEEKS.


-spec get_next_sunday_midnight() -> integer().
get_next_sunday_midnight() ->
    get_next_sunday_midnight(util:now()).
get_next_sunday_midnight(CurrTime) ->
    get_last_sunday_midnight(CurrTime) + ?WEEKS.

