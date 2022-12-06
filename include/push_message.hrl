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
    message :: message() | binary(),
    timestamp_ms :: integer(),
    retry_ms :: integer(),
    push_info :: push_info(),
    push_type = silent :: alert | silent,
    content_type = undefined :: atom(),
    apns_id :: maybe(binary())
}).

-type push_message_item() :: #push_message_item{}.

%% TODO(murali@): Store this pending/retry list info in ets tables/redis and keep the state simple.
-record(worker_push_state, {
    host :: binary(),
    conn :: maybe(pid()),
    mon :: reference(),
    dev_conn :: maybe(pid()),
    dev_mon :: reference(),
    voip_conn :: maybe(pid()),
    voip_mon :: reference(),
    voip_dev_conn :: maybe(pid()),
    voip_dev_mon :: reference(),
    katchup_conn :: maybe(pid()),
    katchup_mon :: reference(),
    katchup_dev_conn :: maybe(pid()),
    katchup_dev_mon :: reference(),
    noise_static_key :: binary(),
    noise_certificate :: binary(),
    pending_map :: #{}
}).

-type worker_push_state() :: #worker_push_state{}.

-record(push_state, {
    host :: binary(),
    push_times_ms = [] :: list()
}).

-type push_state() :: #push_state{}.


-define(GOLDEN_RATIO, 1.618).

-define(FCM, "fcm").
-define(APNS, "apns").
-define(HUAWEI, "huawei").

-type (contentType() :: pb_chat_stanza
                    | pb_chat_retract
                    | pb_group_chat
                    | pb_group_chat_retract
                    | pb_contact_hash
                    | contact_notice
                    | inviter_notice
                    | contact_notification
                    | feedpost
                    | feedpost_retract
                    | comment
                    | comment_retract
                    | group_post
                    | group_post_retract
                    | group_comment
                    | group_comment_retract
                    | pb_group_stanza
                    | pb_rerequest
                    | pb_group_feed_rerequest
                    | pb_home_feed_rerequest
                    | pb_group_feed_items
                    | pb_feed_items
                    | pb_request_logs
                    | pb_wake_up
                    | pb_incoming_call
                    | pb_call_ringing
                    | pb_pre_answer_call
                    | pb_answer_call
                    | pb_end_call
                    | pb_ice_candidate
                    | pb_marketing_alert
).


-type (alertType() :: alert
                    | silent
                    | direct_alert
).


%% TODO(murali@): this list seems getting bigger, we should just send the whole packet as a protobuf binary.
%% Client must decrypt the packet, decode it and do everything with it.
-record(push_metadata,
{
    content_id = <<>> :: binary(),          %% content-id
    content_type = undefined :: contentType(),          %% content-type: see list above
    push_type = alert :: alertType()        %% indicates the push type.
}).

-type push_metadata() :: #push_metadata{}.

-define(NUM_IOS_POOL_WORKERS, 10).
-define(NUM_ANDROID_POOL_WORKERS, 20).
-define(IOS_POOL, ios_pool).
-define(ANDROID_POOL, android_pool).

-endif.
