%% -*- coding: utf-8 -*-
%% Automatically generated, do not edit
%% Generated by gpb_compile version 4.13.0

-ifndef(packets).
-define(packets, true).

-define(packets_gpb_version, "4.13.0").

-ifndef('PB_CHAT_PB_H').
-define('PB_CHAT_PB_H', true).
-record(pb_chat,
        {timestamp = 0          :: integer() | undefined, % = 1, 64 bits
         payload = <<>>         :: iodata() | undefined % = 2
        }).
-endif.

-ifndef('PB_PING_PB_H').
-define('PB_PING_PB_H', true).
-record(pb_ping,
        {
        }).
-endif.

-ifndef('PB_IQ_PAYLOAD_PB_H').
-define('PB_IQ_PAYLOAD_PB_H', true).
-record(pb_iq_payload,
        {content                :: {upload_media, packets:pb_upload_media()} | {contact_list, packets:pb_contact_list()} | {upload_avatar, packets:pb_upload_avatar()} | {avatar, packets:pb_avatar()} | {avatars, packets:pb_avatars()} | {client_mode, packets:pb_client_mode()} | {client_version, packets:pb_client_version()} | {push_register, packets:pb_push_register()} | {whisper_keys, packets:pb_whisper_keys()} | {ping, packets:pb_ping()} | {feed_item, packets:pb_feed_item()} | {feed_node_items, packets:pb_feed_node_items()} | undefined % oneof
        }).
-endif.

-ifndef('PB_MSG_PAYLOAD_PB_H').
-define('PB_MSG_PAYLOAD_PB_H', true).
-record(pb_msg_payload,
        {content                :: {contact_list, packets:pb_contact_list()} | {avatar, packets:pb_avatar()} | {whisper_keys, packets:pb_whisper_keys()} | {seen, packets:pb_seen_receipt()} | {delivery, packets:pb_delivery_receipt()} | {chat, packets:pb_chat()} | {feed_item, packets:pb_feed_item()} | {feed_node_items, packets:pb_feed_node_items()} | undefined % oneof
        }).
-endif.

-ifndef('PB_HA_IQ_PB_H').
-define('PB_HA_IQ_PB_H', true).
-record(pb_ha_iq,
        {id = []                :: iodata() | undefined, % = 1
         type = get             :: get | set | result | error | integer() | undefined, % = 2, enum pb_ha_iq.Type
         payload = undefined    :: packets:pb_iq_payload() | undefined % = 3
        }).
-endif.

-ifndef('PB_HA_MESSAGE_PB_H').
-define('PB_HA_MESSAGE_PB_H', true).
-record(pb_ha_message,
        {id = []                :: iodata() | undefined, % = 1
         type = chat            :: chat | error | groupchat | headline | normal | integer() | undefined, % = 2, enum pb_ha_message.Type
         to_uid = 0             :: integer() | undefined, % = 3, 64 bits
         from_uid = 0           :: integer() | undefined, % = 4, 64 bits
         payload = undefined    :: packets:pb_msg_payload() | undefined % = 5
        }).
-endif.

-ifndef('PB_HA_PRESENCE_PB_H').
-define('PB_HA_PRESENCE_PB_H', true).
-record(pb_ha_presence,
        {id = []                :: iodata() | undefined, % = 1
         type = available       :: available | away | subscribe | unsubscribe | integer() | undefined, % = 2, enum pb_ha_presence.Type
         uid = 0                :: integer() | undefined, % = 3, 64 bits
         last_seen = 0          :: integer() | undefined % = 4, 64 bits
        }).
-endif.

-ifndef('PB_HA_ACK_PB_H').
-define('PB_HA_ACK_PB_H', true).
-record(pb_ha_ack,
        {id = []                :: iodata() | undefined, % = 1
         timestamp = 0          :: integer() | undefined % = 2, 64 bits
        }).
-endif.

-ifndef('PB_HA_ERROR_PB_H').
-define('PB_HA_ERROR_PB_H', true).
-record(pb_ha_error,
        {reason = []            :: iodata() | undefined % = 1
        }).
-endif.

-ifndef('PB_PACKET_PB_H').
-define('PB_PACKET_PB_H', true).
-record(pb_packet,
        {stanza                 :: {msg, packets:pb_ha_message()} | {iq, packets:pb_ha_iq()} | {ack, packets:pb_ha_ack()} | {presence, packets:pb_ha_presence()} | {error, packets:pb_ha_error()} | undefined % oneof
        }).
-endif.

-ifndef('PB_AUTH_REQUEST_PB_H').
-define('PB_AUTH_REQUEST_PB_H', true).
-record(pb_auth_request,
        {uid = 0                :: integer() | undefined, % = 1, 64 bits
         pwd = []               :: iodata() | undefined, % = 2
         cm = undefined         :: packets:pb_client_mode() | undefined, % = 3
         cv = undefined         :: packets:pb_client_version() | undefined, % = 4
         resource = []          :: iodata() | undefined % = 5
        }).
-endif.

-ifndef('PB_AUTH_RESULT_PB_H').
-define('PB_AUTH_RESULT_PB_H', true).
-record(pb_auth_result,
        {result = []            :: iodata() | undefined, % = 1
         reason = []            :: iodata() | undefined % = 2
        }).
-endif.

-ifndef('PB_CLIENT_MODE_PB_H').
-define('PB_CLIENT_MODE_PB_H', true).
-record(pb_client_mode,
        {mode = active          :: active | passive | integer() | undefined % = 1, enum pb_client_mode.Mode
        }).
-endif.

-ifndef('PB_CLIENT_VERSION_PB_H').
-define('PB_CLIENT_VERSION_PB_H', true).
-record(pb_client_version,
        {version = []           :: iodata() | undefined, % = 1
         expires_in_seconds = 0 :: integer() | undefined % = 2, 64 bits
        }).
-endif.

-ifndef('PB_UPLOAD_AVATAR_PB_H').
-define('PB_UPLOAD_AVATAR_PB_H', true).
-record(pb_upload_avatar,
        {id = []                :: iodata() | undefined, % = 1
         data = <<>>            :: iodata() | undefined % = 2
        }).
-endif.

-ifndef('PB_AVATAR_PB_H').
-define('PB_AVATAR_PB_H', true).
-record(pb_avatar,
        {id = []                :: iodata() | undefined, % = 1
         uid = 0                :: integer() | undefined % = 2, 64 bits
        }).
-endif.

-ifndef('PB_AVATARS_PB_H').
-define('PB_AVATARS_PB_H', true).
-record(pb_avatars,
        {avatars = []           :: [packets:pb_avatar()] | undefined % = 1
        }).
-endif.

-ifndef('PB_MEDIA_URL_PB_H').
-define('PB_MEDIA_URL_PB_H', true).
-record(pb_media_url,
        {get = []               :: iodata() | undefined, % = 1
         put = []               :: iodata() | undefined, % = 2
         patch = []             :: iodata() | undefined % = 3
        }).
-endif.

-ifndef('PB_UPLOAD_MEDIA_PB_H').
-define('PB_UPLOAD_MEDIA_PB_H', true).
-record(pb_upload_media,
        {size = 0               :: integer() | undefined, % = 1, 64 bits
         url = undefined        :: packets:pb_media_url() | undefined % = 2
        }).
-endif.

-ifndef('PB_CONTACT_PB_H').
-define('PB_CONTACT_PB_H', true).
-record(pb_contact,
        {action = add           :: add | delete | integer() | undefined, % = 1, enum pb_contact.Action
         raw = []               :: iodata() | undefined, % = 2
         normalized = []        :: iodata() | undefined, % = 3
         uid = 0                :: integer() | undefined, % = 4, 64 bits
         avatar_id = []         :: iodata() | undefined, % = 5
         role = friend          :: friend | none | integer() | undefined % = 6, enum pb_contact.Role
        }).
-endif.

-ifndef('PB_CONTACT_LIST_PB_H').
-define('PB_CONTACT_LIST_PB_H', true).
-record(pb_contact_list,
        {type = full            :: full | delta | integer() | undefined, % = 1, enum pb_contact_list.Type
         sync_id = []           :: iodata() | undefined, % = 2
         batch_index = 0        :: integer() | undefined, % = 3, 32 bits
         is_last = false        :: boolean() | 0 | 1 | undefined, % = 4
         contacts = []          :: [packets:pb_contact()] | undefined % = 5
        }).
-endif.

-ifndef('PB_SEEN_RECEIPT_PB_H').
-define('PB_SEEN_RECEIPT_PB_H', true).
-record(pb_seen_receipt,
        {id = []                :: iodata() | undefined, % = 1
         thread_id = []         :: iodata() | undefined, % = 2
         timestamp = 0          :: integer() | undefined % = 3, 64 bits
        }).
-endif.

-ifndef('PB_DELIVERY_RECEIPT_PB_H').
-define('PB_DELIVERY_RECEIPT_PB_H', true).
-record(pb_delivery_receipt,
        {id = []                :: iodata() | undefined, % = 1
         thread_id = []         :: iodata() | undefined, % = 2
         timestamp = 0          :: integer() | undefined % = 3, 64 bits
        }).
-endif.

-ifndef('PB_FEEDPOST_PB_H').
-define('PB_FEEDPOST_PB_H', true).
-record(pb_feedpost,
        {id = []                :: iodata() | undefined, % = 1
         payload = <<>>         :: iodata() | undefined % = 2
        }).
-endif.

-ifndef('PB_COMMENT_PB_H').
-define('PB_COMMENT_PB_H', true).
-record(pb_comment,
        {id = []                :: iodata() | undefined, % = 1
         publisher_uid = 0      :: integer() | undefined, % = 2, 64 bits
         publisher_name = []    :: iodata() | undefined, % = 3
         post_id = []           :: iodata() | undefined, % = 4
         payload = <<>>         :: iodata() | undefined % = 5
        }).
-endif.

-ifndef('PB_FEED_ITEM_PB_H').
-define('PB_FEED_ITEM_PB_H', true).
-record(pb_feed_item,
        {action = publish       :: publish | retract | integer() | undefined, % = 1, enum pb_feed_item.Action
         timestamp = 0          :: integer() | undefined, % = 2, 64 bits
         item                   :: {feedpost, packets:pb_feedpost()} | {comment, packets:pb_comment()} | undefined % oneof
        }).
-endif.

-ifndef('PB_FEED_NODE_ITEMS_PB_H').
-define('PB_FEED_NODE_ITEMS_PB_H', true).
-record(pb_feed_node_items,
        {uid = 0                :: integer() | undefined, % = 1, 64 bits
         items = []             :: [packets:pb_feed_item()] | undefined % = 2
        }).
-endif.

-ifndef('PB_WHISPER_KEYS_PB_H').
-define('PB_WHISPER_KEYS_PB_H', true).
-record(pb_whisper_keys,
        {uid = 0                :: integer() | undefined, % = 1, 64 bits
         action = normal        :: normal | add | count | get | set | update | integer() | undefined, % = 2, enum pb_whisper_keys.Action
         identity_key = <<>>    :: iodata() | undefined, % = 3
         signed_key = <<>>      :: iodata() | undefined, % = 4
         otp_key_count = 0      :: integer() | undefined, % = 5, 32 bits
         one_time_keys = []     :: [iodata()] | undefined % = 6
        }).
-endif.

-ifndef('PB_PUSH_TOKEN_PB_H').
-define('PB_PUSH_TOKEN_PB_H', true).
-record(pb_push_token,
        {os = android           :: android | ios | ios_dev | integer() | undefined, % = 1, enum pb_push_token.Os
         token = []             :: iodata() | undefined % = 2
        }).
-endif.

-ifndef('PB_PUSH_REGISTER_PB_H').
-define('PB_PUSH_REGISTER_PB_H', true).
-record(pb_push_register,
        {push_token = undefined :: packets:pb_push_token() | undefined % = 1
        }).
-endif.

-endif.
