%%%------------------------------------------------------------------------------------
%%% File: model_prompts.erl
%%% Copyright (C) 2022, HalloApp, Inc.
%%%
%%%------------------------------------------------------------------------------------
-module(model_prompts).
-author('vipin').

-include("ha_types.hrl").
-include("logger.hrl").
-include("redis_keys.hrl").

-export([
    get_used_album_prompts/0,
    get_used_text_prompts/0,
    get_used_camera_prompts/0,
    update_used_album_prompts/2,
    update_used_text_prompts/2,
    update_used_camera_prompts/2
]).


get_used_album_prompts() ->
    get_used_prompts(used_album_prompts_key()).

get_used_text_prompts() ->
    get_used_prompts(used_text_prompts_key()).

get_used_camera_prompts() ->
    get_used_prompts(used_camera_prompts_key()).

-spec get_used_prompts(binary()) -> list({PromptId :: binary(), Timestamp :: binary()}).
get_used_prompts(Key) ->
    {ok, ResultList} = q(["ZRANGE", Key, 0, -1, "WITHSCORES"]),
    util_redis:parse_zrange_with_scores(ResultList).


update_used_album_prompts(ToAdd, ToRemoveList) ->
    update_used_prompts(used_album_prompts_key(), ToAdd, ToRemoveList).

update_used_text_prompts(ToAdd, ToRemoveList) ->
    update_used_prompts(used_text_prompts_key(), ToAdd, ToRemoveList).

update_used_camera_prompts(ToAdd, ToRemoveList) ->
    update_used_prompts(used_camera_prompts_key(), ToAdd, ToRemoveList).

-spec update_used_prompts(Key :: binary(), ToAdd :: {PromptId :: binary(), Timestamp :: pos_integer()},
    ToRemoveList :: list(PromptId :: binary())) -> ok.
update_used_prompts(Key, {PromptId, Timestamp}, []) ->
    q(["ZADD", Key, Timestamp, PromptId]),
    ok;

update_used_prompts(Key, {PromptId, Timestamp}, ToRemoveList) ->
    Commands = [
        ["ZADD", Key, Timestamp, PromptId],
        ["ZREM", Key] ++ ToRemoveList
    ],
    qp(Commands),
    ok.


used_album_prompts_key() ->
    used_prompts_key(<<"album">>).

used_text_prompts_key() ->
    used_prompts_key(<<"text">>).

used_camera_prompts_key() ->
    used_prompts_key(<<"media">>).

used_prompts_key(Type) ->
    <<?USED_PROMPTS_KEY/binary, "{", Type/binary, "}">>.


q(Command) -> ecredis:q(ecredis_feed, Command).
qp(Commands) -> ecredis:qp(ecredis_feed, Commands).

