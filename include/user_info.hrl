%%%----------------------------------------------------------------------
%%% Records for user_contacts and user_ids.
%%%
%%%----------------------------------------------------------------------

%% Temporarily handle both old and new record types for backwards compatibility.
-record(user_contacts_new, {username :: {binary(), binary()},
                        contact :: {binary(), binary()},
                        syncid :: binary()}).

-record(user_syncids, {username :: {binary(), binary()},
                       syncid :: binary()}).

-record(user_ids, {username = {<<"">>, <<"">>} :: {binary(), binary()},
                    id = <<"">> :: binary()}).

-record(user_phone, {uid :: binary(), phone :: binary()}).

%% Using a large value to indicate the number of items that can be stored in a node.
%% max-value of 32-bit integer
-define(MAX_ITEMS, 2147483647).

%% Number of seconds in 30days.
-define(EXPIRE_ITEM_SEC, 2592000).

%% Using an atom here to indicate that it never expires.
-define(UNEXPIRED_ITEM_SEC, infinity).