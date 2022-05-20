%%%-------------------------------------------------------------------
%%% @copyright (C) 2021, HalloApp, Inc.
%%%-------------------------------------------------------------------
-author("vipin").

-ifndef(USER_EVENTS_HRL).
-define(USER_EVENTS_HRL, 1).

-type(user_event_type() :: im_sent | im_recv | post_published | comment_published | group_post_published |
    group_comment_published | im_send_seen | im_receive_seen | post_send_seen | post_receive_seen |
    item_retracted | invite_recorded | invite_accepted | group_invite_recorded | group_invite_accepted |
    app_opened | secret_post_published | secret_post_send_seen | secret_post_receive_seen).

-endif.
