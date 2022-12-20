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

%% API
-export([
    get_text_prompts/0,
    get_media_prompts/0,
    get_text_prompt/0,
    get_media_prompt/0,
    add_text_prompts/1,
    add_media_prompts/1
]).

-spec get_text_prompts() -> {ok, [binary()]} | {error, any()}.
get_text_prompts() ->
    q(["LRANGE", text_prompt_key(), 0, -1]).

-spec get_media_prompts() -> {ok, [binary()]} | {error, any()}.
get_media_prompts() ->
    q(["LRANGE", media_prompt_key(), 0, -1]).

-spec get_text_prompt() -> {ok, maybe(binary())} | {error, any()}.
get_text_prompt() ->
    q(["LPOP", text_prompt_key()]).

-spec get_media_prompt() -> {ok, maybe(binary())} | {error, any()}.
get_media_prompt() ->
    q(["LPOP", media_prompt_key()]).

-spec add_text_prompts(Prompts :: [binary()]) -> ok | {error, any()}.
add_text_prompts(Prompts) ->
    q(["RPUSH", text_prompt_key() | Prompts]),
    ok.

-spec add_media_prompts(Prompts :: [binary()]) -> ok | {error, any()}.
add_media_prompts(Prompts) ->
    q(["RPUSH", media_prompt_key() | Prompts]),
    ok.

q(Command) -> ecredis:q(ecredis_feed, Command).

-spec text_prompt_key() -> binary().
text_prompt_key() ->
    <<?PROMPT_KEY/binary, "{text_prompt}">>.

-spec media_prompt_key() -> binary().
media_prompt_key() ->
    <<?PROMPT_KEY/binary, "{media_prompt}">>.

