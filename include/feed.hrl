%%%----------------------------------------------------------------------
%%% Records for mod_feed related nodes and items.
%%%
%%%----------------------------------------------------------------------

-ifndef(FEED_HRL).
-define(FEED_HRL, 1).


-include("ha_types.hrl").
-include("time.hrl").

-type node_type() :: feed | metadata.
-type item_type() :: feedpost | comment | other.
-type event_type() :: publish | retract | share.
-type post_tag() :: empty | moment.

-record(psnode, {
    id :: binary(),                             %% node_id
    uid :: binary(),                            %% owner_uid
    type :: node_type(),                        %% node_type
    creation_ts_ms :: integer()                 %% creation_ts_ms
}).

-type psnode() :: #psnode{}.

-record(item, {
    key :: {binary(), binary()},                %% item_id, node_id
    type :: item_type(),                        %% item_type
    uid :: binary(),                            %% publisher_uid
    creation_ts_ms :: integer(),                %% creation_ts_ms
    payload :: any()                            %% payload
}).

-type item() :: #item{}.

-record(post, {
    id :: binary(),
    uid :: uid(),
    payload :: binary(),
    tag :: post_tag(),
    audience_type :: atom(),
    audience_list :: [uid()],
    ts_ms :: integer(),
    gid :: maybe(binary()),
    psa_tag :: maybe(binary())
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

-type action_type() :: publish | retract.
-type set() :: sets:set().

-define(POST_EXPIRATION, (31 * ?DAYS)).
-define(POST_TTL_MS, (31 * ?DAYS_MS)).
-define(CATCH_UP_TIME_MS, 1 * ?WEEKS_MS).
-define(MOMENT_TAG_EXPIRATION, (3 * ?DAYS)).


-endif.
