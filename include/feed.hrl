%%%----------------------------------------------------------------------
%%% Records for mod_feed related nodes and items.
%%%
%%%----------------------------------------------------------------------

-type node_type() :: feed | metadata.
-type item_type() :: feedpost | comment | other.
-type event_type() :: publish | retract.

-record(psnode, {
    id :: binary(),                     %% node_id
    uid :: binary(),                    %% owner_uid
    type :: node_type(),                %% node_type
    c_ts_ms :: integer()                %% creation_ts_ms
}).

-type psnode() :: #psnode{}.

-record(item, {
    key :: {binary(), binary()},        %% item_id, node_id
    type :: item_type(),                %% item_type
    uid :: binary(),                    %% publisher_uid
    c_ts_ms :: integer(),               %% creation_ts_ms
    payload :: any()                    %% payload
}).

-type item() :: #item{}.

-define(HOUR, 3600).
-define(HOUR_MS, 3600000).
-define(DAY, 24 * ?HOUR).
-define(DAY_MS, 24 * ?HOUR_MS).

