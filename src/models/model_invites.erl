%%%------------------------------------------------------------------------------------
%%% File: model_invites.erl
%%% Copyright (C) 2020, HalloApp, Inc.
%%%
%%% API for Redis queries associated with the invite system.
%%%
%%%------------------------------------------------------------------------------------
-module(model_invites).
-author("josh").

-include("logger.hrl").
-include("time.hrl").
-include("redis_keys.hrl").
-include("ha_types.hrl").
-include("expiration.hrl").

%% API
-export([
    get_invites_remaining/1,
    record_invite/3,
    is_invited/1,
    is_invited_by/2,
    get_inviters_list/1,
    get_sent_invites/1,
    set_invites_left/2,
    ph_invited_by_key/1,
    invites_key/1
]).

%% Export functions for unit tests
-ifdef(TEST).
-export([
    is_invited/2,
    record_invite/4,
    is_invited_by/3,
    get_inviters_list/2,
    get_sent_invites/2,
    get_invite_ttl/0
]).
-endif.
-compile([{nowarn_unused_function, [
    {get_invite_ttl, 0}
    ]}]).


-define(INVITE_TTL, 90 * ?DAYS).

-define(FIELD_NUM_INV, <<"in">>).
-define(FIELD_SINV_TS, <<"it">>).

%%====================================================================
%% API
%%====================================================================

% returns {ok, NumInvitesRemaining, TimestampOfLastInvite}
-spec get_invites_remaining(Uid :: uid()) -> {ok, maybe(integer()), maybe(integer())}.
get_invites_remaining(Uid) ->
    {ok, [Num, Ts]} = q_accounts(["HMGET", model_accounts:account_key(Uid),
        ?FIELD_NUM_INV, ?FIELD_SINV_TS]),
    case {Num, Ts} of
        {undefined, undefined} -> {ok, undefined, undefined};
        {_, _} -> {ok, binary_to_integer(Num), binary_to_integer(Ts)}
    end.


-spec record_invite(FromUid :: uid(), ToPhoneNum :: binary(), NumInvsLeft :: integer()) -> ok.
record_invite(FromUid, ToPhoneNum, NumInvsLeft) ->
    record_invite(FromUid, ToPhoneNum, NumInvsLeft, util:now()).

-spec record_invite(FromUid :: uid(), ToPhoneNum :: binary(), NumInvsLeft :: integer(),
        Ts :: integer()) -> ok.
record_invite(FromUid, ToPhoneNum, NumInvsLeft, Ts) ->
    ok = record_invited_by(FromUid, ToPhoneNum, Ts),
    ok = record_sent_invite(FromUid, ToPhoneNum, NumInvsLeft, Ts),
    ok.


-spec is_invited(PhoneNum :: binary()) -> boolean().
is_invited(PhoneNum) ->
    is_invited(PhoneNum, util:now()).

-spec is_invited(PhoneNum :: binary(), Now :: integer()) -> boolean().
is_invited(PhoneNum, Now) ->
    {ok, List} = get_inviters_list(PhoneNum, Now),
    case List of
        [] -> false;
        _ -> true
    end.


-spec is_invited_by(Phone :: phone(), Uid :: uid()) -> boolean().
is_invited_by(Phone, Uid) ->
    is_invited_by(Phone, Uid, util:now()).

-spec is_invited_by(Phone :: phone(), Uid :: uid(), Now :: integer()) -> boolean().
is_invited_by(Phone, Uid, Now) ->
    {ok, TsBin} = q_accounts(["ZSCORE", invites_key(Uid), Phone]),
    case TsBin of
        undefined -> false;
        _ ->
            Ts = binary_to_integer(TsBin),
            % check if the invite is not expired
            Ts >= Now - ?INVITE_TTL
    end.

-spec set_invites_left(Uid :: uid(), NumInvsLeft :: integer()) -> ok.
set_invites_left(Uid, NumInvsLeft) ->
    {ok, _} = q_accounts(
        ["HSET", model_accounts:account_key(Uid), ?FIELD_NUM_INV, NumInvsLeft]),
    ok.


% TODO: rename the function that takes bunch of phones to something else like get_inviters_list_multi
% TODO: change the return timestamp to be integer
-spec get_inviters_list(PhoneNum :: binary() | list()) ->
    {ok, [{Uid :: uid(), Timestamp :: binary()}]} | #{}.
get_inviters_list(PhoneNum) when is_binary(PhoneNum) ->
    get_inviters_list(PhoneNum, util:now());
get_inviters_list([]) -> #{};
get_inviters_list(PhoneNums) when is_list(PhoneNums) ->
    StartTime = util:now() - ?INVITE_TTL,
    StartTimeBin = integer_to_binary(StartTime),
    Commands = lists:map(
        fun(PhoneNum) ->
            ["ZRANGE", ph_invited_by_key(PhoneNum), StartTimeBin, "+inf", "BYSCORE", "WITHSCORES"]
        end, PhoneNums),
    Res = qmn_phones(Commands),
    Result = lists:foldl(
        fun({PhoneNum, {ok, InvitersList}}, Acc) ->
            case InvitersList of
                [] -> Acc;
                _ -> Acc#{PhoneNum => util_redis:parse_zrange_with_scores(InvitersList)}
            end
        end, #{}, lists:zip(PhoneNums, Res)),
    Result.

-spec get_inviters_list(PhoneNum :: binary(), Now :: integer()) ->
        {ok, [{Uid :: uid(), Timestamp :: binary()}]}.
get_inviters_list(PhoneNum, Now) ->
    StartTime = Now - ?INVITE_TTL,
    {ok, InvitersList} = q_phones(["ZRANGE", ph_invited_by_key(PhoneNum),
        integer_to_binary(StartTime), "+inf", "BYSCORE", "WITHSCORES"]),
    {ok, util_redis:parse_zrange_with_scores(InvitersList)}.


-spec get_sent_invites(Uid ::binary()) -> {ok, [binary()]}.
get_sent_invites(Uid) ->
    get_sent_invites(Uid, util:now()).

-spec get_sent_invites(Uid :: binary(), Now :: integer()) -> {ok, [binary()]}.
get_sent_invites(Uid, Now) ->
    StartTime = Now - ?INVITE_TTL,
    {ok, Phones} = q_accounts(["ZRANGE", invites_key(Uid),
        integer_to_binary(StartTime), "+inf", "BYSCORE"]),
    {ok, Phones}.

get_invite_ttl() ->
    ?INVITE_TTL.

%%====================================================================
%% Internal functions
%%====================================================================

q_accounts(Command) -> ecredis:q(ecredis_accounts, Command).
qp_accounts(Commands) -> ecredis:qp(ecredis_accounts, Commands).
q_phones(Command) -> ecredis:q(ecredis_phone, Command).
qp_phones(Commands) -> ecredis:qp(ecredis_phone, Commands).
qmn_phones(Commands) -> ecredis:qmn(ecredis_phone, Commands).


-spec invites_key(Uid :: uid()) -> binary().
invites_key(Uid) ->
    <<?INVITES2_KEY/binary, "{", Uid/binary, "}">>.

-spec ph_invited_by_key(Phone :: phone()) -> binary().
ph_invited_by_key(Phone) ->
    <<?INVITED_BY_KEY/binary, "{", Phone/binary, "}">>.

-spec record_sent_invite(FromUid :: uid(), ToPhone :: phone(), NumInvsLeft :: integer(),
        Ts :: integer()) -> ok.
record_sent_invite(FromUid, ToPhone, NumInvsLeft, Ts) ->
    [{ok, _}, {ok, _}, {ok, _}, {ok, CountExpiredBin}] = qp_accounts([
        ["HSET", model_accounts:account_key(FromUid),
            ?FIELD_NUM_INV, integer_to_binary(NumInvsLeft),
            ?FIELD_SINV_TS, integer_to_binary(Ts)],
        ["ZADD", invites_key(FromUid), Ts, ToPhone],
        ["EXPIRE", invites_key(FromUid), ?INVITE_TTL],
        ["ZREMRANGEBYSCORE", invites_key(FromUid), "-inf", Ts - ?INVITE_TTL]
    ]),
    % TODO: remove once we know its kind of working
    CountExpired = binary_to_integer(CountExpiredBin),
    ?INFO("Uid: ~p, expired ~p invites", [FromUid, CountExpired]),
    ok.

-spec record_invited_by(FromUid :: uid(), ToPhone :: phone(), Ts :: integer()) -> ok.
record_invited_by(FromUid, ToPhone, Ts) ->
    [{ok, _}, {ok, _}, {ok, CountExpiredBin}] = qp_phones([
        ["ZADD", ph_invited_by_key(ToPhone), Ts, FromUid],
        ["EXPIRE", ph_invited_by_key(ToPhone), ?INVITE_TTL],
        ["ZREMRANGEBYSCORE", ph_invited_by_key(ToPhone), "-inf", Ts - ?INVITE_TTL]
    ]),
    % TODO: remove once we know its kind of working
    CountExpired = binary_to_integer(CountExpiredBin),
    ?INFO("Phone: ~p, expired ~p invites", [ToPhone, CountExpired]),
    ok.

