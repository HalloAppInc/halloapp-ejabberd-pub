%%%-------------------------------------------------------------------
%%% @copyright (C) 2020, HalloApp, Inc.
%%% @doc
%%%
%%% @end
%%%-------------------------------------------------------------------
-author("vipin").

-ifndef(TWILIO_HRL).
-define(TWILIO_HRL, true).

-define(TEST_ACCOUNT_SID, "ACe9c5dfe8bc211f52e4e235aadfa2df1b").
-define(PROD_ACCOUNT_SID, "AC50b98f4898fbcc27bfa31980ffd0799a").

-define(BASE_SMS_URL(AccountSid),
    "https://api.twilio.com/2010-04-01/Accounts/" ++ AccountSid ++ "/Messages.json").
-define(BASE_VOICE_URL(AccountSid),
    "https://api.twilio.com/2010-04-01/Accounts/" ++ AccountSid ++ "/Calls.json").

-define(FROM_PHONE, "+14152339113").
-define(FROM_TEST_PHONE, "+15005550006").

-define(TWILIOCALLBACK_URL, "https://api.halloapp.net/api/smscallback/twilio").

%% Not tested currently, so can always assume prod account sid
-define(SMS_INFO_URL,
    "https://api.twilio.com/2010-04-01/Accounts/" ++ ?PROD_ACCOUNT_SID ++ "/Messages/").

-endif.
