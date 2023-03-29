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

-record(prompt, {id, text, image_id = <<>>, reuse_after = 6 * ?MONTHS}).

-type prompt_record() :: #prompt{}.

-endif.

