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
    to_uid :: binary(),
    from_uid :: binary(),
    content_type :: binary(),
    retry_count :: integer(),
    message :: binary()
}).

-type offline_message() :: #offline_message{}.
