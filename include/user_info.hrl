%%%----------------------------------------------------------------------
%%% Records for user_contacts and user_ids.
%%%
%%%----------------------------------------------------------------------

-record(user_contacts, {username :: {binary(), binary()},
                        contact :: {binary(), binary()},
                        syncid :: binary()}).

-record(user_syncids, {username :: {binary(), binary()},
                       syncid :: binary()}).

-record(user_ids, {username = {<<"">>, <<"">>} :: {binary(), binary()},
                    id = <<"">> :: binary()}).

%% Using a large value to indicate the number of items that can be stored in a node.
%% max-value of 32-bit integer
-define(MAX_ITEMS, 2147483647).