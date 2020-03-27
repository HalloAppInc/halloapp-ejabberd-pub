%%%----------------------------------------------------------------------
%%% Records for last actvity of the user.
%%%
%%%----------------------------------------------------------------------

-type(statusType() :: available | away).

-record(user_activity, {username = {<<"">>, <<"">>} :: {binary(), binary()},
                        last_seen = <<"">> :: binary(),
                        status = away :: statusType()}).