%%%-------------------------------------------------------------------
%%% @author nikola
%%% @copyright (C) 2020, HalloApp, Inc.
%%% @doc
%%%
%%% @end
%%% Created : 09. Apr 2020 2:29 PM
%%%-------------------------------------------------------------------
-module(model_accounts).
-author("nikola").
-behavior(gen_server).
-behavior(gen_mod).

-include("logger.hrl").

%% Export all functions for unit tests
-ifdef(TEST).
-compile(export_all).
-endif.

-import(lists, [map/2]).

-export([start_link/0]).
%% gen_mod callbacks
-export([start/2, stop/1, depends/2, mod_options/1]).
%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, terminate/2, handle_info/2, code_change/3]).

-export([key/1]).


%% API
-export([
    set_name/2,
    get_name/1,
    get_name_binary/1,
    delete_name/1
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

-define(ACCOUNTS_KEY, <<"acc:">>).
-define(FIELD_NAME, <<"na">>).

-spec set_name(Uid :: binary(), Name :: binary()) -> ok  | {error, any()}.
set_name(Uid, Name) ->
    gen_server:call(get_proc(), {set_name, Uid, Name}).

-spec get_name(Uid :: binary()) -> binary() | {ok, string() | undefined} | {error, any()}.
get_name(Uid) ->
    gen_server:call(get_proc(), {get_name, Uid}).

-spec delete_name(Uid :: binary()) -> ok  | {error, any()}.
delete_name(Uid) ->
    gen_server:call(get_proc(), {delete_name, Uid}).

-spec get_name_binary(Uid :: binary()) -> binary().
get_name_binary(Uid) ->
    {ok, Name} = get_name(Uid),
    case Name of
        undefined ->  <<>>;
        _ -> Name
    end.

%%====================================================================
%% gen_server callbacks
%%====================================================================

init(_Stuff) ->
    process_flag(trap_exit, true),
    {ok, redis_accounts_client}.

handle_call({get_connection}, _From, Redis) ->
    {reply, {ok, Redis}, Redis};

handle_call({set_name, Uid, Name}, _From, Redis) ->
    {ok, _Res} = q(["HSET", key(Uid), ?FIELD_NAME, Name]),
    {reply, ok, Redis};

handle_call({get_name, Uid}, _From, Redis) ->
    {ok, Res} = q(["HGET", key(Uid), ?FIELD_NAME]),
    {reply, {ok, Res}, Redis};

handle_call({delete_name, Uid}, _From, Redis) ->
    {ok, Res} = q(["HDEL", key(Uid), ?FIELD_NAME]),
    {reply, {ok, Res}, Redis}.

handle_cast(_Message, Redis) -> {noreply, Redis}.
handle_info(_Message, Redis) -> {noreply, Redis}.
terminate(_Reason, _Redis) -> ok.
code_change(_OldVersion, Redis, _Extra) -> {ok, Redis}.

q(Command) ->
    {ok, Result} = gen_server:call(redis_accounts_client, {q, Command}),
    Result.

-spec key(binary()) -> binary().
key(Uid) ->
    <<?ACCOUNTS_KEY/binary, <<"{">>/binary, Uid/binary, <<"}">>/binary>>.
