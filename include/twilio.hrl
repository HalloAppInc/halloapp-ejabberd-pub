%%%-------------------------------------------------------------------
%%% @copyright (C) 2020, HalloApp, Inc.
%%% @doc
%%%
%%% @end
%%%-------------------------------------------------------------------
-author("vipin").

-ifndef(TWILIO_HRL).
-define(TWILIO_HRL, true).

-define(ACCOUNT_SID, "AC50b98f4898fbcc27bfa31980ffd0799a").

-define(BASE_URL, "https://api.twilio.com/2010-04-01/Accounts/" ++ ?ACCOUNT_SID ++ "/Messages.json").
-define(FROM_PHONE, "+14152339113").

-define(TWILIOCALLBACK_URL, "https://api.halloapp.net/api/smscallback/twilio").

-define(SMS_INFO_URL, "https://api.twilio.com/2010-04-01/Accounts/" ++ ?ACCOUNT_SID ++ "/Messages/").

-endif.
