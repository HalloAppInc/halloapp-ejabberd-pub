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

%% Export all functions for unit tests
-ifdef(TEST).
-compile(export_all).
-endif.


%% gen_mod callbacks
-export([start/2, stop/1, depends/2, mod_options/1]).

%% API
-export([
    set_password/3,
    get_password/1,
    delete_password/1
]).

%%====================================================================
%% gen_mod callbacks
%%====================================================================

start(Host, Opts) ->
    ?INFO_MSG("start ~w", [?MODULE]),
    ok.

stop(_Host) ->
    ?INFO_MSG("stop ~w", [?MODULE]),
    ok.

depends(_Host, _Opts) ->
    [{mod_redis, hard}].

mod_options(_Host) ->
    [].

%%====================================================================
%% API
%%====================================================================

-define(FIELD_SALT, <<"sal">>).
-define(FIELD_HASHED_PASSWORD, <<"hpw">>).
-define(FIELD_TIMESTAMP_MS, <<"tms">>).

-spec set_password(Uid :: binary(), Salt :: binary(), HashedPassword :: binary()) ->
    ok  | {error, any()}.
set_password(Uid, Salt, HashedPassword) ->
    set_password(Uid, Salt, HashedPassword, util:now_ms()).


-spec set_password(Uid :: binary(), Salt :: binary(), HashedPassword :: binary(),
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


-spec get_password(Uid :: binary()) -> {ok, password()} | {error, missing}.
get_password(Uid) ->
    {ok, [Salt, HashedPassword, TsMsBinary]} = q(["HMGET", password_key(Uid),
        ?FIELD_SALT, ?FIELD_HASHED_PASSWORD, ?FIELD_TIMESTAMP_MS]),
    {ok, #password{
        salt = Salt,
        hashed_password = HashedPassword,
        ts_ms = util_redis:decode_ts(TsMsBinary),
        uid = Uid
    }}.


-spec delete_password(Uid :: binary()) -> ok  | {error, any()}.
delete_password(Uid) ->
    {ok, _Res} = q(["DEL", password_key(Uid)]),
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

