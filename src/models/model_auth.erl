%%%-------------------------------------------------------------------
%%% @author nikola
%%% @copyright (C) 2020, HalloApp, Inc.
%%% @doc
%%%
%%% @end
%%% Created : 15. Apr 2020 2:53 PM
%%%-------------------------------------------------------------------
-module(model_auth).
-author("nikola").
-behavior(gen_mod).

-include("logger.hrl").
-include("password.hrl").
-include("redis_keys.hrl").
-include("ha_types.hrl").

%% Export all functions for unit tests
-ifdef(TEST).
-compile(export_all).
-endif.

-define(LOCKED, <<"locked:">>).
-define(LOCKED_SIZE, byte_size(?LOCKED)).


%% gen_mod callbacks
-export([start/2, stop/1, depends/2, mod_options/1]).

%% API
-export([
    set_password/3,
    get_password/1,
    delete_password/1,
    set_spub/2,
    get_spub/1,
    delete_spub/1,
    lock_user/1,
    unlock_user/1
]).

%%====================================================================
%% gen_mod callbacks
%%====================================================================

start(_Host, _Opts) ->
    ?INFO("start ~w", [?MODULE]),
    ok.

stop(_Host) ->
    ?INFO("stop ~w", [?MODULE]),
    ok.

depends(_Host, _Opts) ->
    [].

mod_options(_Host) ->
    [].

%%====================================================================
%% API
%%====================================================================

-define(FIELD_SALT, <<"sal">>).
-define(FIELD_HASHED_PASSWORD, <<"hpw">>).
-define(FIELD_TIMESTAMP_MS, <<"tms">>).
-define(FIELD_S_PUB, <<"spb">>).

-spec set_password(Uid :: uid(), Salt :: binary(), HashedPassword :: binary()) ->
    ok  | {error, any()}.
set_password(Uid, Salt, HashedPassword) ->
    set_password(Uid, Salt, HashedPassword, util:now_ms()).


-spec set_password(Uid :: uid(), Salt :: binary(), HashedPassword :: binary(),
        TimestampMs :: integer()) -> ok  | {error, any()}.
set_password(Uid, Salt, HashedPassword, TimestampMs) ->
    Commands = [
        ["DEL", password_key(Uid)],
        ["HSET", password_key(Uid),
            ?FIELD_SALT, Salt,
            ?FIELD_HASHED_PASSWORD, HashedPassword,
            ?FIELD_TIMESTAMP_MS, integer_to_binary(TimestampMs)]
    ],
    {ok, [_DelResult, <<"3">>]} = multi_exec(Commands),
    ok.


-spec set_spub(Uid :: binary(), SPub :: binary()) -> ok  | {error, any()}.
set_spub(Uid, SPub) ->
    TimestampMs = util:now_ms(),
    Commands = [
        ["DEL", spub_key(Uid)],
        ["HSET", spub_key(Uid),
            ?FIELD_S_PUB, SPub,
            ?FIELD_TIMESTAMP_MS, integer_to_binary(TimestampMs)]
    ],
    {ok, [_DelResult, <<"2">>]} = multi_exec(Commands),
    ok.


%% TODO: spec says this function returns {error, missing}, but it does not
-spec get_password(Uid :: uid()) -> {ok, password()} | {error, missing}.
get_password(Uid) ->
    {ok, [Salt, HashedPassword, TsMsBinary]} = q(["HMGET", password_key(Uid),
        ?FIELD_SALT, ?FIELD_HASHED_PASSWORD, ?FIELD_TIMESTAMP_MS]),
    {ok, #password{
        salt = Salt,
        hashed_password = HashedPassword,
        ts_ms = util_redis:decode_ts(TsMsBinary),
        uid = Uid
    }}.


-spec get_spub(Uid :: binary()) -> {ok, binary()} | {error, missing}.
get_spub(Uid) ->
    {ok, [SPub, TsMsBinary]} = q(["HMGET", spub_key(Uid),
        ?FIELD_S_PUB, ?FIELD_TIMESTAMP_MS]),
    {ok, #s_pub{
        s_pub = SPub,
        ts_ms = util_redis:decode_ts(TsMsBinary),
        uid = Uid
    }}.


-spec lock_user(Uid :: binary()) -> ok | {error, any()}.
lock_user(Uid) ->
    {ok, #s_pub{s_pub = SPub, ts_ms = _TsMs, uid = _Uid}} = get_spub(Uid),
    {Locked, LockedSize} = {?LOCKED, ?LOCKED_SIZE},
    case SPub of
        <<Locked:LockedSize/binary, _Rest/binary>> -> ok;
        _ ->
            SPub2 = <<?LOCKED/binary, SPub/binary>>,
            set_spub(Uid, SPub2)
    end.


-spec unlock_user(Uid :: binary()) -> ok | {error, any()}.
unlock_user(Uid) ->
    {ok, #s_pub{s_pub = LockedSPub, ts_ms = _TsMs, uid = _Uid}} = get_spub(Uid),
    {Locked, LockedSize} = {?LOCKED, ?LOCKED_SIZE},
    case LockedSPub of
        <<Locked:LockedSize/binary, Rest/binary>> -> set_spub(Uid, Rest);
        _ -> ok
    end.
        

-spec delete_password(Uid :: binary()) -> ok  | {error, any()}.
delete_password(Uid) ->
    {ok, _Res} = q(["DEL", password_key(Uid)]),
    ok.


-spec delete_spub(Uid :: binary()) -> ok  | {error, any()}.
delete_spub(Uid) ->
    {ok, _Res} = q(["DEL", spub_key(Uid)]),
    ok.


q(Command) -> ecredis:q(ecredis_auth, Command).
qp(Commands) -> ecredis:qp(ecredis_auth, Commands).


multi_exec(Commands) ->
    WrappedCommands = lists:append([[["MULTI"]], Commands, [["EXEC"]]]),
    Results = qp(WrappedCommands),
    [ExecResult|_Rest] = lists:reverse(Results),
    ExecResult.


-spec password_key(binary()) -> binary().
password_key(Uid) ->
    <<?PASSWORD_KEY/binary, <<"{">>/binary, Uid/binary, <<"}">>/binary>>.

-spec spub_key(binary()) -> binary().
spub_key(Uid) ->
    <<?SPUB_KEY/binary, <<"{">>/binary, Uid/binary, <<"}">>/binary>>.

