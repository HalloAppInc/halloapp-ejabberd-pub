%%%-------------------------------------------------------------------
%%% @author josh
%%% @copyright (C) 2023, HalloApp, Inc.
%%% @doc
%%%
%%% @end
%%%-------------------------------------------------------------------
-author("josh").

-ifndef(PROMPTS).
-define(PROMPTS, 1).

-include("time.hrl").

%% Models
-define(STABLE_DIFFUSION_1_5, "runwayml/stable-diffusion-v1-5").

-record(prompt, {
    id,
    text,
    image_id = <<>>,
    reuse_after = 6 * ?MONTHS,
    ai_image_model = ?STABLE_DIFFUSION_1_5,
    prompt_wrapper = fun(T) -> T end,
    negative_prompt = <<>>
}).

-type prompt_record() :: #prompt{}.

-endif.

