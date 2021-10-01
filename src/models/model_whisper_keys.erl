%%%------------------------------------------------------------------------------------
%%% File: model_whisper_keys.erl
%%% Copyright (C) 2020, HalloApp, Inc.
%%%
%%% This model handles all the redis db queries that are related with whisper keys.
%%%
%%%------------------------------------------------------------------------------------
-module(model_whisper_keys).
-author('murali').

-include("logger.hrl").
-include("redis_keys.hrl").
-include("whisper.hrl").
-include("ha_types.hrl").
-include("time.hrl").


%% e2e_stats query key will expire every 12hrs - so that we can query them again.
-define(E2E_QUERY_EXPIRY, 12 * ?HOURS).

-export([whisper_key/1, otp_key/1, subcribers_key/1]).


%% API
-export([
    set_keys/4,
    add_otp_keys/2,
    get_key_set/1,
    get_key_set_without_otp/1,
    get_identity_keys/1,
    remove_all_keys/1,
    count_otp_keys/1,
    add_key_subscriber/2,
    add_key_subscribers/2,
    remove_key_subscriber/2,
    remove_key_subscribers/2,
    get_all_key_subscribers/1,
    remove_all_key_subscribers/1,
    delete_all_otp_keys/1,  %% dangerous function - dont use without talking to the team.
    mark_e2e_stats_query/0,
    export_keys/1
]).

%%====================================================================
%% API
%%====================================================================


-define(FIELD_IDENTITY_KEY, <<"idk">>).
-define(FIELD_SIGNEDPRE_KEY, <<"spk">>).


-spec set_keys(Uid :: uid(), IdentityKey :: binary(),
        SignedPreKey :: binary(), OtpKeys :: list(binary())) -> ok | {error, any()}.
set_keys(Uid, IdentityKey, SignedPreKey, OtpKeys) ->
    PipeCommands = [
            ["MULTI"],
            ["DEL", whisper_key(Uid), otp_key(Uid)],
            ["HSET", whisper_key(Uid),
                ?FIELD_IDENTITY_KEY, IdentityKey,
                ?FIELD_SIGNEDPRE_KEY, SignedPreKey],
            % Note: We are doing LPUSH and RPOP so our otks are stored in reverse
            ["LPUSH", otp_key(Uid) | OtpKeys],
            ["EXEC"]],
    _Results = qp(PipeCommands),
    ok.


-spec add_otp_keys(Uid :: uid(), OtpKeys :: list(binary())) -> ok | {error, any()}.
add_otp_keys(Uid, OtpKeys) ->
    {ok, _Res} = q(["LPUSH", otp_key(Uid) | OtpKeys]),
    ok.


%% dangerous function - dont use without notice to the team.
-spec delete_all_otp_keys(Uid :: uid()) -> ok.
delete_all_otp_keys(Uid) ->
    % TODO: Just DEL is better
    {ok, _Res} = q(["LTRIM", otp_key(Uid), 1, 0]),
    ok.


-spec get_key_set(Uid :: uid()) -> {ok, maybe(user_whisper_key_set())} | {error, any()}.
get_key_set(Uid) ->
    {ok, [IdentityKey, SignedPreKey]} = q(["HMGET", whisper_key(Uid),
            ?FIELD_IDENTITY_KEY, ?FIELD_SIGNEDPRE_KEY]),
    {ok, OtpKey} = q(["RPOP", otp_key(Uid)]),
    Result = case IdentityKey =:= undefined orelse SignedPreKey =:= undefined of
        true -> undefined;
        false ->
            #user_whisper_key_set{
                uid = Uid,
                identity_key = IdentityKey,
                signed_key = SignedPreKey,
                one_time_key = OtpKey
            }
    end,
    {ok, Result}.


-spec get_key_set_without_otp(Uid :: uid()) -> {ok, maybe(user_whisper_key_set())} | {error, any()}.
get_key_set_without_otp(Uid) ->
    {ok, [IdentityKey, SignedPreKey]} = q(["HMGET", whisper_key(Uid),
            ?FIELD_IDENTITY_KEY, ?FIELD_SIGNEDPRE_KEY]),
    Result = case IdentityKey =:= undefined orelse SignedPreKey =:= undefined of
        true -> undefined;
        false ->
            #user_whisper_key_set{
                uid = Uid,
                identity_key = IdentityKey,
                signed_key = SignedPreKey,
                one_time_key = undefined
            }
    end,
    {ok, Result}.


-spec get_identity_keys(Uids :: [uid()]) -> map() | {error, any()}.
get_identity_keys(Uids) ->
    Commands = [["HGET", whisper_key(Uid), ?FIELD_IDENTITY_KEY] || Uid <- Uids],
    Res = qmn(Commands),
    Result = lists:foldl(
        fun({Uid, {ok, IdentityKey}}, Acc) ->
            case IdentityKey of
                undefined -> Acc;
                _ -> Acc#{Uid => IdentityKey}
            end
        end, #{}, lists:zip(Uids, Res)),
    Result.


-spec count_otp_keys(Uid :: uid()) -> {ok, integer()} | {error, any()}.
count_otp_keys(Uid) ->
    {ok, Count} = q(["LLEN", otp_key(Uid)]),
    {ok, binary_to_integer(Count)}.


-spec remove_all_keys(Uid :: uid()) -> ok | {error, any()}.
remove_all_keys(Uid) ->
    {ok, _Res} = q(["DEL", whisper_key(Uid), otp_key(Uid)]),
    ok.


-spec add_key_subscriber(Uid :: uid(), SubscriberUid :: uid()) -> ok | {error, any()}.
add_key_subscriber(Uid, SubscriberUid) ->
    {ok, _Res} = q(["SADD", subcribers_key(Uid), SubscriberUid]),
    ok.

-spec add_key_subscribers(Uid :: uid(), SubscriberUids :: [uid()]) -> ok | {error, any()}.
add_key_subscribers(_Uid, []) -> ok;
add_key_subscribers(Uid, SubscriberUids) ->
    {ok, _Res} = q(["SADD", subcribers_key(Uid) | SubscriberUids]),
    ok.


-spec remove_key_subscriber(Uid :: uid(), SubscriberUid :: uid()) -> ok | {error, any()}.
remove_key_subscriber(Uid, SubscriberUid) ->
    {ok, _Res} = q(["SREM", subcribers_key(Uid), SubscriberUid]),
    ok.


-spec remove_key_subscribers(Uid :: uid(), SubscriberUids :: [uid()]) -> ok | {error, any()}.
remove_key_subscribers(_Uid, []) -> ok;
remove_key_subscribers(Uid, SubscriberUids) ->
    {ok, _Res} = q(["SREM", subcribers_key(Uid) | SubscriberUids]),
    ok.


-spec get_all_key_subscribers(Uid :: uid()) -> {ok, list(binary())} | {error, any()}.
get_all_key_subscribers(Uid) ->
    q(["SMEMBERS", subcribers_key(Uid)]).


-spec remove_all_key_subscribers(Uid :: uid()) -> ok | {error, any()}.
remove_all_key_subscribers(Uid) ->
    {ok, _Res} = q(["DEL", subcribers_key(Uid)]),
    ok.


mark_e2e_stats_query() ->
    [{ok, Exists}, {ok, _}] = qp([
        ["SETNX", ?E2E_STATS_QUERY_KEY, 1],
        ["EXPIRE", ?E2E_STATS_QUERY_KEY, ?E2E_QUERY_EXPIRY]
    ]),
    Exists =:= <<"1">>.


-spec export_keys(Uid :: uid()) ->
        {ok, IdentityKey :: binary(), SignedPreKey :: binary(), OneTimeKeys ::[binary()]}.
export_keys(Uid) ->
    {ok, [IdentityKey, SignedPreKey]} = q(["HMGET", whisper_key(Uid),
        ?FIELD_IDENTITY_KEY, ?FIELD_SIGNEDPRE_KEY]),
    {ok, OTKs} = q(["LRANGE", otp_key(Uid), 0, -1]),
    {ok, IdentityKey, SignedPreKey, lists:reverse(OTKs)}.


q(Command) -> ecredis:q(ecredis_whisper, Command).
qp(Commands) -> ecredis:qp(ecredis_whisper, Commands).
qmn(Commands) -> ecredis:qmn(ecredis_whisper, Commands).


-spec whisper_key(Uid :: uid()) -> binary().
whisper_key(Uid) ->
    <<?WHISPER_KEY/binary, <<"{">>/binary, Uid/binary, <<"}">>/binary>>.


-spec otp_key(Uid :: uid()) -> binary().
otp_key(Uid) ->
    <<?OTP_KEY/binary, <<"{">>/binary, Uid/binary, <<"}">>/binary>>.


-spec subcribers_key(Uid :: uid()) -> binary().
subcribers_key(Uid) ->
    <<?SUBSCRIBERS_KEY/binary, <<"{">>/binary, Uid/binary, <<"}">>/binary>>.


