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

