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
    get_camera_prompts/0
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
    get_prompt_image_bytes/1,
    get_prompt_text/2
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
            {fun model_prompts:get_used_camera_prompts/0, fun model_prompts:update_used_camera_prompts/2, get_camera_prompts()};
        album_post ->
            {fun model_prompts:get_used_album_prompts/0, fun model_prompts:update_used_album_prompts/2, get_album_prompts()};
        _ ->
            ?ERROR("Unexpected type, defaulting to camera prompt: ~p", [Type]),
            {fun model_prompts:get_used_camera_prompts/0, fun model_prompts:update_used_camera_prompts/2, get_camera_prompts()}
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
    case PromptIdsToChooseFrom of
        [] ->
            %% Choose prompt that was used most amount of time ago
            {ChosenPromptId, _} = lists:foldl(
                fun({PromptId, BinTimestamp}, {OldestPrompt, OldestPromptTimestamp}) ->
                    Timestamp = util_redis:decode_int(BinTimestamp),
                    case Timestamp < OldestPromptTimestamp of
                        true -> {PromptId, Timestamp};
                        false -> {OldestPrompt, OldestPromptTimestamp}
                    end
                end,
                {<<"">>, 9223372036854775807},  %% 64-bit max int – Timestamp should always be less
                UsedPrompts),
            ?ERROR("No usable ~p prompts, chose oldest promptId: ~p", [Type, ChosenPromptId]),
            %% some crash in the following line. todo: fix it separately.
            %% alerts:send_no_prompts_alert(util:to_binary(Type), ChosenPromptId),
            ChosenPromptId;
        _ ->
            ChosenPromptId = lists:nth(rand:uniform(length(PromptIdsToChooseFrom)), PromptIdsToChooseFrom),
            UpdateUsedPromptsFun({ChosenPromptId, util:now()}, PromptsThatCanBeUsedAgain),
            ChosenPromptId
    end.


-spec get_prompt_from_id(PromptId :: binary()) -> maybe(prompt_record()).
get_prompt_from_id(PromptId) ->
    case PromptId of
        <<"text", _/binary>> ->
            maps:get(PromptId, get_text_prompts(), undefined);
        <<"camera", _/binary>> ->
            maps:get(PromptId, get_camera_prompts(), undefined);
        <<"album", _/binary>> ->
            maps:get(PromptId, get_album_prompts(), undefined);
        _ ->
            undefined
    end.


get_prompt_image_bytes(ImageId) ->
    case ImageId of
        <<>> -> <<>>;
        _ ->
            FilePath = "/home/ec2-user/prompt_images/" ++ util:to_list(ImageId),
            case file:read_file(FilePath) of
                {ok, ImageBytes} ->
                    ImageBytes;
                {error, Error} ->
                    ?ERROR("Unable to open image ~p: ~p", [FilePath, Error]),
                    <<>>
            end
    end.


-spec get_prompt_text(uid(), prompt_record()) -> binary().
get_prompt_text(Uid, PromptRecord) ->
    %% Overrides for dev users
    case dev_users:is_dev_uid(Uid) of
        false ->
            PromptRecord#prompt.text;
        true ->
            case PromptRecord#prompt.id of
                <<"camera.1">> ->
                    <<"WYD?"/utf8>>;
                _ ->
                    PromptRecord#prompt.text
            end
    end.

%%====================================================================

get_album_prompts() ->
    #{
        <<"album.1">> =>
            #prompt{
                id = <<"album.1">>,
                text = <<"mirror selfie!">>,
                reuse_after = 6 * ?MONTHS
            },
        <<"album.2">> =>
            #prompt{
                id = <<"album.2">>,
                text = <<"a nostalgic memory">>,
                reuse_after = 6 * ?MONTHS
            },
        <<"album.3">> =>
            #prompt{
                id = <<"album.3">>,
                text = <<" 🐶 🐱 🦎 🐥 🐿 ❓"/utf8>>,
                reuse_after = 6 * ?MONTHS
            },
        <<"album.4">> =>
            #prompt{
                id = <<"album.4">>,
                text = <<"spring break selfie 🌴"/utf8>>,
                reuse_after = 6 * ?MONTHS
            },
        <<"album.5">> =>
            #prompt{
                id = <<"album.5">>,
                text = <<"coachella or couch-ella? 🛋✨"/utf8>>,
                reuse_after = 6 * ?MONTHS
            },
        <<"album.6">> =>
            #prompt{
                id = <<"album.6">>,
                text = <<"work-out selfie 🏋🏾‍♀️🏋🏼‍♂️🏋🏿"/utf8>>,
                reuse_after = 6 * ?MONTHS
            },
        <<"album.7">> =>
            #prompt{
                id = <<"album.7">>,
                text = <<"Drop the spiciest screenshot you have on your phone? 👀 🌶"/utf8>>,
                reuse_after = 6 * ?MONTHS
            },
        <<"album.8">> =>
            #prompt{
                id = <<"album.8">>,
                text = <<"share a photo from your last vacation 🛬"/utf8>>,
                reuse_after = 6 * ?MONTHS
            },
        <<"album.9">> =>
            #prompt{
                id = <<"album.9">>,
                text = <<"pics or it didn't happen 😎"/utf8>>,
                reuse_after = 6 * ?MONTHS
            }
    }.

get_text_prompts() ->
    #{
        <<"text.1">> =>
            #prompt{
                id = <<"text.1">>,
                text = <<"What food are you craving right now?">>,
                reuse_after = 3 * ?MONTHS},
        <<"text.2">> =>
            #prompt{
                id = <<"text.2">>,
                text = <<"Describe your day in emojis">>,
                reuse_after = 3 * ?MONTHS},
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
                reuse_after = 6 * ?MONTHS,
                ai_image_model = ?STABLE_DIFFUSION_1_5,
                prompt_wrapper = fun(T) -> <<"close up photo of ", T/binary, ", the food">> end,
                negative_prompt = <<"drawing, cartoon">>
                },
        <<"text.7">> =>
            #prompt{
                id = <<"text.7">>,
                text = <<"Favorite thing to start your day with">>,
                reuse_after = 6 * ?MONTHS
            },
        <<"text.8">> =>
            #prompt{
                id = <<"text.8">>,
                text = <<"What's one superpower you definitely would not want?">>,
                reuse_after = 6 * ?MONTHS,
                ai_image_model = ?STABLE_DIFFUSION_1_5,
                prompt_wrapper = fun(T) -> <<T/binary, " superpower, in the style of roy lichtenstein, 8K, hyper-detailed and intricate, realistic shaded">> end,
                negative_prompt = <<"disfigured faces, bad eyes, extra fingers">>
            },
        <<"text.9">> =>
            #prompt{
                id = <<"text.9">>,
                text = <<"what pokemon would make a bad roommate?">>,
                reuse_after = 6 * ?MONTHS,
                ai_image_model = ?STABLE_DIFFUSION_1_5,
                prompt_wrapper = fun(T) -> <<T/binary, " pokemon, 8K">> end,
                negative_prompt = <<"disfigured faces, faces">>
            },
        <<"text.10">> =>
            #prompt{
                id = <<"text.10">>,
                text = <<"If you could ✨magically✨ learn any language, which one would you choose?"/utf8>>,
                reuse_after = 6 * ?MONTHS,
                ai_image_model = ?STABLE_DIFFUSION_1_5,
                prompt_wrapper = fun(T) -> <<T/binary, " dialect, landmark, 8k">> end,
                negative_prompt = <<"disfigured faces, text">>
            },
        <<"text.11">> =>
            #prompt{
                id = <<"text.11">>,
                text = <<"worst Tinder opener? 🤡"/utf8>>,
                reuse_after = 6 * ?MONTHS,
                ai_image_model = ?STABLE_DIFFUSION_1_5,
                prompt_wrapper = fun(T) -> <<T/binary, ", clown, smiling, friendly">> end,
                negative_prompt = <<"disfigured faces, text, scary">>
            },
        <<"text.12">> =>
            #prompt{
                id = <<"text.12">>,
                text = <<"24 hours to live, what's your final meal?⏱"/utf8>>,
                reuse_after = 6 * ?MONTHS,
                ai_image_model = ?STABLE_DIFFUSION_1_5,
                prompt_wrapper = fun(T) -> <<T/binary, ", food, meal">> end,
                negative_prompt = <<"disfigured faces, text, high saturation">>
            },
        <<"text.13">> =>
            #prompt{
                id = <<"text.13">>,
                text = <<"what are you listening to? 🎧"/utf8>>,
                reuse_after = 6 * ?MONTHS,
                ai_image_model = ?STABLE_DIFFUSION_1_5,
                prompt_wrapper = fun(T) -> <<T/binary, ", music, headphones, listening">> end,
                negative_prompt = <<"disfigured faces, text, high saturation">>
            },
        <<"text.14">> =>
            #prompt{
                id = <<"text.14">>,
                text = <<"which tv show character do you think would definitely have an onlyfans? 🫣"/utf8>>,
                reuse_after = 6 * ?MONTHS,
                ai_image_model = ?STABLE_DIFFUSION_1_5,
                prompt_wrapper = fun(T) -> <<T/binary, ", tv show, popcorn">> end,
                negative_prompt = <<"disfigured faces, text, high saturation">>
            },
        <<"text.15">> =>
            #prompt{
                id = <<"text.15">>,
                text = <<"you're out with friends and stumble into a karaoke bar, what's your song? 🎤👩🏾‍🎤"/utf8>>,
                reuse_after = 6 * ?MONTHS,
                ai_image_model = ?STABLE_DIFFUSION_1_5,
                prompt_wrapper = fun(T) -> <<T/binary, ", karaoke, bar, 8k, hyper detailed and intricate">> end,
                negative_prompt = <<"disfigured faces, text, high saturation">>
            },
        <<"text.16">> =>
            #prompt{
                id = <<"text.16">>,
                text = <<"latest netflix binge? 🍿"/utf8>>,
                reuse_after = 6 * ?MONTHS,
                ai_image_model = ?STABLE_DIFFUSION_1_5,
                prompt_wrapper = fun(T) -> <<T/binary, ", movie, popcorn, theatre">> end,
                negative_prompt = <<"disfigured faces, text, high saturation">>
            },
        <<"text.17">> =>
            #prompt{
                id = <<"text.17">>,
                text = <<"Spring's in full bloom, if you could plant any flower, which one would you choose? 🌷🌷"/utf8>>,
                reuse_after = 6 * ?MONTHS,
                ai_image_model = ?STABLE_DIFFUSION_1_5,
                prompt_wrapper = fun(T) -> <<T/binary, ", flowers, low saturation">> end,
                negative_prompt = <<"disfigured faces">>
            },
        <<"text.18">> =>
            #prompt{
                id = <<"text.18">>,
                text = <<"We don't gatekeep, share a ✨tip✨ that gets you through life on the daily"/utf8>>,
                reuse_after = 6 * ?MONTHS,
                ai_image_model = ?STABLE_DIFFUSION_1_5,
                prompt_wrapper = fun(T) -> <<T/binary, ", journal, tips, how to">> end,
                negative_prompt = <<"disfigured faces">>
            },
        <<"text.19">> =>
            #prompt{
                id = <<"text.19">>,
                text = <<"Free meals for life at 1 fast food chain, who's your pick?!? 🍟🌮🍔"/utf8>>,
                reuse_after = 6 * ?MONTHS,
                ai_image_model = ?STABLE_DIFFUSION_1_5,
                prompt_wrapper = fun(T) -> <<T/binary, ", food, delicious ">> end,
                negative_prompt = <<"text, disfigured faces, low saturation, people">>
            },
        <<"text.20">> =>
            #prompt{
                id = <<"text.20">>,
                text = <<"if you were paid for your ✨bad habits✨, which one would make you a millionaire?"/utf8>>,
                reuse_after = 6 * ?MONTHS,
                ai_image_model = ?STABLE_DIFFUSION_1_5,
                prompt_wrapper = fun(T) -> <<T/binary, ", money">> end,
                negative_prompt = <<"text, disfigured faces">>
            },
        <<"text.21">> =>
            #prompt{
                id = <<"text.21">>,
                text = <<"what are some 🚩🚩🚩 on a first date?"/utf8>>,
                reuse_after = 6 * ?MONTHS,
                ai_image_model = ?STABLE_DIFFUSION_1_5,
                prompt_wrapper = fun(T) -> <<T/binary, ", picture of a red flag, vibrant"/utf8>> end,
                negative_prompt = <<"text, disfigured faces, low saturation, people">>
            }
    }.


get_camera_prompts() ->
    #{
        <<"camera.1">> =>
            #prompt{
                id = <<"media.1">>,
                text = <<"">>,
                reuse_after = 0
            },
        <<"camera.2">> =>
            #prompt{
                id = <<"media.2">>,
                text = <<"Show us your best 😡 face"/utf8>>,
                reuse_after = 6 * ?MONTHS
            },
        <<"camera.3">> =>
            #prompt{
                id = <<"media.3">>,
                text = <<"ootd 👗👕👟🧢"/utf8>>,
                reuse_after = 6 * ?MONTHS
            }
    }.

