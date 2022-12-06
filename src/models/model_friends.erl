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

%% API
-export([
    add_friend/2,
    add_friends/2,
    remove_friend/2,
    get_friends/1,
    is_friend/2,
    remove_all_friends/1,
    get_friend_scores/1,
    set_friend_scores/2
]).

-define(USER_VAL, 0).

%%====================================================================
%% API
%%====================================================================

-spec add_friend(Uid :: uid(), Buid :: uid()) -> ok | {error, any()}.
add_friend(Uid, Buid) ->
    {ok, _Res1} = q(["HSET", friends_key(Uid), Buid, ?USER_VAL]),
    {ok, _Res2} = q(["HSET", friends_key(Buid), Uid, ?USER_VAL]),
    ok.


-spec add_friends(Uid :: uid(), Buids :: [uid()]) -> ok | {error, any()}.
add_friends(Uid, Buids) ->
    Commands1 = lists:map(fun(Buid) -> ["HSET", friends_key(Uid), Buid, ?USER_VAL] end, Buids),
    Commands2 = lists:map(fun(Buid) -> ["HSET", friends_key(Buid), Uid, ?USER_VAL] end, Buids),
    _Res = qmn(Commands1 ++ Commands2),
    ok.


-spec remove_friend(Uid :: uid(), Buid :: uid()) -> ok | {error, any()}.
remove_friend(Uid, Buid) ->
    {ok, _Res1} = q(["HDEL", friends_key(Uid), Buid]),
    {ok, _Res2} = q(["HDEL", friends_key(Buid), Uid]),
    ok.


-spec get_friends(Uid :: uid() | list(uid())) -> {ok, list(uid()) | #{uid() => list(uid())} } | {error, any()}.
get_friends(Uids) when is_list(Uids)->
    Commands = lists:map(fun (Uid) -> 
            ["HKEYS", friends_key(Uid)]
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
    {ok, Result};

get_friends(Uid) ->
    {ok, Friends} = q(["HKEYS", friends_key(Uid)]),
    {ok, Friends}.


-spec is_friend(Uid :: uid(), Buid :: uid()) -> boolean().
is_friend(Uid, Buid) ->
    {ok, Res} = q(["HEXISTS", friends_key(Uid), Buid]),
    binary_to_integer(Res) == 1.


-spec remove_all_friends(Uid :: uid()) -> ok | {error, any()}.
remove_all_friends(Uid) ->
    {ok, Friends} = q(["HKEYS", friends_key(Uid)]),
    lists:foreach(fun(X) -> q(["HDEL", friends_key(X), Uid]) end, Friends),
    {ok, _Res} = q(["DEL", friends_key(Uid)]),
    ok.

%%====================================================================
%% Friend Scoring API
%%====================================================================

-spec get_friend_scores(uid()) -> {ok, #{uid() => integer()}} | {error, any()}.
get_friend_scores(Uid) ->
    UidKey = friends_key(Uid),
    {ok, Res} = q(["HGETALL", UidKey]),
    ScoreMap = lists:foldl( % convert list of [key, value, key1, value1...] to map
        fun (Value, {Buid, Map}) when Value =:= <<"">> -> % need to be compatible with old field data
                Map#{Buid => ?USER_VAL};
            (Value, {Buid, Map}) ->
                Map#{Buid => util:to_integer(Value)};
            (Buid, Map) -> 
                {Buid, Map} % preserve Buid to use as key for following value
        end,
        #{},
        Res),
    {ok, ScoreMap}.

-spec set_friend_scores(Uid :: uid(), ScoreMap :: #{Buid :: uid() => integer()}) -> ok | {error, any()}.
set_friend_scores(Uid, ScoreMap) ->
    UidKey = friends_key(Uid),
    Command = ["HSET", UidKey] ++ lists:foldl(
        fun ({Buid, Score}, Acc) ->
            [Buid | [Score | Acc]]
        end,
        [],
        maps:to_list(ScoreMap)),
    {ok, Res} = case maps:size(ScoreMap) of
        0 -> {ok, 0}; % If ScoreMap is empty, just skip
        _ -> q(Command)
    end,
    case util:to_integer(Res) of 
        0 -> ok;
        Num -> 
            ?INFO("Setting friend scores for ~s added ~p new friends. ScoreMap = ~p", 
                    [Uid, Num, ScoreMap])
    end,
    ok.

%%====================================================================
%% Redis functions
%%====================================================================

q(Command) -> ecredis:q(ecredis_friends, Command).
qmn(Commands) -> ecredis:qmn(ecredis_friends, Commands).


-spec friends_key(Uid :: uid()) -> binary().
friends_key(Uid) ->
    <<?FRIENDS_KEY/binary, <<"{">>/binary, Uid/binary, <<"}">>/binary>>.

