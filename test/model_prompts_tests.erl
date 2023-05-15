%%%-------------------------------------------------------------------
%%% File: model_prompts_tests.erl
%%%
%%% Copyright (C) 2022, Halloapp Inc.
%%%
%%%-------------------------------------------------------------------

-module(model_prompts_tests).
-author('vipin').

-include("tutil.hrl").

-define(TEXT_ID1, <<"text.1">>).
-define(TEXT_ID2, <<"text.2">>).
-define(MEDIA_ID1, <<"media.1">>).
-define(ALBUM_ID1, <<"album.1">>).

setup() ->
    tutil:setup([
        {redis, [redis_feed]}
    ]).


api_testset(_) ->
    Ts1 = 1,
    Ts2 = 2,
    [
        ?_assertEqual([], model_prompts:get_used_camera_prompts()),
        ?_assertEqual([], model_prompts:get_used_text_prompts()),
        ?_assertEqual([], model_prompts:get_used_album_prompts()),
        ?_assertOk(model_prompts:update_used_text_prompts({?TEXT_ID1, Ts1}, [])),
        ?_assertEqual([], model_prompts:get_used_camera_prompts()),
        ?_assertEqual([{?TEXT_ID1, util:to_binary(Ts1)}], model_prompts:get_used_text_prompts()),
        ?_assertEqual([], model_prompts:get_used_album_prompts()),
        ?_assertOk(model_prompts:update_used_text_prompts({?TEXT_ID2, Ts2}, [?TEXT_ID1])),
        ?_assertEqual([], model_prompts:get_used_camera_prompts()),
        ?_assertEqual([{?TEXT_ID2, util:to_binary(Ts2)}], model_prompts:get_used_text_prompts()),
        ?_assertEqual([], model_prompts:get_used_album_prompts())
    ].


