%%%-------------------------------------------------------------------
%%% File: model_prompts_tests.erl
%%%
%%% Copyright (C) 2022, Halloapp Inc.
%%%
%%%-------------------------------------------------------------------

-module(model_prompts_tests).
-author('vipin').

-include("tutil.hrl").

-define(PROMPT1, <<"prompt1">>).
-define(PROMPT2, <<"prompt2">>).

setup() ->
    tutil:setup([
        {redis, [redis_feed]}
    ]).


api_test_() ->
    [tutil:setup_foreach(fun setup/0, [
        fun api/1
    ])].

api(_) ->
    [
    ?_assertEqual({ok, []}, model_prompts:get_text_prompts()),
    ?_assertEqual({ok, []}, model_prompts:get_media_prompts()),
    ?_assertOk(model_prompts:add_text_prompts([?PROMPT1, ?PROMPT2])),
    ?_assertOk(model_prompts:add_media_prompts([?PROMPT1, ?PROMPT2])),
    ?_assertEqual({ok, [?PROMPT1, ?PROMPT2]}, model_prompts:get_text_prompts()),
    ?_assertEqual({ok, [?PROMPT1, ?PROMPT2]}, model_prompts:get_media_prompts()),
    ?_assertEqual({ok, ?PROMPT1}, model_prompts:get_text_prompt()),
    ?_assertEqual({ok, ?PROMPT1}, model_prompts:get_media_prompt()),
    ?_assertEqual({ok, [?PROMPT2]}, model_prompts:get_text_prompts()),
    ?_assertEqual({ok, [?PROMPT2]}, model_prompts:get_media_prompts())
    ].


