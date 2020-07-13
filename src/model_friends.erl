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
-behavior(gen_mod).

-include("logger.hrl").
-include("redis_keys.hrl").

-import(lists, [map/2]).

%% gen_mod callbacks
-export([start/2, stop/1, depends/2, mod_options/1]).

-export([key/1]).


%% API
-export([
    get_connection/0,
    add_friend/2,
    remove_friend/2,
    get_friends/1,
    is_friend/2,
    set_friends/2,
    remove_all_friends/1
]).


%%====================================================================
%% gen_mod callbacks
%%====================================================================


start(_Host, _Opts) ->
    ?INFO_MSG("start ~w", [?MODULE]),
    ok.

stop(_Host) ->
    ?INFO_MSG("start ~w", [?MODULE]),
    ok.

depends(_Host, _Opts) ->
    [{mod_redis, hard}].

mod_options(_Host) ->
    [].


%%====================================================================
%% API
%%====================================================================


-define(USER_VAL, <<"">>).

-spec add_friend(Uid :: binary(), Buid :: binary()) -> ok | {error, any()}.
add_friend(Uid, Buid) ->
    {ok, _Res1} = q(["HSET", key(Uid), Buid, ?USER_VAL]),
    {ok, _Res2} = q(["HSET", key(Buid), Uid, ?USER_VAL]),
    ok.


-spec remove_friend(Uid :: binary(), Buid :: binary()) -> ok | {error, any()}.
remove_friend(Uid, Buid) ->
    {ok, _Res1} = q(["HDEL", key(Uid), Buid]),
    {ok, _Res2} = q(["HDEL", key(Buid), Uid]),
    ok.


-spec get_friends(Uid :: binary()) -> {ok, list(binary())} | {error, any()}.
get_friends(Uid) ->
    {ok, Friends} = q(["HKEYS", key(Uid)]),
    {ok, Friends}.


-spec is_friend(Uid :: binary(), Buid :: binary()) -> boolean().
is_friend(Uid, Buid) ->
    {ok, Res} = q(["HEXISTS", key(Uid), Buid]),
    binary_to_integer(Res) == 1.


-spec set_friends(Uid :: binary(), Contacts ::[binary()]) -> ok | {error, any()}.
set_friends(Uid, Contacts) ->
    UidKey = key(Uid),
    {ok, _Res} = q(["DEL", UidKey]),
    lists:foreach(fun(X) -> q(["HSET", UidKey, X, ?USER_VAL]) end, Contacts),
    lists:foreach(fun(X) -> q(["HSET", key(X), Uid, ?USER_VAL]) end, Contacts),
    ok.


-spec remove_all_friends(Uid :: binary()) -> ok | {error, any()}.
remove_all_friends(Uid) ->
    {ok, Friends} = q(["HKEYS", key(Uid)]),
    lists:foreach(fun(X) -> q(["HDEL", key(X), Uid]) end, Friends),
    {ok, _Res} = q(["DEL", key(Uid)]),
    ok.


q(Command) -> util_redis:q(redis_friends_client, Command).


-spec key(Uid :: binary()) -> binary().
key(Uid) ->
    <<?FRIENDS_KEY/binary, <<"{">>/binary, Uid/binary, <<"}">>/binary>>.


-spec get_connection() -> Pid::pid().
get_connection() ->
    gen_server:call(?MODULE, {get_connection}).

