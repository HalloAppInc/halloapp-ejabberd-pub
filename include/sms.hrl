%%%-------------------------------------------------------------------
%%% @author nikola
%%% @copyright (C) 2020, HalloApp, Inc.
%%% @doc
%%%
%%% @end
%%% Created : 31. Mar 2020 3:00 PM
%%%-------------------------------------------------------------------
% -author("nikola").

-ifndef(SMS_HRL).
-define(SMS_HRL, true).

-include("time.hrl").
-include("ha_types.hrl").

-define(ANDROID_DEBUG_HASH, <<"/TwOjtaTNFA">>).
-define(ANDROID_RELEASE_HASH, <<"05IyxZs5b3I">>).
-define(KATCHUP_ANDROID_RELEASE_HASH, <<"dsBIR3o/cGT">>).

-define(TWILIO, <<"twilio">>).

-type status() :: accepted | queued | sending | sent | delivered | undelivered | failed | canceled | unknown.

-record(gateway_response, {
    gateway :: maybe(atom()),
    method :: maybe(sms | voice_call),
    gateway_id :: maybe(binary()),
    status :: maybe(status()),
    response :: maybe(binary()),
    price :: maybe(float()),
    currency :: maybe(binary()),
    verified  :: maybe(boolean()),
    attempt_id :: maybe(binary()),
    attempt_ts :: maybe(non_neg_integer()),
    lang_id :: maybe(binary()),
    valid :: maybe(boolean())
}).

-type gateway_response()  :: #gateway_response{}.

-record(verification_info,
{
    attempt_id :: binary(),
    gateway :: binary(),
    code :: binary(),
    sid :: binary(),
    ts :: non_neg_integer(),
    status :: binary(),
    valid :: boolean()
}).

-type verification_info() :: #verification_info{}.

% number of sms requests in a single increment without conversion from a country to alert as possible spam
-define(SPAM_THRESHOLD_PER_INCREMENT, 30).


%% for testing purposes
-ifdef(TEST).
-define(SMS_REG_TIMESTAMP_INCREMENT, 1 * ?SECONDS).
-define(MIN_SCORING_TIME, 2 * ?SECONDS). 
-define(MAX_SCORING_TIME, 3 * ?SECONDS). 
-define(MIN_TEXTS_TO_SCORE_GW, 5).
-else.
-define(SMS_REG_TIMESTAMP_INCREMENT, 900 * ?SECONDS).  %% 15 minutes.
-define(MIN_SCORING_TIME, 2 * ?HOURS). %% 2 hours
-define(MAX_SCORING_TIME, 7 * ?DAYS). %% 7 days
-define(MIN_TEXTS_TO_SCORE_GW, 10).
-endif.
-define(SCORE_DATA_TABLE, sms_gw_score_data).
-define(MIN_SCORING_INTERVAL_COUNT, (?MIN_SCORING_TIME div ?SMS_REG_TIMESTAMP_INCREMENT)). 
-define(MAX_SCORING_INTERVAL_COUNT, (?MAX_SCORING_TIME div ?SMS_REG_TIMESTAMP_INCREMENT)). %% 7 days
-define(ERROR_POS, 2).
-define(TOTAL_POS, 3).
-define(TOTAL_SEEN_POS, 4).
-define(IS_RELEVANT_POS, 5).
-define(RECENT_SCORE_WEIGHT, 0.8).

-define(MIN_SMS_CONVERSION_SCORE, 20).

-define(PROBABILITY_USE_MAX, 0.9).
-define(PROBABILITY_SAMPLE_RANDOMLY, 0.1).


-define(ENG_LANG_ID, <<"en-US">>).

%% Score is between 0, 1. Multiply by 100 to get percent score.
-define(DEFAULT_GATEWAY_SCORE, 0.1).
-define(DEFAULT_GATEWAY_SCORE_PERCENT, ?DEFAULT_GATEWAY_SCORE * 100).

-define(HALLOAPP_SENDER_ID, "HalloApp").
-define(KATCHUP_SENDER_ID, "Katchup").

-endif.
