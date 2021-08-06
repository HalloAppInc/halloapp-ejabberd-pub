%%%-------------------------------------------------------------------
%%% @copyright (C) 2021, HalloApp, Inc.
%%% @doc
%%%
%%% @end
%%%-------------------------------------------------------------------
-author("michelle").

-ifndef(TWILIO_VERIFY_HRL).
-define(TWILIO_VERIFY_HRL, true).

-define(SERVICE_SID, "VAb1725ac577bd6e4ec7ec6f4a09581934").

-define(VERIFICATION_URL, "https://verify.twilio.com/v2/Services/" ++ ?SERVICE_SID ++ "/Verifications/").

-define(INVALID_TO_PHONE_CODE, 21211). % 'To' number not a valid phone number
-define(NOT_ALLOWED_CALL_CODE, 21216). % Account not allowed to call

-endif.

