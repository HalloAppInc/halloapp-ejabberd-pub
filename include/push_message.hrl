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
    push_type = silent :: alert | silent,
    content_type = <<>> :: binary(),
    apns_id :: binary()
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
    voip_dev_conn :: pid(),
    voip_dev_mon :: reference(),
    noise_static_key :: binary(),
    noise_certificate :: binary()
}).

-type push_state() :: #push_state{}.


-define(GOLDEN_RATIO, 1.618).

-define(FCM, "fcm").
-define(APNS, "apns").

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

-endif.
