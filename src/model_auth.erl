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
-behavior(gen_server).
-behavior(gen_mod).

-include("logger.hrl").
-include("password.hrl").
-include("redis_keys.hrl").

%% Export all functions for unit tests
-ifdef(TEST).
-compile(export_all).
-endif.

-export([start_link/0]).
%% gen_mod callbacks
-export([start/2, stop/1, depends/2, mod_options/1]).
%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, terminate/2, handle_info/2, code_change/3]).

%% API
-export([
    set_password/3,
    get_password/1,
    delete_password/1
]).

start_link() ->
    gen_server:start_link({local, get_proc()}, ?MODULE, [], []).

%%====================================================================
%% gen_mod callbacks
%%====================================================================

start(Host, Opts) ->
    ?INFO_MSG("start ~w", [?MODULE]),
    gen_mod:start_child(?MODULE, Host, Opts, get_proc()).

stop(_Host) ->
    ?INFO_MSG("stop ~w", [?MODULE]),
    gen_mod:stop_child(get_proc()).

depends(_Host, _Opts) ->
    [{mod_redis, hard}].

mod_options(_Host) ->
    [].

get_proc() ->
    gen_mod:get_module_proc(global, ?MODULE).

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
    gen_server:call(get_proc(), {set_password, Uid, Salt, HashedPassword, TimestampMs}).


-spec get_password(Uid :: binary()) -> {ok, password()} | {error, missing}.
get_password(Uid) ->
    gen_server:call(get_proc(), {get_password, Uid}).

-spec delete_password(Uid :: binary()) -> ok  | {error, any()}.
delete_password(Uid) ->
    gen_server:call(get_proc(), {delete_password, Uid}).

%%====================================================================
%% gen_server callbacks
%%====================================================================

init(_Stuff) ->
    process_flag(trap_exit, true),
    {ok, redis_auth_client}.

handle_call({get_connection}, _From, Redis) ->
    {reply, {ok, Redis}, Redis};

handle_call({set_password, Uid, Salt, HashedPassword, TimestampMs}, _From, Redis) ->
    Commands = [
        ["DEL", password_key(Uid)],
        ["HSET", password_key(Uid),
            ?FIELD_SALT, Salt,
            ?FIELD_HASHED_PASSWORD, HashedPassword,
            ?FIELD_TIMESTAMP_MS, integer_to_binary(TimestampMs)]
    ],
    {ok, [_DelResult, <<"3">>]} = multi_exec(Commands),
    {reply, ok, Redis};

handle_call({get_password, Uid}, _From, Redis) ->
    {ok, [Salt, HashedPassword, TsMsBinary]} = q(["HMGET", password_key(Uid),
        ?FIELD_SALT, ?FIELD_HASHED_PASSWORD, ?FIELD_TIMESTAMP_MS]),
    {reply, {ok, #password{
        salt = Salt,
        hashed_password = HashedPassword,
        ts_ms = decode_ts(TsMsBinary),
        uid = Uid
    }}, Redis};

handle_call({delete_password, Uid}, _From, Redis) ->
    {ok, _Res} = q(["DEL", password_key(Uid)]),
    {reply, ok, Redis}.

handle_cast(_Message, Redis) -> {noreply, Redis}.
handle_info(_Message, Redis) -> {noreply, Redis}.
terminate(_Reason, _Redis) -> ok.
code_change(_OldVersion, Redis, _Extra) -> {ok, Redis}.

decode_ts(TsMsBinary) ->
    case TsMsBinary of
        undefined -> undefined;
        X -> binary_to_integer(X)
    end.

q(Command) ->
    {ok, Result} = gen_server:call(redis_auth_client, {q, Command}),
    Result.

qp(Commands) ->
    {ok, Results} = gen_server:call(redis_auth_client, {qp, Commands}),
    Results.

multi_exec(Commands) ->
    WrappedCommands = lists:append([[["MULTI"]], Commands, [["EXEC"]]]),
    {ok, Results} = gen_server:call(redis_auth_client, {qp, WrappedCommands}),
    [ExecResult|_Rest] = lists:reverse(Results),
    ExecResult.

-spec password_key(binary()) -> binary().
password_key(Uid) ->
    <<?PASSWORD_KEY/binary, <<"{">>/binary, Uid/binary, <<"}">>/binary>>.
