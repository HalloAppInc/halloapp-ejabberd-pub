%%%-------------------------------------------------------------------
%%% @author nikola
%%% @copyright (C) 2020, HalloApp, Inc.
%%% @doc
%%%
%%% @end
%%% Created : 31. Mar 2020 3:00 PM
%%%-------------------------------------------------------------------
-author("nikola").

-ifndef(SMS_HRL).
-define(SMS_HRL, true).

-define(ANDROID_DEBUG_HASH, <<"/TwOjtaTNFA">>).
-define(ANDROID_RELEASE_HASH, <<"05IyxZs5b3I">>).

-define(TWILIO, <<"twilio">>).

-type status() :: accepted | queued | sending | sent | delivered | undelivered | failed | unknown.

-record(gateway_response, {
    gateway :: atom(),
    method :: sms | voice_call,
    gateway_id :: binary(),
    status :: status(),
    response :: binary(),
    price :: float(),
    currency :: binary(),
    verified  :: boolean(),
    attempt_id :: binary(),
    attempt_ts :: non_neg_integer()
}).

-type gateway_response()  :: #gateway_response{}.

-define(SMS_REG_TIMESTAMP_INCREMENT, 900).  %% 15 minutes.

-endif.
