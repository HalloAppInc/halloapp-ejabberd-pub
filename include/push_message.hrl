%%%----------------------------------------------------------------------------
%%% Records for message_items used in modules related to push notifications.
%%%
%%%----------------------------------------------------------------------------

-include("account.hrl").

-record(push_message_item, {
	id :: binary(),
	uid :: binary(),
	message :: message(),
	timestamp :: integer(),
	retry_ms :: integer(),
	push_info :: push_info()
}).

-type push_message_item() :: #push_message_item{}.

%% TODO(murali@): Store this pending/retry list info in ets tables/redis and keep the state simple.
-record(push_state, {
	pendingMap :: #{},
	host :: binary(),
	conn :: pid(),
	mon :: reference(),
	dev_conn :: pid(),
	dev_mon :: reference()
}).

-type push_state() :: #push_state{}.


-define(GOLDEN_RATIO, 1.618).

-define(FCM, "HA/fcm").
-define(APNS, "HA/apns").


%% TODO(murali@): this list seems getting bigger, we should just send the whole packet as a protobuf binary.
%% Client must decrypt the packet, decode it and do everything with it.
-record(push_metadata,
{
    content_id :: binary(),			%% content-id
    content_type :: binary(),		%% content-type: could be chat, group_chat, group_post, group_comment, feed_post, feed_comment, contact_list.
    from_uid :: binary(),			%% uid of the sender.
    timestamp :: binary(),			%% timestamp of the content.
    thread_id :: binary(),			%% Maps to uid for chat, gid for groupchat, feed for feed.
    thread_name :: binary()			%% Maps to group_name for groupchat, else irrelevant
}).

-type push_metadata() :: #push_metadata{}.

