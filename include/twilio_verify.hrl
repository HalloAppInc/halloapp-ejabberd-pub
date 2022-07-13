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

-define(INVALID_TO_PHONE_CODE1, 21211). % 'To' not a valid phone number
-define(INVALID_TO_PHONE_CODE2, 21614). % Another invalid phone # code - possibly this is a landline/etc
-define(NOT_ALLOWED_CALL_CODE, 21216). % Account not allowed to call
-define(RECIPIENT_UNSUBSCRIBED_CODE, 21610). % Recipient had replied STOP / opted out
-define(OK_ERROR_CODES, [?INVALID_TO_PHONE_CODE1, ?INVALID_TO_PHONE_CODE2, 
                         ?NOT_ALLOWED_CALL_CODE, ?RECIPIENT_UNSUBSCRIBED_CODE]).

-endif.

