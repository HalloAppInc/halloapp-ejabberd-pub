%%%----------------------------------------------------------------------------
%%% Records for message_items used in modules related to push notifications.
%%%
%%%----------------------------------------------------------------------------

-ifndef(PUSH_MESSAGE_HRL).
-define(PUSH_MESSAGE_HRL, 1).


-include("account.hrl").
-include("packets.hrl").

-record(push_message_item, {
    id :: binary(),
    uid :: binary(),
    message :: pb_msg(),
    timestamp :: integer(),
    retry_ms :: integer(),
    push_info :: push_info(),
    push_type = silent :: alert | silent
}).

-type push_message_item() :: #push_message_item{}.

%% TODO(murali@): Store this pending/retry list info in ets tables/redis and keep the state simple.
-record(push_state, {
    pendingMap :: #{},
    host :: binary(),
    conn :: pid(),
    mon :: reference(),
    dev_conn :: pid(),
    dev_mon :: reference(),
    voip_conn :: pid(),
    voip_mon :: reference(),
    noise_static_key :: binary(),
    noise_certificate :: binary()
}).

-type push_state() :: #push_state{}.


-define(GOLDEN_RATIO, 1.618).

-define(FCM, "fcm").
-define(APNS, "apns").


%% TODO(murali@): this list seems getting bigger, we should just send the whole packet as a protobuf binary.
%% Client must decrypt the packet, decode it and do everything with it.
-record(push_metadata,
{
    content_id = <<>> :: binary(),          %% content-id
    content_type = <<>> :: binary(),        %% content-type: could be chat, group_chat, group_post, group_comment, feed_post, feed_comment, contact_list.
    from_uid = <<>> :: binary(),            %% uid of the sender.
    timestamp = <<>> :: binary(),           %% timestamp of the content.
    thread_id = <<>> :: binary(),           %% Maps to uid for chat, gid for groupchat, feed for feed.
    thread_name = <<>> :: binary(),         %% Maps to group_name for groupchat, else irrelevant
    sender_name = <<>> :: binary(),         %% includes push_name of from_uid.
    subject = <<>> :: binary(),             %% includes the fallback subject line
    body = <<>> :: binary(),                %% includes the fallback body line
    push_type = silent :: alert | silent,   %% indicates the push type.
    payload = <<>> :: binary(),             %% payload of the content to be sent to the client.
    retract = false :: boolean()            %% indicates whether push is about retracting content.
}).

-type push_metadata() :: #push_metadata{}.

-endif.
