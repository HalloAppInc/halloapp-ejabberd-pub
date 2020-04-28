%%%-------------------------------------------------------------------
%%% @author nikola
%%% @copyright (C) 2020, Halloapp Inc.
%%% @doc
%%%
%%% @end
%%% Created : 19. Mar 2020 1:19 PM
%%%-------------------------------------------------------------------
-module(model_friends).
-author("nikola").
-behavior(gen_server).
-behavior(gen_mod).

-include("logger.hrl").

-import(lists, [map/2]).

-export([start_link/0]).
%% gen_mod callbacks
-export([start/2, stop/1, depends/2, mod_options/1]).
%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, terminate/2, handle_info/2, code_change/3]).

-export([key/1]).


%% API
-export([
  get_connection/0,
  add_friend/2,
  remove_friend/2,
  get_friends/1,
  is_friend/2,
  set_friends/2,
  remove_all_friends/1]).

start_link() ->
    gen_server:start_link({local, get_proc()}, ?MODULE, [], []).

%%====================================================================
%% gen_mod callbacks
%%====================================================================

start(Host, Opts) ->
    ?INFO_MSG("start ~w", [?MODULE]),
    gen_mod:start_child(?MODULE, Host, Opts, get_proc()).

stop(Host) ->
    ?INFO_MSG("start ~w", [?MODULE]),
    gen_mod:stop_child(?MODULE, Host).

depends(_Host, _Opts) ->
    [{mod_redis, hard}].

mod_options(_Host) ->
    [].

get_proc() ->
    gen_mod:get_module_proc(global, ?MODULE).

%%====================================================================
%% API
%%====================================================================

-define(FRIENDS_KEY, <<"fr:">>).
-define(USER_VAL, <<"">>).

-spec add_friend(Uid :: binary(), Buid :: binary()) -> {ok, boolean()} | {error, any()}.
add_friend(Uid, Buid) ->
    gen_server:call(get_proc(), {add_friend, Uid, Buid}).


-spec remove_friend(Uid :: binary(), Buid :: binary()) -> {ok, boolean()} | {error, any()}.
remove_friend(Uid, Buid) ->
    gen_server:call(get_proc(), {remove_friend, Uid, Buid}).


-spec get_friends(Uid :: binary()) -> {ok, list(binary())} | {error, any()}.
get_friends(Uid) ->
    gen_server:call(get_proc(), {get_friends, Uid}).


-spec is_friend(Uid :: binary(), Buid :: binary()) -> boolean().
is_friend(Uid, Buid) ->
    {ok, Bool} = gen_server:call(get_proc(), {is_friend, Uid, Buid}),
    Bool.


-spec set_friends(Uid :: binary(), Contacts ::[binary()]) -> {ok, boolean()} | {error, any()}.
set_friends(Uid, Contacts) ->
    gen_server:call(get_proc(), {set_friends, Uid, Contacts}).


-spec remove_all_friends(Uid :: binary()) -> {ok, boolean()} | {error, any()}.
remove_all_friends(Uid) ->
    gen_server:call(get_proc(), {remove_all_friends, Uid}).

%%====================================================================
%% gen_server callbacks
%%====================================================================

init(_Stuff) ->
    process_flag(trap_exit, true),
    {ok, redis_friends_client}.


handle_call({get_connection}, _From, Redis) ->
    {reply, {ok, Redis}, Redis};

handle_call({add_friend, Uid, Buid}, _From, Redis) ->
    {ok, _Res1} = q(["HSET", key(Uid), Buid, ?USER_VAL]),
    {ok, _Res2} = q(["HSET", key(Buid), Uid, ?USER_VAL]),
    {reply, ok, Redis};

handle_call({remove_friend, Uid, Buid}, _From, Redis) ->
    {ok, _Res1} = q(["HDEL", key(Uid), Buid]),
    {ok, _Res2} = q(["HDEL", key(Buid), Uid]),
    {reply, ok, Redis};

handle_call({is_friend, Uid, Buid}, _From, Redis) ->
    {ok, Res} = q(["HEXISTS", key(Uid), Buid]),
    {reply, {ok, binary_to_integer(Res) == 1}, Redis};

handle_call({get_friends, Uid}, _From, Redis) ->
    {ok, Friends} = q(["HKEYS", key(Uid)]),
    {reply, {ok, Friends}, Redis};

handle_call({set_friends, Uid, Contacts}, _From, Redis) ->
    UidKey = key(Uid),
    {ok, _Res} = q(["DEL", UidKey]),
    lists:foreach(fun(X) -> q(["HSET", UidKey, X, ?USER_VAL]) end, Contacts),
    lists:foreach(fun(X) -> q(["HSET", key(X), Uid, ?USER_VAL]) end, Contacts),
    {reply, ok, Redis};

handle_call({remove_all_friends, Uid}, _From, Redis) ->
    {ok, Friends} = q(["HKEYS", key(Uid)]),
    lists:foreach(fun(X) -> q(["HDEL", key(X), Uid]) end, Friends),
    {ok, _Res} = q(["DEL", key(Uid)]),
    {reply, ok, Redis}.


handle_cast(_Message, Redis) -> {noreply, Redis}.
handle_info(_Message, Redis) -> {noreply, Redis}.
terminate(_Reason, _Redis) -> ok.
code_change(_OldVersion, Redis, _Extra) -> {ok, Redis}.


q(Command) ->
    {ok, Result} = gen_server:call(redis_friends_client, {q, Command}),
    Result.


-spec key(Uid :: binary()) -> binary().
key(Uid) ->
    <<?FRIENDS_KEY/binary, <<"{">>/binary, Uid/binary, <<"}">>/binary>>.


-spec get_connection() -> Pid::pid().
get_connection() ->
    gen_server:call(?MODULE, {get_connection}).


