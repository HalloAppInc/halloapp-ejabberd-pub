%%%------------------------------------------------------------------------------------
%%% File: model_invites.erl
%%% Copyright (C) 2020, HalloApp, Inc.
%%%
%%% API for Redis queries associated with the invite system.
%%%
%%%------------------------------------------------------------------------------------
-module(model_invites).
-author("josh").
-behavior(gen_mod).

-include("logger.hrl").
-include("time.hrl").
-include("redis_keys.hrl").
-include("ha_types.hrl").

%% Export all functions for unit tests
-ifdef(TEST).
-compile(export_all).
-endif.

%% gen_mod callbacks
-export([start/2, stop/1, depends/2, mod_options/1]).

%% API
-export([
    get_invites_remaining/1,
    record_invite/3,
    is_invited/1,
    is_invited_by/2,
    get_inviter/1,
    get_sent_invites/1
]).

-define(FIELD_NUM_INV, <<"in">>).
-define(FIELD_SINV_TS, <<"it">>).
-define(FIELD_RINV_UID, <<"id">>).
-define(FIELD_RINV_TS, <<"ts">>).


%%====================================================================
%% gen_mod callbacks
%%====================================================================

start(_Host, _Opts) ->
    ok.

stop(_Host) ->
    ok.

depends(_Host, _Opts) ->
    [{mod_redis, hard}].

mod_options(_Host) ->
    [].


%%====================================================================
%% API
%%====================================================================

% returns {ok, NumInvitesRemaining, TimestampOfLastInvite}
-spec get_invites_remaining(Uid :: uid()) -> {ok, maybe(integer()), maybe(integer())}.
get_invites_remaining(Uid) ->
    {ok, [Num, Ts]} = q_accounts(["HMGET", model_accounts:account_key(Uid), ?FIELD_NUM_INV, ?FIELD_SINV_TS]),
    case {Num, Ts} of
        {undefined, undefined} -> {ok, undefined, undefined};
        {_, _} -> {ok, binary_to_integer(Num), binary_to_integer(Ts)}
    end.


-spec record_invite(FromUid :: uid(), ToPhoneNum :: binary(), NumInvsLeft :: integer()) -> ok.
record_invite(FromUid, ToPhoneNum, NumInvsLeft) ->
    ok = record_invited_by(FromUid, ToPhoneNum),
    ok = record_sent_invite(FromUid, ToPhoneNum, integer_to_binary(NumInvsLeft)),
    ok.


-spec is_invited(PhoneNum :: binary()) -> boolean().
is_invited(PhoneNum) ->
    {ok, Res} = q_phones(["EXISTS", ph_invited_by_key(PhoneNum)]),
    binary_to_integer(Res) == 1.


-spec is_invited_by(Phone :: binary(), Uid :: uid()) -> boolean().
is_invited_by(Phone, Uid) ->
    {ok, Res} = q_accounts(["SISMEMBER", acc_invites_key(Uid), Phone]),
    binary_to_integer(Res) == 1.


-spec get_inviter(PhoneNum :: binary()) -> {ok, Uid :: uid(), Timestamp :: binary()} | {ok, undefined}.
get_inviter(PhoneNum) ->
    IsInvited = is_invited(PhoneNum),
    case IsInvited of
        false -> {ok, undefined};
        true ->
            {ok, [_, Uid, _, Ts]} = q_phones(["HGETALL", ph_invited_by_key(PhoneNum)]),
            {ok, Uid, Ts}
    end.


-spec get_sent_invites(Uid ::binary()) -> {ok, [binary()]}.
get_sent_invites(Uid) ->
    q_accounts(["SMEMBERS", acc_invites_key(Uid)]).

%%====================================================================
%% Internal functions
%%====================================================================

% borrowed from model_accounts.erl
q_accounts(Command) -> ecredis:q(ecredis_accounts, Command).
% borrowed from model_accounts.erl
qp_accounts(Commands) -> ecredis:qp(ecredis_accounts, Commands).
q_phones(Command) -> ecredis:q(ecredis_phone, Command).


-spec acc_invites_key(Uid :: uid()) -> binary().
acc_invites_key(Uid) ->
    <<?INVITES_KEY/binary, "{", Uid/binary, "}">>.

-spec ph_invited_by_key(Phone :: binary()) -> binary().
ph_invited_by_key(Phone) ->
    <<?INVITED_BY_KEY/binary, "{", Phone/binary, "}">>.

-spec record_sent_invite(FromUid :: uid(), ToPhone :: binary(), NumInvsLeft :: binary()) -> ok.
record_sent_invite(FromUid, ToPhone, NumInvsLeft) ->
    [{ok, _}, {ok, _}] = qp_accounts([
        ["HSET", model_accounts:account_key(FromUid),
            ?FIELD_NUM_INV, NumInvsLeft,
            ?FIELD_SINV_TS, integer_to_binary(util:now())],
        ["SADD", acc_invites_key(FromUid), ToPhone]
    ]),
    ok.

-spec record_invited_by(FromUid :: uid(), ToPhone :: binary()) -> ok.
record_invited_by(FromUid, ToPhone) ->
    {ok, _} = q_phones(["HSET", ph_invited_by_key(ToPhone),
                   ?FIELD_RINV_UID, FromUid,
                   ?FIELD_RINV_TS, util:now()]),
    ok.

