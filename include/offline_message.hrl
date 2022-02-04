%%%--------------------------------------------------------------------------
%%% Record to hold details about the message stored in the redis offline store
%%%
%%% copyright (C) 2020 halloapp inc.
%%%
%%%--------------------------------------------------------------------------

%% TODO(murali@): update content_type to be atom later.
-author('murali').

-ifndef(OFFLINE_MESSAGES_HRL).
-define(OFFLINE_MESSAGES_HRL, 1).

-include("time.hrl").

-record(offline_message,
{
    msg_id :: binary(),
    order_id :: integer(),
    to_uid :: binary(),
    from_uid :: binary(),
    content_type :: binary(),
    retry_count :: integer(),
    message :: binary(),
    thread_id :: binary(),
    protobuf = false :: boolean(),
    sent :: boolean()
}).

-type offline_message() :: #offline_message{}.

-define(MSG_EXPIRATION, (30 * ?DAYS)).
-define(MAX_OFFLINE_MESSAGES, 10000).
-define(MAX_OFFLINE_MESSAGES_TEST, 100).

-endif.
