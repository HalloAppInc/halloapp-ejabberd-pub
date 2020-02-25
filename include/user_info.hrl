%%%----------------------------------------------------------------------
%%% Records for user_contacts and user_ids.
%%%
%%%----------------------------------------------------------------------

-record(user_contacts, {username :: {binary(), binary()},
                        contact :: {binary(), binary()}}).

-record(user_ids, {username = {<<"">>, <<"">>} :: {binary(), binary()},
                    id = <<"">> :: binary()}).