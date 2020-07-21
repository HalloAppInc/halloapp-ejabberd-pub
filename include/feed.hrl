%%%----------------------------------------------------------------------
%%% Records for mod_feed related nodes and items.
%%%
%%%----------------------------------------------------------------------

-include("ha_types.hrl").
-include("time.hrl").

-type node_type() :: feed | metadata.
-type item_type() :: feedpost | comment | other.
-type event_type() :: publish | retract.

-record(psnode, {
    id :: binary(),                     		%% node_id
    uid :: binary(),                    		%% owner_uid
    type :: node_type(),                		%% node_type
    creation_ts_ms :: integer()                	%% creation_ts_ms
}).

-type psnode() :: #psnode{}.

-record(item, {
    key :: {binary(), binary()},        		%% item_id, node_id
    type :: item_type(),                		%% item_type
    uid :: binary(),                    		%% publisher_uid
    creation_ts_ms :: integer(),               	%% creation_ts_ms
    payload :: any()                    		%% payload
}).

-type item() :: #item{}.

-record(post, {
	id :: binary(),
	uid :: uid(),
	payload :: binary(),
	ts_ms :: integer()
}).

-type post() :: #post{}.


-record(comment, {
	id :: binary(),
	post_id :: binary(),
	publisher_uid :: uid(),
	parent_id :: binary(),
	payload :: binary(),
	ts_ms :: integer()
}).

-type comment() :: #comment{}.

-type feed_item() :: post() | comment().
-type feed_items() :: [feed_item()].

-define(POST_EXPIRATION, (30 * ?DAYS)).
-define(POST_TTL_MS, (30 * ?DAYS_MS)).

