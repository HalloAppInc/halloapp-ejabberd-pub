%%%-------------------------------------------------------------------
%%% @copyright (C) 2021, HalloApp, Inc.
%%% @doc
%%%
%%% @end
%%%-------------------------------------------------------------------
-author("luke").

-ifndef(SMS_APP_HRL).
-define(SMS_APP_HRL, true).

-include("time.hrl").

-define(SMS_APP_PHONE_LIST, [<<"16503915827">>]).
-define(SMS_APP_OPTIONS, sms_app_options).

-define(SMS_APP_REQUEST_TIMEOUT, 5 * ?SECONDS).

-endif.
