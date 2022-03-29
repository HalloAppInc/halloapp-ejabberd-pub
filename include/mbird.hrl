%%%-------------------------------------------------------------------
%%% @copyright (C) 2020, HalloApp, Inc.
%%% @doc
%%%
%%% @end
%%%-------------------------------------------------------------------
-author("vipin").

-ifndef(MBIRD_HRL).
-define(MBIRD_HRL, true).

-define(BASE_SMS_URL, "https://rest.messagebird.com/messages").
-define(BASE_VOICE_URL, "https://voice.messagebird.com/calls").
-define(FROM_PHONE_FOR_CANADA, "+12262403383").
-define(FROM_PHONE_FOR_US, "+12022213975").
-define(REFERENCE, "HALLOAPP").

-define(NO_RECIPIENTS_CODE, 9). % No (correct) recipients found
-define(BLACKLIST_NUM_CODE, 12). % Number is blacklisted

-define(STICKY_VMN, "inbox").

-endif.
