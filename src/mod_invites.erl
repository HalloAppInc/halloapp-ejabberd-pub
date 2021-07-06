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

-include("account.hrl").
-include("invites.hrl").
-include("logger.hrl").
-include("time.hrl").
-include("packets.hrl").

%% Export all functions for unit tests
-ifdef(TEST).
-compile(export_all).
-endif.

%% gen_mod API.
-export([start/2, stop/1, reload/3, depends/2, mod_options/1]).
-export([
    process_local_iq/1,
    get_invites_remaining/1,
    get_invites_remaining2/1,
    register_user/3,
    request_invite/2
]).

-define(NS_INVITE, <<"halloapp:invites">>).
-define(NS_INVITE_STATS, "HA/invite").

%%====================================================================
%% gen_mod functions
%%====================================================================

start(Host, _Opts) ->
    gen_iq_handler:add_iq_handler(ejabberd_local, Host, pb_invites_request, ?MODULE, process_local_iq),
    ejabberd_hooks:add(register_user, Host, ?MODULE, register_user, 50),
    ok.

stop(Host) ->
    gen_iq_handler:remove_iq_handler(ejabberd_local, Host, pb_invites_request),
    ejabberd_hooks:delete(register_user, Host, ?MODULE, register_user, 50),
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

% type = get
process_local_iq(#pb_iq{from_uid = Uid, type = get} = IQ) ->
    AccExists = model_accounts:account_exists(Uid),
    case AccExists of
        false -> pb:make_error(IQ, util:err(no_account));
        true ->
            InvsRem = get_invites_remaining2(Uid),
            Time = get_time_until_refresh(),
            ?INFO("Uid: ~s has ~p invites left, next invites at ~p", [Uid, InvsRem, Time]),
            Result = #pb_invites_response{
                invites_left = InvsRem,
                time_until_refresh = Time
            },
            pb:make_iq_result(IQ, Result)
    end;

% type = set
process_local_iq(#pb_iq{from_uid = Uid, type = set,
        payload = #pb_invites_request{invites = InviteList}} = IQ) ->
    AccExists = model_accounts:account_exists(Uid),
    case AccExists of
        false -> pb:make_error(IQ, util:err(no_account));
        true ->
            PhoneList = [P#pb_invite.phone || P <- InviteList],
            ?INFO("Uid: ~s inviting ~p", [Uid, PhoneList]),
            Results = lists:map(fun(Phone) -> request_invite(Uid, Phone) end, PhoneList),
            NewInviteList = lists:map(
                    fun({Ph, Res, Rea}) ->
                        Result = util:to_binary(Res),
                        Reason = case Rea of
                            undefined -> <<>>;
                            _ -> util:to_binary(Rea)
                        end,
                        #pb_invite{phone = Ph, result = Result, reason = Reason}
                    end, Results),
            Ret = #pb_invites_response{
                invites_left = get_invites_remaining2(Uid),
                time_until_refresh = get_time_until_refresh(),
                invites = NewInviteList
            },
            pb:make_iq_result(IQ, Ret)
    end.


-spec register_user(Uid :: binary(), Server :: binary(), Phone :: binary()) -> ok.
register_user(Uid, _Server, Phone) ->
    {ok, InvitersList} = model_invites:get_inviters_list(Phone),
    give_back_invite(Uid, Phone, InvitersList),
    send_invitee_notice(Uid, InvitersList),
    ok.


-spec request_invite(FromUid :: uid(), ToPhoneNum :: phone()) -> {ToPhoneNum :: phone(),
    ok | failed, maybe(invalid_number | no_invites_left | existing_user)}.
request_invite(FromUid, ToPhoneNum) ->
    stat:count(?NS_INVITE_STATS, "requests"),
    stat:count(?NS_INVITE_STATS, "requests_by_dev", 1, [{is_dev, dev_users:is_dev_uid(FromUid)}]),
    case can_send_invite(FromUid, ToPhoneNum) of
        {error, already_invited} ->
            ?INFO("Uid: ~s Phone: ~s already_invited", [FromUid, ToPhoneNum]),
            stat:count(?NS_INVITE_STATS, "invite_duplicate"),
            {ToPhoneNum, ok, undefined};
        {error, Reason} ->
            ?INFO("Uid: ~s Phone: ~s error ~p", [FromUid, ToPhoneNum, Reason]),
            stat:count(?NS_INVITE_STATS, "invite_error_" ++ atom_to_list(Reason)),
            {ToPhoneNum, failed, Reason};
        {ok, InvitesLeft, NormalizedPhone} ->
            ?INFO("Uid: ~s Phone: ~s invite successful, ~p invites left",
                [FromUid, ToPhoneNum, InvitesLeft]),
            stat:count(?NS_INVITE_STATS, "invite_success"),
            % In prod, registration of test number won't decrease the # of invites a user has
            NumInvitesLeft = case config:is_prod_env() and
                    (util:is_test_number(NormalizedPhone) or not ?IS_INVITE_REQUIRED) of
                 true -> InvitesLeft;
                 false -> InvitesLeft - 1
             end,
            model_invites:record_invite(FromUid, NormalizedPhone, NumInvitesLeft),
            {ToPhoneNum, ok, undefined}
    end.

%%====================================================================
%% Internal functions
%%====================================================================

-spec give_back_invite(Uid :: binary(), Phone :: binary(), InvitersList :: [{binary(), integer()}]) -> ok.
give_back_invite(Uid, Phone, InvitersList) ->
    lists:foreach(
        fun({InviterUid, _Ts}) ->
            ?INFO("Uid: ~p, Phone: ~p accepted invite. InviterUid: ~p", [Uid, Phone, InviterUid]),
            InvitesRem = get_invites_remaining(InviterUid),
            FinalNumInvsLeft = min(InvitesRem +1, ?MAX_NUM_INVITES),
            ok = model_invites:set_invites_left(InviterUid, FinalNumInvsLeft)
        end, InvitersList),
    ok.


-spec send_invitee_notice(Uid :: binary(), InvitersList :: [{binary(), integer()}]) -> ok.
send_invitee_notice(Uid, InvitersList) ->
    PbInviters = lists:foldl(
        fun({InviterUid, TimestampBin}, Acc) ->
            case model_accounts:get_account(InviterUid) of
                {ok, Account} ->
                    PbInviter = #pb_inviter{
                        uid = InviterUid,
                        name = Account#account.name,
                        phone = Account#account.phone,
                        timestamp = util:to_integer(TimestampBin)
                    },
                    [PbInviter | Acc];
                _ -> Acc
            end
        end, [], InvitersList),
    Packet = #pb_msg{
        id = util_id:new_msg_id(),
        to_uid = Uid,
        type = normal,
        payload = #pb_invitee_notice{
            inviters = PbInviters
        }
    },
    ?INFO("Uid: ~p, MsgId: ~p", [Uid, Packet#pb_msg.id]),
    ejabberd_router:route(Packet),
    ok.


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

-spec get_invites_remaining2(Uid :: binary()) -> integer().
get_invites_remaining2(Uid) ->
    case ?IS_INVITE_REQUIRED of
        true -> get_invites_remaining(Uid);
        false -> ?INF_INVITES
    end.

-spec get_time_until_refresh() -> integer().
get_time_until_refresh() ->
    get_time_until_refresh(util:now()).

get_time_until_refresh(CurrEpochTime) ->
    get_next_sunday_midnight(CurrEpochTime) - CurrEpochTime.


can_send_invite(FromUid, ToPhone) ->
    {ok, UserPhone} = model_accounts:get_phone(FromUid),
    RegionId = mod_libphonenumber:get_region_id(UserPhone),
    NormPhone = mod_libphonenumber:normalize(prepend_plus(ToPhone), RegionId),
    case NormPhone of
        undefined -> {error, invalid_number};
        _ ->
            case model_phone:get_uid(NormPhone) of
                {ok, undefined} ->
                    IsInvited = model_invites:is_invited_by(NormPhone, FromUid),
                    case IsInvited of
                        true -> {error, already_invited};
                        false ->
                            InvsRem = get_invites_remaining(FromUid),
                            case {InvsRem, ?IS_INVITE_REQUIRED} of
                                {0, true} -> {error, no_invites_left};
                                _ -> {ok, InvsRem, NormPhone}
                            end
                    end;
                {ok, _} -> {error, existing_user}
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


-spec get_next_sunday_midnight(CurrTime :: non_neg_integer()) -> non_neg_integer().
get_next_sunday_midnight(CurrTime) ->
    get_last_sunday_midnight(CurrTime) + ?WEEKS.


%%% IQ helper functions %%%


prepend_plus(RawPhone) ->
    case RawPhone of
        <<"+", _Rest/binary>> ->  RawPhone;
        _ -> <<"+", RawPhone/binary>>
    end.

