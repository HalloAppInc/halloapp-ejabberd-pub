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

-include("logger.hrl").
-include("redis_keys.hrl").
-include("ha_types.hrl").

-import(lists, [map/2]).

-export([key/1]).


%% API
-export([
    get_connection/0,
    add_friend/2,
    add_friends/2,
    remove_friend/2,
    get_friends/1,
    get_friends_multi/1,
    is_friend/2,
    set_friends/2,
    remove_all_friends/1
]).

%%====================================================================
%% API
%%====================================================================


-define(USER_VAL, <<"">>).

-spec add_friend(Uid :: uid(), Buid :: uid()) -> ok | {error, any()}.
add_friend(Uid, Buid) ->
    {ok, _Res1} = q(["HSET", key(Uid), Buid, ?USER_VAL]),
    {ok, _Res2} = q(["HSET", key(Buid), Uid, ?USER_VAL]),
    ok.


-spec add_friends(Uid :: uid(), Buids :: [uid()]) -> ok | {error, any()}.
add_friends(Uid, Buids) ->
    Commands1 = lists:map(fun(Buid) -> ["HSET", key(Uid), Buid, ?USER_VAL] end, Buids),
    Commands2 = lists:map(fun(Buid) -> ["HSET", key(Buid), Uid, ?USER_VAL] end, Buids),
    _Res = qmn(Commands1 ++ Commands2),
    ok.


-spec remove_friend(Uid :: uid(), Buid :: uid()) -> ok | {error, any()}.
remove_friend(Uid, Buid) ->
    {ok, _Res1} = q(["HDEL", key(Uid), Buid]),
    {ok, _Res2} = q(["HDEL", key(Buid), Uid]),
    ok.


-spec get_friends(Uid :: uid()) -> {ok, list(binary())} | {error, any()}.
get_friends(Uid) ->
    {ok, Friends} = q(["HKEYS", key(Uid)]),
    {ok, Friends}.


-spec get_friends_multi(Uids :: [uid()]) -> {ok, map()} | {error, any()}.
get_friends_multi(Uids) ->
    Commands = lists:map(fun (Uid) -> 
            ["HKEYS", key(Uid)] 
        end, 
        Uids),
    Res = qmn(Commands),
    Result = lists:foldl(
        fun({Uid, {ok, Friends}}, Acc) ->
            case Friends of
                undefined -> Acc;
                _ -> Acc#{Uid => Friends}
            end
        end, #{}, lists:zip(Uids, Res)),
    {ok, Result}.

-spec is_friend(Uid :: uid(), Buid :: uid()) -> boolean().
is_friend(Uid, Buid) ->
    {ok, Res} = q(["HEXISTS", key(Uid), Buid]),
    binary_to_integer(Res) == 1.


-spec set_friends(Uid :: uid(), Contacts ::[binary()]) -> ok | {error, any()}.
set_friends(Uid, Contacts) ->
    UidKey = key(Uid),
    {ok, _Res} = q(["DEL", UidKey]),
    lists:foreach(fun(X) -> q(["HSET", UidKey, X, ?USER_VAL]) end, Contacts),
    lists:foreach(fun(X) -> q(["HSET", key(X), Uid, ?USER_VAL]) end, Contacts),
    ok.


-spec remove_all_friends(Uid :: uid()) -> ok | {error, any()}.
remove_all_friends(Uid) ->
    {ok, Friends} = q(["HKEYS", key(Uid)]),
    lists:foreach(fun(X) -> q(["HDEL", key(X), Uid]) end, Friends),
    {ok, _Res} = q(["DEL", key(Uid)]),
    ok.


q(Command) -> ecredis:q(ecredis_friends, Command).
qmn(Commands) -> ecredis:qmn(ecredis_friends, Commands).


-spec key(Uid :: uid()) -> binary().
key(Uid) ->
    <<?FRIENDS_KEY/binary, <<"{">>/binary, Uid/binary, <<"}">>/binary>>.


-spec get_connection() -> Pid::pid().
get_connection() ->
    gen_server:call(?MODULE, {get_connection}).

