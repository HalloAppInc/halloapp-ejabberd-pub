%%%------------------------------------------------------------------------------------
%%% File: model_whisper_keys.erl
%%% Copyright (C) 2020, HalloApp, Inc.
%%%
%%% This model handles all the redis db queries that are related with whisper keys.
%%%
%%%------------------------------------------------------------------------------------
-module(model_whisper_keys).
-author('murali').
-behavior(gen_mod).

-include("logger.hrl").
-include("redis_keys.hrl").
-include("whisper.hrl").
-include("ha_types.hrl").

%% Export all functions for unit tests
-ifdef(TEST).
-compile(export_all).
-endif.

%% gen_mod callbacks
-export([start/2, stop/1, depends/2, mod_options/1]).

-export([whisper_key/1, otp_key/1, subcribers_key/1]).


%% API
-export([
    set_keys/4,
    add_otp_keys/2,
    get_key_set/1,
    get_key_set_without_otp/1,
    remove_all_keys/1,
    count_otp_keys/1,
    add_key_subscriber/2,
    remove_key_subscriber/2,
    get_all_key_subscribers/1,
    remove_all_key_subscribers/1,
    delete_all_otp_keys/1  %% dangerous function - dont use without talking to the team.
]).

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


-spec remove_key_subscriber(Uid :: uid(), SubscriberUid :: uid()) -> ok | {error, any()}.
remove_key_subscriber(Uid, SubscriberUid) ->
    {ok, _Res} = q(["SREM", subcribers_key(Uid), SubscriberUid]),
    ok.


-spec get_all_key_subscribers(Uid :: uid()) -> {ok, list(binary())} | {error, any()}.
get_all_key_subscribers(Uid) ->
    q(["SMEMBERS", subcribers_key(Uid)]).


-spec remove_all_key_subscribers(Uid :: uid()) -> ok | {error, any()}.
remove_all_key_subscribers(Uid) ->
    {ok, _Res} = q(["DEL", subcribers_key(Uid)]),
    ok.


q(Command) -> ecredis:q(ecredis_whisper, Command).
qp(Commands) -> ecredis:qp(ecredis_whisper, Commands).


-spec whisper_key(Uid :: uid()) -> binary().
whisper_key(Uid) ->
    <<?WHISPER_KEY/binary, <<"{">>/binary, Uid/binary, <<"}">>/binary>>.


-spec otp_key(Uid :: uid()) -> binary().
otp_key(Uid) ->
    <<?OTP_KEY/binary, <<"{">>/binary, Uid/binary, <<"}">>/binary>>.


-spec subcribers_key(Uid :: uid()) -> binary().
subcribers_key(Uid) ->
    <<?SUBSCRIBERS_KEY/binary, <<"{">>/binary, Uid/binary, <<"}">>/binary>>.


