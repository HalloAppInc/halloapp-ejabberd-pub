%% -*- coding: utf-8 -*-
%% Automatically generated, do not edit
%% Generated by gpb_compile version 4.12.0

-ifndef(feed_items).
-define(feed_items, true).

-define(feed_items_gpb_version, "4.12.0").

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
         feedpost_id = []       :: iodata() | undefined, % = 4
         payload = <<>>         :: iodata() | undefined % = 5
        }).
-endif.

-ifndef('PB_FEED_ITEM_PB_H').
-define('PB_FEED_ITEM_PB_H', true).
-record(pb_feed_item,
        {action = publish       :: publish | retract | integer() | undefined, % = 1, enum pb_feed_item.Action
         timestamp = 0          :: integer() | undefined, % = 2, 64 bits
         uid = 0                :: integer() | undefined, % = 3, 64 bits
         item                   :: {feedpost, feed_items:pb_feedpost()} | {comment, feed_items:pb_comment()} | undefined % oneof
        }).
-endif.

-ifndef('PB_FEED_NODE_ITEMS_PB_H').
-define('PB_FEED_NODE_ITEMS_PB_H', true).
-record(pb_feed_node_items,
        {uid = 0                :: integer() | undefined, % = 1, 64 bits
         items = []             :: [feed_items:pb_feed_item()] | undefined % = 2
        }).
-endif.

-endif.
