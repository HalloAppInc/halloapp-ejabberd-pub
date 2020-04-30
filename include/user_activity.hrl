%%%----------------------------------------------------------------------
%%% Records for last actvity of the user.
%%%
%%%----------------------------------------------------------------------

-type(activity_status() :: available | away).

-record(user_activity, {username = {<<"">>, <<"">>} :: {binary(), binary()},
                        last_seen = <<"">> :: binary(),
                        status :: activity_status() | undefined}).

-type user_activity() :: #user_activity{}.

