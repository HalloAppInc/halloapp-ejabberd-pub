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
-define(MESSAGE_SERVICE_SID, "MG19c741731dbb39c649fa376b224e0324").
-define(KATCHUP_MESSAGE_SERVICE_SID, "MG192442db5c86e3ca7e5880711a19a612").

-define(BASE_SMS_URL(AccountSid),
    "https://api.twilio.com/2010-04-01/Accounts/" ++ AccountSid ++ "/Messages.json").
-define(BASE_VOICE_URL(AccountSid),
    "https://api.twilio.com/2010-04-01/Accounts/" ++ AccountSid ++ "/Calls.json").

-define(FROM_PHONE, "+14152339113").
-define(KATCHUP_FROM_PHONE, "+14153636140").
-define(FROM_TEST_PHONE, "+15005550006").

-define(TWILIOCALLBACK_URL, "https://api.halloapp.net/api/smscallback/twilio").

%% Not tested currently, so can always assume prod account sid
-define(SMS_INFO_URL,
    "https://api.twilio.com/2010-04-01/Accounts/" ++ ?PROD_ACCOUNT_SID ++ "/Messages/").

-define(INVALID_TO_PHONE_CODE, 21211). % 'To' number not a valid phone number
-define(NOT_ALLOWED_CALL_CODE, 21216). % Account not allowed to call

-endif.
