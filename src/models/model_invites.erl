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
-include("expiration.hrl").

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
    get_inviters_list/1,
    get_sent_invites/1,
    set_invites_left/2,
    ph_invited_by_key_new/1,
    invites_key/1,
    acc_invites_key/1
]).

-define(INVITE_TTL, 60 * ?DAYS).

-define(FIELD_NUM_INV, <<"in">>).
-define(FIELD_SINV_TS, <<"it">>).


%%====================================================================
%% gen_mod callbacks
%%====================================================================

start(_Host, _Opts) ->
    ok.

stop(_Host) ->
    ok.

depends(_Host, _Opts) ->
    [].

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
    {ok, Res} = q_phones(["ZCARD", ph_invited_by_key_new(PhoneNum)]),
    util_redis:decode_int(Res) > 0.


-spec is_invited_by(Phone :: phone(), Uid :: uid()) -> boolean().
is_invited_by(Phone, Uid) ->
    [{ok, Res1}, {ok, Res2}] = qp_accounts([
        ["SISMEMBER", acc_invites_key(Uid), Phone],
        ["ZSCORE", invites_key(Uid), Phone]
    ]),
    Res1Bool = binary_to_integer(Res1) == 1,
    Res2Bool = Res2 =/= undefined,
    Match = Res1Bool =:= Res2Bool,
    ?INFO("Phone:~p Uid:~p ~p ~p Match:~p", [Phone, Uid, Res1Bool, Res2Bool, Match]),
    Res1Bool.

-spec set_invites_left(Uid :: uid(), NumInvsLeft :: integer()) -> ok.
set_invites_left(Uid, NumInvsLeft) ->
    {ok, _} = q_accounts(
        ["HSET", model_accounts:account_key(Uid), ?FIELD_NUM_INV, NumInvsLeft]),
    ok.


-spec get_inviters_list(PhoneNum :: binary() | list()) ->
        {ok, [{Uid :: uid(), Timestamp :: binary()}]} | #{}.
get_inviters_list(PhoneNum) when is_binary(PhoneNum) ->
    {ok, InvitersList} = q_phones(["ZRANGEBYSCORE", ph_invited_by_key_new(PhoneNum), "-inf", "+inf", "WITHSCORES"]),
    {ok, util_redis:parse_zrange_with_scores(InvitersList)};
get_inviters_list([]) -> #{};
get_inviters_list(PhoneNums) when is_list(PhoneNums) ->
    Commands = lists:map(
        fun(PhoneNum) ->
            ["ZRANGEBYSCORE", ph_invited_by_key_new(PhoneNum), "-inf", "+inf", "WITHSCORES"]
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


-spec get_sent_invites(Uid ::binary()) -> {ok, [binary()]}.
get_sent_invites(Uid) ->
    {ok, Phones1} = q_accounts(["SMEMBERS", acc_invites_key(Uid)]),
    {ok, Phones2} = q_accounts(["ZRANGEBYSCORE", invites_key(Uid), "-inf", "+inf"]),
    Phones1Sorted = lists:sort(Phones1),
    Phones2Sorted = lists:sort(Phones2),
    case Phones1Sorted =:= Phones2Sorted of
        true -> ?INFO("Uid: ~p, match-ok Res: ~p", [Uid, Phones1Sorted]);
        false -> ?WARNING("Uid: ~p, match-failed ~p | ~p", [Uid, Phones1Sorted, Phones2Sorted])
    end,
    {ok, Phones1}.

%%====================================================================
%% Internal functions
%%====================================================================

% borrowed from model_accounts.erl
q_accounts(Command) -> ecredis:q(ecredis_accounts, Command).
% borrowed from model_accounts.erl
qp_accounts(Commands) -> ecredis:qp(ecredis_accounts, Commands).
q_phones(Command) -> ecredis:q(ecredis_phone, Command).
qp_phones(Commands) -> ecredis:qp(ecredis_phone, Commands).
qmn_phones(Commands) -> ecredis:qmn(ecredis_phone, Commands).


-spec acc_invites_key(Uid :: uid()) -> binary().
acc_invites_key(Uid) ->
    <<?INVITES_KEY/binary, "{", Uid/binary, "}">>.

-spec invites_key(Uid :: uid()) -> binary().
invites_key(Uid) ->
    <<?INVITES2_KEY/binary, "{", Uid/binary, "}">>.

% TODO: Do a migration to clean up the old key. We have old data left in redis with this old key
%%<<?INVITED_BY_KEY/binary, "{", Phone/binary, "}">>.

% TODO: cleanup after migration
-spec ph_invited_by_key_new(Phone :: phone()) -> binary().
ph_invited_by_key_new(Phone) ->
    <<?INVITED_BY_KEY_NEW/binary, "{", Phone/binary, "}">>.

-spec record_sent_invite(FromUid :: uid(), ToPhone :: phone(), NumInvsLeft :: binary()) -> ok.
record_sent_invite(FromUid, ToPhone, NumInvsLeft) ->
    Now = util:now(),
    NowBin = integer_to_binary(Now),
    [{ok, _}, {ok, _}, {ok, _}] = qp_accounts([
        ["HSET", model_accounts:account_key(FromUid),
            ?FIELD_NUM_INV, NumInvsLeft,
            ?FIELD_SINV_TS, NowBin],
        ["SADD", acc_invites_key(FromUid), ToPhone],
        ["ZADD", invites_key(FromUid), Now, ToPhone]
        %% TODO: enable after the we finish migrating from set to zset for invites_key
%%        ["EXPIRE", invites_key(FromUid), ?INVITE_TTL]
    ]),
    ok.

-spec record_invited_by(FromUid :: uid(), ToPhone :: phone()) -> ok.
record_invited_by(FromUid, ToPhone) ->
    [{ok, _}] = qp_phones([
        ["ZADD", ph_invited_by_key_new(ToPhone), util:now(), FromUid]
        %% TODO: enable after the we finish migrating from set to zset for invites_key
        %% TODO: also add tests for the expiration
%%        ["EXPIRE", ph_invited_by_key_new(ToPhone), ?INVITE_TTL]
    ]),
    ok.

