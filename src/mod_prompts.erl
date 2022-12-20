%%%---------------------------------------------------------------------------------
%%% File    : mod_prompts.erl
%%%
%%% Copyright (C) 2022 HalloApp Inc.
%%%
%%%---------------------------------------------------------------------------------

-module(mod_prompts).
-author('vipin').
-behaviour(gen_mod).

-include("logger.hrl").

-export([
    start/2,
    stop/1,
    reload/3,
    depends/2,
    mod_options/1,
    get_prompt/1
]).



start(_Host, _Opts) ->
    {ok, TextPrompts} = model_prompts:get_text_prompts(),
    case length(TextPrompts) =:= 0 of
        true -> model_prompts:add_text_prompts(get_text_prompts());
        false -> ok
    end,
    {ok, MediaPrompts} = model_prompts:get_media_prompts(),
    case length(MediaPrompts) =:= 0 of
        true -> model_prompts:add_media_prompts(get_media_prompts());
        false -> ok
    end,
    ok.

stop(_Host) ->
    ok.

depends(_Host, _Opts) ->
    [].

reload(_Host, _NewOpts, _OldOpts) ->
    ok.

mod_options(_Host) ->
    [].

%%====================================================================

get_prompt(text_post) -> get_text_prompt();
get_prompt(live_camera) -> get_media_prompt();
get_prompt(Type) ->
    ?ERROR("Got invalid type: ~p", [Type]),
    get_media_prompt().

get_text_prompt() ->
    {ok, Prompt} = model_prompts:get_text_prompt(),
    case Prompt of
        undefined ->
            ?ERROR("Need to add more prompts", []),
            model_prompts:add_text_prompts(get_text_prompts()),
            <<"VIBE CHECK">>;
        _ -> Prompt
    end.

get_media_prompt() ->
    {ok, Prompt} = model_prompts:get_media_prompt(),
    case Prompt of
        undefined ->
            ?ERROR("Need to add more prompts", []),
            model_prompts:add_media_prompts(get_media_prompts()),
            <<"WYD?">>;
        _ -> Prompt
    end.

%%====================================================================

get_text_prompts() ->
    [
    <<"Vibe Check1">>,
    <<"Vibe Check2">>,
    <<"Vibe Check3">>,
    <<"Vibe Check4">>,
    <<"Vibe Check4">>,
    <<"Vibe Check6">>,
    <<"Vibe Check7">>,
    <<"Vibe Check8">>,
    <<"Vibe Check9">>
    ].

get_media_prompts() ->
    [
    <<"WYD1?">>,
    <<"WYD2?">>,
    <<"WYD3?">>,
    <<"WYD4?">>,
    <<"WYD5?">>,
    <<"WYD6?">>,
    <<"WYD7?">>,
    <<"WYD8?">>,
    <<"WYD9?">>
    ].

