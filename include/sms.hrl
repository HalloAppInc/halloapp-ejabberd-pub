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

-record(sms_response, {
    gateway :: atom(),
    sms_id :: binary(),
    status :: binary(),
    response :: binary(),
    price :: float(),
    currency :: binary()
}).

-type sms_response()  :: #sms_response{}.

-endif.
