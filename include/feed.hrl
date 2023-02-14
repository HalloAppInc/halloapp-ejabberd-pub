%%%----------------------------------------------------------------------
%%% Records for mod_feed related nodes and items.
%%%
%%%----------------------------------------------------------------------

-ifndef(FEED_HRL).
-define(FEED_HRL, 1).


-include("ha_types.hrl").
-include("time.hrl").
-include("server.hrl").

-type node_type() :: feed | metadata.
-type item_type() :: feedpost | comment | other.
-type event_type() :: publish | retract | share.
-type post_tag() :: empty | moment | public_post | public_moment.
-type comment_type() :: comment | post_reaction | comment_reaction.

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
    psa_tag :: maybe(binary()),
    moment_info :: maybe(pb_moment_info()),
    expired = false :: boolean()
}).

-type post() :: #post{}.


-record(comment, {
    id :: binary(),
    post_id :: binary(),
    publisher_uid :: uid(),
    parent_id :: binary(),
    comment_type :: comment_type(),
    payload :: binary(),
    ts_ms :: integer()
}).

-type comment() :: #comment{}.

-type feed_item() :: post() | comment().
-type feed_items() :: [feed_item()].

-type action_type() :: publish | retract.
-type set() :: sets:set().

-define(POST_EXPIRATION, (31 * ?DAYS)).
-define(KATCHUP_MOMENT_EXPIRATION, (2 * ?DAYS)).
-define(KATCHUP_MOMENT_EXPIRATION_HRS, 48).
-define(KATCHUP_MOMENT_INDEX_EXPIRATION, (4 * ?DAYS)).
-define(POST_TTL_MS, (31 * ?DAYS_MS)).
-define(MOMENT_TAG_EXPIRATION, (7 * ?DAYS)).
-define(GEO_TAG_EXPIRATION, (4 * ?WEEKS)).
-define(NUM_PUBLIC_FEED_ITEMS_PER_REQUEST, 20).
-define(MAX_DAILY_MOMENT_LIMIT, 2).
-define(KATCHUP_PUBLIC_FEED_REFRESH_SECS, 30 * ?MINUTES).
-define(KATCHUP_PUBLIC_FEED_REFRESH_MSECS, 30 * ?MINUTES_MS).

-endif.
