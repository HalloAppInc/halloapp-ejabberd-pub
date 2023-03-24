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
        %% TODO: logic to reuse these after 6 months
%%    <<"What food are you craving right now?">>,
%%    <<"Describe your day in emojis">>,
%%    <<"If you could live in any time period, which one would you choose?">>,
%%    <<"A movie you thought was overrated, but turned out great">>,
%%    <<"If you had to listen to only one artist for a week, who would it be?">>
        <<"What food did you hate as a child?">>
    ].

get_media_prompts() ->
    [
    <<"WYD?">>,
    <<"WYD?">>,
    <<"WYD?">>,
    <<"WYD?">>,
    <<"WYD?">>,
    <<"WYD?">>,
    <<"WYD?">>,
    <<"WYD?">>,
    <<"WYD?">>
    ].

