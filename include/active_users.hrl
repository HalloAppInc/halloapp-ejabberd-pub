-include("ha_types.hrl").

-ifndef(ACTIVE_USERS_HRL).
-define(ACTIVE_USERS_HRL, 1).

-type activity_type() :: all | client_type() | post | {cc, binary()}.

-endif.
