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
  gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%%====================================================================
%% gen_mod callbacks
%%====================================================================

start(Host, Opts) ->
  ?INFO_MSG("start ~w", [?MODULE]),
  gen_mod:start_child(?MODULE, Host, Opts).

stop(Host) ->
  ?INFO_MSG("start ~w", [?MODULE]),
  gen_mod:stop_child(?MODULE, Host).

depends(_Host, _Opts) ->
  [{mod_redis, hard}].

mod_options(_Host) ->
  [].

%%====================================================================
%% API
%%====================================================================

-define(FRIENDS_KEY, "fr:").
-define(USER_VAL, "u").

-spec add_friend(integer(), integer()) -> {ok, boolean()} | {error, any()}.
add_friend(Uid, Buid) ->
  gen_server:call(?MODULE, {add_friend, Uid, Buid}).

-spec remove_friend(integer(), integer()) -> {ok, boolean()} | {error, any()}.
remove_friend(Uid, Buid) ->
  gen_server:call(?MODULE, {remove_friend, Uid, Buid}).

-spec get_friends(integer()) -> {ok, list(integer())} | {error, any()}.
get_friends(Uid) ->
  gen_server:call(?MODULE, {get_friends, Uid}).

-spec is_friend(integer(), integer()) -> {ok, boolean()} | {error, any()}.
is_friend(Uid, Buid) ->
  gen_server:call(?MODULE, {is_friend, Uid, Buid}).

-spec set_friends(integer(), list(integer())) -> {ok, boolean()} | {error, any()}.
set_friends(Uid, Contacts) ->
  gen_server:call(?MODULE, {set_friends, Uid, Contacts}).

-spec remove_all_friends(integer()) -> {ok, boolean()} | {error, any()}.
remove_all_friends(Uid) ->
  gen_server:call(?MODULE, {remove_all_friends, Uid}).

%%====================================================================
%% gen_server callbacks
%%====================================================================

init(_Stuff) ->
  process_flag(trap_exit, true),
  {ok, redis_friends_client}.

handle_call({get_connection}, _From, Redis) ->
  {reply, {ok, Redis}, Redis};

handle_call({add_friend, Uid, Buid}, _From, Redis) ->
  {ok, Res} = q(["HSET", key(Uid), Buid, ?USER_VAL]),
  {reply, {ok, binary_to_integer(Res) > 0}, Redis};

handle_call({remove_friend, Uid, Buid}, _From, Redis) ->
  {ok, Res} = q(["HDEL", key(Uid), Buid]),
  {reply, {ok, binary_to_integer(Res) > 0}, Redis};

handle_call({is_friend, Uid, Buid}, _From, Redis) ->
  {ok, Res} = q(["HEXISTS", key(Uid), Buid]),
  {reply, {ok, binary_to_integer(Res) == 1}, Redis};

handle_call({get_friends, Uid}, _From, Redis) ->
  {ok, Contacts} = q(["HKEYS", key(Uid)]),
  {reply, {ok, map(fun(X) -> binary_to_integer(X) end, Contacts)}, Redis};

handle_call({set_friends, Uid, Contacts}, _From, Redis) ->
  Contacts2 = lists:flatmap(fun(X) -> [X, ?USER_VAL] end, Contacts),
  {ok, Results} = gen_server:call(redis_friends_client, {qp, [
    ["MULTI"],
    ["DEL", key(Uid)],
    ["HSET", key(Uid)] ++ Contacts2,
    ["EXEC"]]}),
  [Result|_Rest] = lists:reverse(Results),
  {ok, [_DelRes, Count]} = Result,
  {reply, {ok, binary_to_integer(Count)}, Redis};

handle_call({remove_all_friends, Uid}, _From, Redis) ->
  {ok, Res} = q(["DEL", key(Uid)]),
  {reply, {ok, binary_to_integer(Res) == 1}, Redis}.

handle_cast(_Message, Redis) -> {noreply, Redis}.
handle_info(_Message, Redis) -> {noreply, Redis}.
terminate(_Reason, _Redis) -> ok.
code_change(_OldVersion, Redis, _Extra) -> {ok, Redis}.

q(Command) ->
  {ok, Result} = gen_server:call(redis_friends_client, {q, Command}),
  Result.

-spec key(integer()) -> string().
key(Uid) ->
  ?FRIENDS_KEY ++ "{" ++ integer_to_list(Uid) ++ "}".

-spec get_connection() -> Pid::pid().
get_connection() ->
  gen_server:call(?MODULE, {get_connection}).


