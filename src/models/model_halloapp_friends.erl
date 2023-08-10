%%%-------------------------------------------------------------------
%%%
%%% @copyright (C) 2023, Halloapp Inc.
%%% @doc
%%%
%%% @end
%%%-------------------------------------------------------------------
-module(model_halloapp_friends).
-author('murali').

-include("logger.hrl").
-include("redis_keys.hrl").
-include("ha_types.hrl").

%% For testing
-ifdef(TEST).
-compile(export_all).
-endif.

%% API
-export([
    add_friend_request/2,
    accept_friend_request/2,
    is_friend/2,
    is_friend_pending/2,
    get_friends/3,
    get_outgoing_friends/3,
    get_incoming_friends/3,
    get_all_friends/1,
    get_all_outgoing_friends/1,
    get_all_incoming_friends/1,
    get_num_mutual_friends/2,
    get_friend_status/2,
    remove_friend/2,
    remove_all_friends/1,
    remove_all_outgoing_friends/1,
    remove_all_incoming_friends/1,
    get_random_friends/2,
    update_contact_suggestions/2,
    update_fof_suggestions/2,
    get_contact_suggestions/1,
    get_fof_suggestions/1,
    block/2,
    unblock/2,
    is_blocked/2,
    is_blocked_by/2,
    is_blocked_any/2,
    get_blocked_uids/1,
    get_blocked_by_uids/1,
    remove_all_blocked_uids/1,
    remove_all_blocked_by_uids/1,
    blocked_key/1
]).

-define(USER_VAL, 0).

%%====================================================================
%% API
%%====================================================================

-spec add_friend_request(Uid :: uid(), Ouid :: uid()) -> ok | {error, any()}.
add_friend_request(Uid, Ouid) ->
    TimestampMs = util:now_ms(),
    {ok, _Res1} = q(["ZADD", outgoing_friends_key(Uid), TimestampMs, Ouid]),
    {ok, _Res2} = q(["ZADD", incoming_friends_key(Ouid), TimestampMs, Uid]),
    ok.


-spec accept_friend_request(Uid :: uid(), Ouid :: uid()) -> ok | {error, any()}.
accept_friend_request(Uid, Ouid) ->
    TimestampMs = util:now_ms(),
    [{ok, _}, {ok, _}] = qp([
        ["ZREM", incoming_friends_key(Uid), Ouid],
        ["ZADD", friends_key(Uid), TimestampMs, Ouid]
        ]),
    [{ok, _}, {ok, _}] = qp([
        ["ZREM", outgoing_friends_key(Ouid), Uid],
        ["ZADD", friends_key(Ouid), TimestampMs, Uid]
        ]),
    ok.


-spec is_friend(Uid :: uid(), Ouid :: uid()) -> true | false.
is_friend(Uid, Ouid) ->
    {ok, Res} = q(["ZSCORE", friends_key(Uid), Ouid]),
    util_redis:decode_int(Res) =/= undefined.


-spec is_friend_pending(Uid :: uid(), Ouid :: uid()) -> true | false.
is_friend_pending(Uid, Ouid) ->
    [{ok, Res1}, {ok, Res2}] = qp([
        ["ZSCORE", outgoing_friends_key(Uid), Ouid],
        ["ZSCORE", incoming_friends_key(Uid), Ouid]]),
    util_redis:decode_int(Res1) =/= undefined orelse util_redis:decode_int(Res2) =/= undefined.


-spec get_friends(Uid :: uid(), Cursor :: binary(), Limit :: pos_integer()) ->
    {Uids :: list(uid()), NewCursor :: binary()}.
get_friends(Uid, Cursor, Limit) ->
    get_all(friends_key(Uid), Cursor, Limit).


-spec get_outgoing_friends(Uid :: uid(), Cursor :: binary(), Limit :: pos_integer()) ->
    {Uids :: list(uid()), NewCursor :: binary()}.
get_outgoing_friends(Uid, Cursor, Limit) ->
    get_all(outgoing_friends_key(Uid), Cursor, Limit).


-spec get_incoming_friends(Uid :: uid(), Cursor :: binary(), Limit :: pos_integer()) ->
    {Uids :: list(uid()), NewCursor :: binary()}.
get_incoming_friends(Uid, Cursor, Limit) ->
    get_all(incoming_friends_key(Uid), Cursor, Limit).


-spec get_all_friends(Uid :: uid()) -> [uid()].
get_all_friends(Uid) ->
    {ok, FriendUids} = q(["ZRANGE", friends_key(Uid), "0", "-1"]),
    FriendUids.


-spec get_all_outgoing_friends(Uid :: uid()) -> [uid()].
get_all_outgoing_friends(Uid) ->
    {ok, OutgoingFriendUids} = q(["ZRANGE", outgoing_friends_key(Uid), "0", "-1"]),
    OutgoingFriendUids.


-spec get_all_incoming_friends(Uid :: uid()) -> [uid()].
get_all_incoming_friends(Uid) ->
    {ok, IncomingFriendUids} = q(["ZRANGE", incoming_friends_key(Uid), "0", "-1"]),
    IncomingFriendUids.


-spec get_num_mutual_friends(Uid :: uid(), Ouids :: uid() | list(uid())) -> integer() | list(integer()).
get_num_mutual_friends(_Uid, []) -> [];
get_num_mutual_friends(Uid, Ouids) when is_list(Ouids) ->
    %% TODO: improve this by switching to qmn.
    [get_num_mutual_friends(Uid, Ouid) || Ouid <- Ouids];
get_num_mutual_friends(Uid, Ouid) ->
    UidFriendSet = sets:from_list(get_all_friends(Uid)),
    OuidFriendSet = sets:from_list(get_all_friends(Ouid)),
    sets:size(sets:intersection(UidFriendSet, OuidFriendSet)).


-spec get_friend_status(Uid :: uid(), Ouid :: uid()) -> atom().
get_friend_status(Uid, Ouid) ->
    [{ok, FriendsResult}, {ok, OutgoingFriendsResult}, {ok, IncomingFriendsResult}] = qp([
        ["ZSCORE", friends_key(Uid), Ouid],
        ["ZSCORE", outgoing_friends_key(Uid), Ouid],
        ["ZSCORE", incoming_friends_key(Uid), Ouid]]),
    case util_redis:decode_int(FriendsResult) =/= undefined of
        true ->
            friends;
        false ->
            case util_redis:decode_int(OutgoingFriendsResult) =/= undefined of
                true ->
                    outgoing_pending;
                false ->
                    case util_redis:decode_int(IncomingFriendsResult) =/= undefined of
                        true ->
                            incoming_pending;
                        false ->
                            none_status
                    end
            end
    end.


-spec remove_friend(Uid :: uid(), Ouid :: uid()) -> ok.
remove_friend(Uid, Ouid) ->
    [{ok, _}, {ok, _}, {ok, _}, {ok, _}, {ok, _}, {ok, _}] = qmn([
        ["ZREM", friends_key(Uid), Ouid],
        ["ZREM", friends_key(Ouid), Uid],
        ["ZREM", outgoing_friends_key(Uid), Ouid],
        ["ZREM", incoming_friends_key(Ouid), Uid],
        ["ZREM", incoming_friends_key(Uid), Ouid],
        ["ZREM", outgoing_friends_key(Ouid), Uid]
        ]),
    ok.


-spec remove_all_friends(Uid :: uid()) -> ok.
remove_all_friends(Uid) ->
    {ok, Friends} = q(["ZRANGE", friends_key(Uid), "0", "-1"]),
    lists:foreach(fun(X) -> q(["ZREM", friends_key(X), Uid]) end, Friends),
    {ok, _Res} = q(["DEL", friends_key(Uid)]),
    ok.


-spec remove_all_outgoing_friends(Uid :: uid()) -> ok.
remove_all_outgoing_friends(Uid) ->
    {ok, Friends} = q(["ZRANGE", outgoing_friends_key(Uid), "0", "-1"]),
    lists:foreach(fun(X) -> q(["ZREM", incoming_friends_key(X), Uid]) end, Friends),
    {ok, _Res} = q(["DEL", outgoing_friends_key(Uid)]),
    ok.


-spec remove_all_incoming_friends(Uid :: uid()) -> ok.
remove_all_incoming_friends(Uid) ->
    {ok, Friends} = q(["ZRANGE", incoming_friends_key(Uid), "0", "-1"]),
    lists:foreach(fun(X) -> q(["ZREM", outgoing_friends_key(X), Uid]) end, Friends),
    {ok, _Res} = q(["DEL", incoming_friends_key(Uid)]),
    ok.


-spec get_random_friends(Uids :: [uid()] | uid(), Limit :: integer()) -> [uid()].
get_random_friends(Uids, Limit) when is_list(Uids) ->
    Commands = lists:map(
        fun(Uid) ->
            ["ZRANDMEMBER", friends_key(Uid), Limit]
        end, Uids),
    Res = qmn(Commands),
    Result = lists:flatmap(fun({ok, Friends}) -> Friends end, Res),
    Result;
get_random_friends(Uid, Limit) ->
    get_random_friends([Uid], Limit).


-spec update_contact_suggestions(Uid :: uid(), Suggestions :: [uid()]) -> ok.
update_contact_suggestions(_Uid, []) -> ok;
update_contact_suggestions(Uid, ContactSuggestionsList) ->
    [{ok, _}, {ok, _}] = qp([
        ["DEL", contact_suggestions_key(Uid)],
        ["RPUSH", contact_suggestions_key(Uid) | ContactSuggestionsList]]),
    ok.


-spec update_fof_suggestions(Uid :: uid(), Suggestions :: [uid()]) -> ok.
update_fof_suggestions(_Uid, []) -> ok;
update_fof_suggestions(Uid, FoFSuggestionsList) ->
    [{ok, _}, {ok, _}] = qp([
        ["DEL", fof_suggestions_key(Uid)],
        ["RPUSH", fof_suggestions_key(Uid) | FoFSuggestionsList]]),
    ok.


-spec get_contact_suggestions(Uid :: uid()) -> [uid()].
get_contact_suggestions(Uid) ->
    {ok, ContactSuggestionsList} = q(["LRANGE", contact_suggestions_key(Uid), "0", "-1"]),
    ContactSuggestionsList.


-spec get_fof_suggestions(Uid :: uid()) -> [uid()].
get_fof_suggestions(Uid) ->
    {ok, FoFSuggestionsList} = q(["LRANGE", fof_suggestions_key(Uid), "0", "-1"]),
    FoFSuggestionsList.


%% Uid blocks Ouid
-spec block(Uid :: uid(), Ouid :: uid()) -> ok.
block(Uid, Ouid) ->
    [{ok, _}, {ok, _}, {ok, _}, {ok, _}] = qp([
        ["ZREM", friends_key(Uid), Ouid],
        ["ZREM", outgoing_friends_key(Uid), Ouid],
        ["ZREM", incoming_friends_key(Uid), Ouid],
        ["SADD", blocked_key(Uid), Ouid]
    ]),
    [{ok, _}, {ok, _}, {ok, _}, {ok, _}] = qp([
        ["ZREM", friends_key(Ouid), Uid],
        ["ZREM", outgoing_friends_key(Ouid), Uid],
        ["ZREM", incoming_friends_key(Ouid), Uid],
        ["SADD", blocked_by_key(Ouid), Uid]
    ]),
    ok.


%% Uid unblocks Ouid
-spec unblock(Uid :: uid(), Ouid :: uid()) -> ok.
unblock(Uid, Ouid) ->
    [{ok, _}, {ok, _}] = qmn([
        ["SREM", blocked_key(Uid), Ouid],
        ["SREM", blocked_by_key(Ouid), Uid]
    ]),
    ok.


%% Uid blocked Ouid ?
-spec is_blocked(Uid :: uid(), Ouid :: uid()) -> boolean().
is_blocked(Uid, Ouid) ->
    {ok, Res} = q(["SISMEMBER", blocked_key(Uid), Ouid]),
    util_redis:decode_boolean(Res).


%% Uid is blocked by Ouid ?
-spec is_blocked_by(Uid :: uid(), Ouid :: uid()) -> boolean().
is_blocked_by(Uid, Ouid) ->
    {ok, Res} = q(["SISMEMBER", blocked_by_key(Uid), Ouid]),
    util_redis:decode_boolean(Res).


%% Uid blocked Ouid  or  Ouid blocked Uid
-spec is_blocked_any(Uid :: uid(), Ouid :: uid()) -> boolean().
is_blocked_any(Uid, Ouid) ->
    [{ok, Res1}, {ok, Res2}] = qp([
        ["SISMEMBER", blocked_key(Uid), Ouid],
        ["SISMEMBER", blocked_by_key(Uid), Ouid]
    ]),
    util_redis:decode_boolean(Res1) orelse util_redis:decode_boolean(Res2).


%% Get list of uids that Uid has blocked
-spec get_blocked_uids(Uid :: uid()) -> list(uid()) | {error, any()}.
get_blocked_uids(Uid) ->
    {ok, Res} = q(["SMEMBERS", blocked_key(Uid)]),
    Res.


%% Get list of uids that have blocked Uid
-spec get_blocked_by_uids(Uid :: uid()) -> list(uid()) | {error, any()}.
get_blocked_by_uids(Uid) ->
    {ok, Res} = q(["SMEMBERS", blocked_by_key(Uid)]),
    Res.


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


%%====================================================================
%% Internal functions
%%====================================================================

get_all(Key, Cursor, Limit) when Cursor =:= <<>> orelse Cursor =:= undefined ->
    {ok, RawRes} = q(["ZRANGE", Key, "+inf", "-inf", "BYSCORE", "REV", "LIMIT", 0, Limit, "WITHSCORES"]),
    Res = util_redis:parse_zrange_with_scores(RawRes),
    {Uids, Scores} = lists:unzip(Res),
    case length(Uids) < Limit orelse length(Uids) =:= 0 of
        true -> {Uids, <<>>};
        false -> {Uids, lists:last(Scores)}
    end;

get_all(Key, Cursor, Limit) ->
    {ok, RawRes} = q(["ZRANGE", Key, <<"(", Cursor/binary>>, "-inf", "BYSCORE", "REV", "LIMIT", 0, Limit, "WITHSCORES"]),
    Res = util_redis:parse_zrange_with_scores(RawRes),
    {Uids, Scores} = lists:unzip(Res),
    case length(Uids) < Limit orelse length(Uids) =:= 0 of
        true -> {Uids, <<>>};
        false -> {Uids, lists:last(Scores)}
    end.


%%====================================================================
%% Redis functions
%%====================================================================

q(Command) -> ecredis:q(ecredis_accounts, Command).
qp(Commands) -> ecredis:qp(ecredis_accounts, Commands).
qmn(Commands) -> ecredis:qmn(ecredis_accounts, Commands).


-spec friends_key(Uid :: uid()) -> binary().
friends_key(Uid) ->
    <<?HALLOAPP_FRIENDS_KEY/binary, <<"{">>/binary, Uid/binary, <<"}">>/binary>>.

-spec outgoing_friends_key(Uid :: uid()) -> binary().
outgoing_friends_key(Uid) ->
    <<?OUTGOING_FRIENDS_KEY/binary, <<"{">>/binary, Uid/binary, <<"}">>/binary>>.

-spec incoming_friends_key(Uid :: uid()) -> binary().
incoming_friends_key(Uid) ->
    <<?INCOMING_FRIENDS_KEY/binary, <<"{">>/binary, Uid/binary, <<"}">>/binary>>.

blocked_key(Uid) ->
    <<?BLOCKED_KEY/binary, <<"{">>/binary, Uid/binary, <<"}">>/binary>>.

blocked_by_key(Uid) ->
    <<?BLOCKED_BY_KEY/binary, <<"{">>/binary, Uid/binary, <<"}">>/binary>>.

contact_suggestions_key(Uid) ->
    <<?CONTACT_SUGGESTIONS_KEY/binary, "{", Uid/binary, "}">>.

fof_suggestions_key(Uid) ->
    <<?FOF_SUGGESTIONS_KEY/binary, "{", Uid/binary, "}">>.

