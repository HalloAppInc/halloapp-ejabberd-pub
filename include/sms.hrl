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

-include("time.hrl").

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


%% for testing purposes
-ifdef(TEST).
-define(SMS_REG_TIMESTAMP_INCREMENT, 1 * ?SECONDS).
-define(MIN_SCORING_TIME, 2 * ?SECONDS). 
-define(MAX_SCORING_TIME, 3 * ?SECONDS). 
-define(MIN_TEXTS_TO_SCORE_GW, 5).
-else.
-define(SMS_REG_TIMESTAMP_INCREMENT, 900 * ?SECONDS).  %% 15 minutes.
-define(MIN_SCORING_TIME, 2 * ?HOURS). %% 2 hours
-define(MAX_SCORING_TIME, 2 * ?DAYS). %% 48 hours
-define(MIN_TEXTS_TO_SCORE_GW, 10).
-endif.
-define(GW_SCORE_TABLE, sms_gw_scores).
-define(MIN_SCORING_INTERVAL_COUNT, (?MIN_SCORING_TIME div ?SMS_REG_TIMESTAMP_INCREMENT)). 
-define(MAX_SCORING_INTERVAL_COUNT, (?MAX_SCORING_TIME div ?SMS_REG_TIMESTAMP_INCREMENT)). %% 48 hours 



-define(ENG_LANG_ID, <<"en-US">>).

-define(DEFAULT_GATEWAY_SCORE, 0.1).

-endif.
