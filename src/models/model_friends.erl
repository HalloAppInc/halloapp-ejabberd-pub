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
    add_outgoing_friend/2,
    remove_outgoing_friend/2,
    remove_all_outgoing_friends/1,
    get_outgoing_friends/1,
    is_outgoing/2,
    ignore_incoming_friend/2,
    remove_all_incoming_friends/1,
    is_ignored/2,
    get_incoming_friends/1,
    is_incoming/2,
    add_friend/2,
    add_friends/2,
    remove_friend/2,
    get_friends/1,
    is_friend/2,
    remove_all_friends/1,
    get_friend_scores/1,
    set_friend_scores/2,
    get_mutual_friends/2,
    get_mutual_friends_count/2,
    block/2,
    unblock/2,
    remove_all_blocked_uids/1,
    remove_all_blocked_by_uids/1,
    get_blocked_uids/1,
    is_blocked/2,
    get_blocked_by_uids/1,
    is_blocked_by/2,
    is_blocked_any/2
]).

-define(USER_VAL, 0).

%%====================================================================
%% API
%%====================================================================

%% Outgoing friend = add request sent
-spec add_outgoing_friend(Uid :: uid(), Buid :: uid()) -> ok | {error, any()}.
add_outgoing_friend(Uid, Buid) ->
    {ok, _Res1} = q(["SADD", outgoing_key(Uid), Buid]),
    {ok, _Res2} = q(["SADD", incoming_key(Buid), Uid]),
    ok.


-spec remove_outgoing_friend(Uid :: uid(), Buid :: uid()) -> ok | {error, any()}.
remove_outgoing_friend(Uid, Buid) ->
    {ok, _Res1} = q(["SREM", outgoing_key(Uid), Buid]),
    {ok, _Res2} = q(["SREM", incoming_key(Buid), Uid]),
    ok.


-spec remove_all_outgoing_friends(Uid :: uid()) -> ok.
remove_all_outgoing_friends(Uid) ->
    OutgoingFriends = get_outgoing_friends(Uid),
    CommandsList = lists:map(
        fun(Ouid) ->
            {["SREM", outgoing_key(Uid), Ouid], ["SREM", incoming_key(Ouid), Uid]}
        end,
        OutgoingFriends),
    {OutgoingCommandList, IncomingCommandList} = lists:unzip(CommandsList),
    _OutgoingResults = qp(OutgoingCommandList),
    _IncomingResults = qmn(IncomingCommandList),
    ok.


-spec get_outgoing_friends(Uid :: uid()) -> list(uid()).
get_outgoing_friends(Uid) ->
    {ok, Res} = q(["SMEMBERS", outgoing_key(Uid)]),
    Res.


-spec is_outgoing(Uid :: uid(), Buid :: uid()) -> boolean().
is_outgoing(Uid, Buid) ->
    {ok, Res} = q(["SISMEMBER", outgoing_key(Uid), Buid]),
    util_redis:decode_boolean(Res).


%% Incoming friend = add request received
-spec ignore_incoming_friend(Uid :: uid(), Buid :: uid()) -> ok | {error, any()}.
ignore_incoming_friend(Uid, Buid) ->
    {ok, _Res1} = q(["SREM", incoming_key(Uid), Buid]),
    ok.


-spec remove_all_incoming_friends(Uid :: uid()) -> ok.
remove_all_incoming_friends(Uid) ->
    IncomingFriends = get_incoming_friends(Uid),
    CommandsList = lists:map(
        fun(Ouid) ->
            {["SREM", incoming_key(Uid), Ouid], ["SREM", outgoing_key(Ouid), Uid]}
        end,
        IncomingFriends),
    {IncomingCommandList, OutgoingCommandList} = lists:unzip(CommandsList),
    _OutgoingResults = qmn(OutgoingCommandList),
    _IncomingResults = qp(IncomingCommandList),
    ok.


-spec is_ignored(Uid :: uid(), Ouid :: uid()) -> boolean().
is_ignored(Uid, Ouid) ->
    is_outgoing(Ouid, Uid) andalso not is_incoming(Uid, Ouid).


-spec get_incoming_friends(Uid :: uid()) -> list(uid()).
get_incoming_friends(Uid) ->
    {ok, Res} = q(["SMEMBERS", incoming_key(Uid)]),
    Res.


-spec is_incoming(Uid :: uid(), Buid :: uid()) -> boolean().
is_incoming(Uid, Buid) ->
    {ok, Res} = q(["SISMEMBER", incoming_key(Uid), Buid]),
    util_redis:decode_boolean(Res).


%% Friend = mutually added
-spec add_friend(Uid :: uid(), Buid :: uid()) -> ok | {error, any()}.
add_friend(Uid, Buid) ->
    [{ok, _}, {ok, _}, {ok, _}] = qp([
        ["HSET", friends_key(Uid), Buid, ?USER_VAL],
        ["SREM", outgoing_key(Uid), Buid],
        ["SREM", incoming_key(Uid), Buid]
    ]),
    [{ok, _}, {ok, _}, {ok, _}] = qp([
        ["HSET", friends_key(Buid), Uid, ?USER_VAL],
        ["SREM", outgoing_key(Buid), Uid],
        ["SREM", incoming_key(Buid), Uid]
    ]),
    ok.

-spec add_friends(Uid :: uid(), Buids :: [uid()]) -> ok | {error, any()}.
add_friends(Uid, Buids) ->
    Commands1 = lists:foldl(fun(Buid, Acc) ->
            Acc ++
                [["HSET", friends_key(Uid), Buid, ?USER_VAL]] ++
                [["SREM", outgoing_key(Uid), Buid]] ++
                [["SREM", incoming_key(Uid), Buid]]
        end, [], Buids),
    Commands2 = lists:foldl(fun(Buid, Acc) ->
            Acc ++
                [["HSET", friends_key(Buid), Uid, ?USER_VAL]] ++
                [["SREM", outgoing_key(Buid), Uid]] ++
                [["SREM", incoming_key(Buid), Uid]]
        end, [], Buids),
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


-spec get_mutual_friends(Uid1 :: uid(), Uid2 :: uid()) -> list(uid()).
get_mutual_friends(Uid1, Uid2) ->
    {ok, Uid1Friends} = model_friends:get_friends(Uid1),
    {ok, Uid2Friends} = model_friends:get_friends(Uid2),
    sets:to_list(sets:intersection(sets:from_list(Uid1Friends), sets:from_list(Uid2Friends))).


-spec get_mutual_friends_count(Uid1 :: uid(), Uid2 :: uid()) -> non_neg_integer().
get_mutual_friends_count(Uid1, Uid2) ->
    length(get_mutual_friends(Uid1, Uid2)).


-spec block(Uid :: uid(), Ouid :: uid()) -> ok | {error, any()}.
block(Uid, Ouid) ->
    [{ok, _}, {ok, _}, {ok, _}, {ok, _}] = qp([
        ["HDEL", friends_key(Ouid), Uid],
        ["SREM", outgoing_key(Ouid), Uid],
        ["SREM", incoming_key(Ouid), Uid],
        ["SADD", blocked_by_key(Ouid), Uid]
    ]),
    [{ok, _}, {ok, _}, {ok, _}, {ok, _}] = qp([
        ["HDEL", friends_key(Uid), Ouid],
        ["SREM", outgoing_key(Uid), Ouid],
        ["SREM", incoming_key(Uid), Ouid],
        ["SADD", blocked_key(Uid), Ouid]
    ]),
    ok.


-spec unblock(Uid :: uid(), Ouid :: uid()) -> ok | {error, any()}.
unblock(Uid, Ouid) ->
    [{ok, _}, {ok, _}] = qmn([
        ["SREM", blocked_key(Uid), Ouid],
        ["SREM", blocked_by_key(Ouid), Uid]
    ]),
    ok.


-spec remove_all_blocked_uids(Uid :: uid()) -> ok.
remove_all_blocked_uids(Uid) ->
    BlockedUsers = get_blocked_uids(Uid),
    CommandsList = lists:map(
        fun(Ouid) ->
            {["SREM", blocked_key(Uid), Ouid], ["SREM", blocked_by_key(Ouid), Uid]}
        end,
        BlockedUsers),
    {BlockedList, BlockedByList} = lists:unzip(CommandsList),
    _BlockedResults = qp(BlockedList),
    _BlockedByResults = qmn(BlockedByList),
    ok.


-spec remove_all_blocked_by_uids(Uid :: uid()) -> ok.
remove_all_blocked_by_uids(Uid) ->
    BlockedByUsers = get_blocked_by_uids(Uid),
    CommandsList = lists:map(
        fun(Ouid) ->
            {["SREM", blocked_by_key(Uid), Ouid], ["SREM", blocked_key(Ouid), Uid]}
        end,
        BlockedByUsers),
    {BlockedByList, BlockedList} = lists:unzip(CommandsList),
    _BlockedResults = qmn(BlockedList),
    _BlockedByResults = qp(BlockedByList),
    ok.


-spec get_blocked_uids(Uid :: uid()) -> list(uid()) | {error, any()}.
get_blocked_uids(Uid) ->
    {ok, Res} = q(["SMEMBERS", blocked_key(Uid)]),
    Res.


-spec is_blocked(Uid :: uid(), Ouid :: uid()) -> boolean().
is_blocked(Uid, Ouid) ->
    {ok, Res} = q(["SISMEMBER", blocked_key(Uid), Ouid]),
    util_redis:decode_boolean(Res).


-spec get_blocked_by_uids(Uid :: uid()) -> list(uid()) | {error, any()}.
get_blocked_by_uids(Uid) ->
    {ok, Res} = q(["SMEMBERS", blocked_by_key(Uid)]),
    Res.


-spec is_blocked_by(Uid :: uid(), Ouid :: uid()) -> boolean().
is_blocked_by(Uid, Ouid) ->
    {ok, Res} = q(["SISMEMBER", blocked_by_key(Uid), Ouid]),
    util_redis:decode_boolean(Res).


-spec is_blocked_any(Uid :: uid(), Ouid :: uid()) -> boolean().
is_blocked_any(Uid, Ouid) ->
    [{ok, Res1}, {ok, Res2}] = qp([
        ["SISMEMBER", blocked_key(Uid), Ouid],
        ["SISMEMBER", blocked_by_key(Uid), Ouid]
    ]),
    util_redis:decode_boolean(Res1) orelse util_redis:decode_boolean(Res2).

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
qp(Commands) -> ecredis:qp(ecredis_friends, Commands).
qmn(Commands) -> ecredis:qmn(ecredis_friends, Commands).


-spec friends_key(Uid :: uid()) -> binary().
friends_key(Uid) ->
    <<?FRIENDS_KEY/binary, <<"{">>/binary, Uid/binary, <<"}">>/binary>>.

-spec outgoing_key(Uid :: uid()) -> binary().
outgoing_key(Uid) ->
    <<?ADDED_KEY/binary, <<"{">>/binary, Uid/binary, <<"}">>/binary>>.

-spec incoming_key(Uid :: uid()) -> binary().
incoming_key(Uid) ->
    <<?PENDING_KEY/binary, <<"{">>/binary, Uid/binary, <<"}">>/binary>>.

-spec blocked_key(Uid :: uid()) -> binary().
blocked_key(Uid) ->
    <<?BLOCKED_KEY/binary, <<"{">>/binary, Uid/binary, <<"}">>/binary>>.

-spec blocked_by_key(Uid :: uid()) -> binary().
blocked_by_key(Uid) ->
    <<?BLOCKED_BY_KEY/binary, <<"{">>/binary, Uid/binary, <<"}">>/binary>>.
