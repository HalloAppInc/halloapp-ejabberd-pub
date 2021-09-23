%%%-------------------------------------------------------------------
%%% @copyright (C) 2021, HalloApp, Inc.
%%% @doc
%%%
%%% @end
%%%-------------------------------------------------------------------
-author("michelle").

-ifndef(MBIRD_VERIFY_HRL).
-define(MBIRD_VERIFY_HRL, true).

-define(BASE_URL, "https://rest.messagebird.com/verify").
-define(VERIFY_URL(Sid, Code), "https://rest.messagebird.com/verify/" ++ binary_to_list(Sid) ++ "?token=" ++ binary_to_list(Code)).

-define(INVALID_RECIPIENTS_CODE, 10). % Invalid recipient

-endif.

