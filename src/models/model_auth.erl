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

%% API
-export([
    set_spub/2,
    get_spub/1,
    delete_spub/1,
    lock_user/1,
    unlock_user/1
]).

%%====================================================================
%% API
%%====================================================================

-define(FIELD_TIMESTAMP_MS, <<"tms">>).
-define(FIELD_S_PUB, <<"spb">>).


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


-spec spub_key(binary()) -> binary().
spub_key(Uid) ->
    <<?SPUB_KEY/binary, <<"{">>/binary, Uid/binary, <<"}">>/binary>>.

