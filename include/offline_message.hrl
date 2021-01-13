%%%--------------------------------------------------------------------------
%%% Record to hold details about the message stored in the redis offline store
%%%
%%% copyright (C) 2020 halloapp inc.
%%%
%%%--------------------------------------------------------------------------

%% TODO(murali@): update content_type to be atom later.
-author('murali').

-record(offline_message,
{
    msg_id :: binary(),
    order_id :: integer(),
    to_uid :: binary(),
    from_uid :: binary(),
    content_type :: binary(),
    retry_count :: integer(),
    message :: binary(),
    protobuf = false :: boolean()
}).

-type offline_message() :: #offline_message{}.

-define(MSG_EXPIRATION, (30 * ?DAYS)).

