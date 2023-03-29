%%%---------------------------------------------------------------------------------
%%% File    : mod_prompts.erl
%%%
%%% Copyright (C) 2022 HalloApp Inc.
%%%
%%%---------------------------------------------------------------------------------

-module(mod_prompts).
-author('vipin').
-behaviour(gen_mod).

-include("ha_types.hrl").
-include("logger.hrl").
-include("moments.hrl").
-include("prompts.hrl").
-include("time.hrl").

-ifdef(TEST).
-export([
    get_text_prompts/0,
    get_media_prompts/0
]).
-endif.

-export([
    start/2,
    stop/1,
    reload/3,
    depends/2,
    mod_options/1,
    get_prompt_and_mark_used/1,
    get_prompt_from_id/1,
    get_prompt_image_bytes/1
]).

%%====================================================================

start(_Host, _Opts) ->
    ?INFO("Start ~w", [?MODULE]),
    ok.

stop(_Host) ->
    ?INFO("Stop ~w", [?MODULE]),
    ok.

depends(_Host, _Opts) ->
    [].

reload(_Host, _NewOpts, _OldOpts) ->
    ok.

mod_options(_Host) ->
    [].

%%====================================================================

-spec get_prompt_and_mark_used(Type :: moment_type()) -> PromptId :: binary().
get_prompt_and_mark_used(Type) ->
    {GetUsedPromptsFun, UpdateUsedPromptsFun, AllPrompts} = case Type of
        text_post ->
            {fun model_prompts:get_used_text_prompts/0, fun model_prompts:update_used_text_prompts/2, get_text_prompts()};
        live_camera ->
            {fun model_prompts:get_used_media_prompts/0, fun model_prompts:update_used_media_prompts/2, get_media_prompts()};
        album_post ->
            {fun model_prompts:get_used_album_prompts/0, fun model_prompts:update_used_album_prompts/2, get_album_prompts()};
        _ ->
            ?ERROR("Unexpected type, defaulting to media prompt: ~p", [Type]),
            {fun model_prompts:get_used_media_prompts/0, fun model_prompts:update_used_media_prompts/2, get_media_prompts()}
    end,
    UsedPrompts = GetUsedPromptsFun(),
    %% Here we will check and separate prompts that can be reused again
    {UnusablePrompts, PromptsThatCanBeUsedAgain} = lists:foldl(
        fun({PromptId, BinTimestamp}, {NotUsable, Usable}) ->
            Timestamp = util_redis:decode_int(BinTimestamp),
            PromptRecord = maps:get(PromptId, AllPrompts, #prompt{reuse_after = 1000 * ?MONTHS}),
            case (util:now() - Timestamp) < PromptRecord#prompt.reuse_after of
                true ->
                    {[PromptId | NotUsable], Usable};
                false ->
                    {NotUsable, [PromptId | Usable]}
            end
        end,
        {[], []},
        UsedPrompts),
    PromptIdsToChooseFrom = maps:keys(AllPrompts) -- UnusablePrompts,
    ChosenPromptId = lists:nth(rand:uniform(length(PromptIdsToChooseFrom)), PromptIdsToChooseFrom),
    UpdateUsedPromptsFun({ChosenPromptId, util:now()}, PromptsThatCanBeUsedAgain),
    ChosenPromptId.


-spec get_prompt_from_id(PromptId :: binary()) -> maybe(prompt_record()).
get_prompt_from_id(PromptId) ->
    case PromptId of
        <<"text", _/binary>> ->
            maps:get(PromptId, get_text_prompts(), undefined);
        <<"media", _/binary>> ->
            maps:get(PromptId, get_media_prompts(), undefined);
        <<"album", _/binary>> ->
            maps:get(PromptId, get_album_prompts(), undefined);
        _ ->
            undefined
    end.


get_prompt_image_bytes(ImageId) ->
    FilePath = "/home/ec2-user/prompt_images/" ++ util:to_list(ImageId),
    case file:read_file(FilePath) of
        {ok, ImageBytes} ->
            ImageBytes;
        {error, Error} ->
            ?ERROR("Unable to open image ~p: ~p", [FilePath, Error]),
            <<>>
    end.

%%====================================================================

get_album_prompts() ->
    #{
        <<"album.1">> =>
            #prompt{
                id = <<"album.1">>,
                text = <<"WYD?">>,
                reuse_after = 6 * ?MONTHS
            }
    }.

get_text_prompts() ->
    #{
        <<"text.1">> =>
            #prompt{
                id = <<"text.1">>,
                text = <<"What food are you craving right now?">>,
                reuse_after = 6 * ?MONTHS},
        <<"text.2">> =>
            #prompt{
                id = <<"text.2">>,
                text = <<"Describe your day in emojis">>,
                reuse_after = 6 * ?MONTHS},
        <<"text.3">> =>
            #prompt{
                id = <<"text.3">>,
                text = <<"If you could live in any time period, which one would you choose?">>,
                reuse_after = 6 * ?MONTHS},
        <<"text.4">> =>
            #prompt{
                id = <<"text.4">>,
                text = <<"A movie you thought was overrated, but turned out great">>,
                reuse_after = 6 * ?MONTHS},
        <<"text.5">> =>
            #prompt{
                id = <<"text.5">>,
                text = <<"If you had to listen to only one artist for a week, who would it be?">>,
                reuse_after = 6 * ?MONTHS},
        <<"text.6">> =>
            #prompt{
                id = <<"text.6">>,
                text = <<"What food did you hate as a child?">>,
                reuse_after = 6 * ?MONTHS}
    }.


get_media_prompts() ->
    #{
        <<"media.1">> =>
            #prompt{
                id = <<"media.1">>,
                text = <<"WYD?">>,
                reuse_after = 0}
    }.

