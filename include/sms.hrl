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
    attempt_ts :: non_neg_integer(),
    lang_id :: binary()
}).

-type gateway_response()  :: #gateway_response{}.

-record(verification_info,
{
    attempt_id :: binary(),
    gateway :: atom(),
    code :: binary(),
    sid :: binary(),
    ts :: non_neg_integer(),
    status :: status()
}).

-type verification_info() :: #verification_info{}.

-define(SMS_REG_TIMESTAMP_INCREMENT, 900).  %% 15 minutes.

-define(ENG_LANG_ID, <<"en-US">>).

-define(DEFAULT_GATEWAY_SCORE, 0.1).

-endif.
