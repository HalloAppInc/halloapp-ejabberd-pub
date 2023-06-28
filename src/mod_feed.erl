%%%-----------------------------------------------------------------------------------
%%% File    : mod_feed.erl
%%%
%%% Copyright (C) 2020 halloappinc.
%%%
%%% TODO(murali@): Feed hooks do not contain payload since we dont need it for now.
%%%-----------------------------------------------------------------------------------

-module(mod_feed).
-behaviour(gen_mod).
-author('murali').

-include("packets.hrl").
-include("logger.hrl").
-include("feed.hrl").
-include("jid.hrl").

-dialyzer({no_match, make_pb_feed_post/7}).
-dialyzer({no_match, broadcast_event/5}).

-define(CURSOR_VERSION_V0, <<"V0">>).
-define(NS_FEED, <<"halloapp:feed">>).
-define(NUM_PUBLIC_FEED_ITEMS_PER_REQUEST, 30).
-define(PUBLIC_FEED_LIMIT_FACTOR, 3).

%% Chose these weights with the following theory in mind.
%% Just for experimenting for now.
%% FollowingInterest score is very important.
%% A post from an author whom 10% of my followers follow is ranked on the same level as a post from my campus.
%% Recent post is something that was posted in the last 1hour.
%% Campus post is something that was posted from an author in the same geotag as me.
%% FollowingInterest post is something that was posted from an author whom more than 10% of people I follow - follow
%% Unseen post is a post that was not seen by the user yet.

%% Unseen posts are always ranked higher than seen posts.
%% Selected the following scores such that:
%% Unseen campus posts are always ranked higher than all other posts.
%% Unseen non-campus posts are ranked higher than seen-following-campus posts with less than 40% of my followers.
%% Unseen non-campus posts are ranked higher than seen-following-non-campus posts with less than 55% of my followers.
%% Any FollowingInterest post is always ranked higher than any campus post or recent post.
%% Any campus post is always ranked higher than a recent post.
%% TODO: Use celeb score of author?
%% TODO: num of followers to be taken into account for following interest score instead of raw percent?
%% TODO: Show score for post?
-define(CAMPUS_SCORE_IMPORTANCE, 10.0).
-define(FOLLOWING_INTEREST_IMPORTANCE, 110.0).
-define(FOF_SCORE_IMPORTANCE, 0.1).
-define(RECENCY_SCORE_IMPORTANCE, 1.0).
-define(TIME_ZONE_IMPORTANCE, 40.0).


%% gen_mod API.
-export([start/2, stop/1, reload/3, mod_options/1, depends/2]).

%% Hooks and API.
-export([
    user_send_packet/1,
    process_local_iq/1,
    add_friend/4,
    remove_user/2,
    get_active_psa_tag_list/0,
    send_old_items/3,
    share_feed_items/4,
    send_old_moment/2,
    send_moment_notification/8,
    new_follow_relationship/2,
    remove_follow_relationship/2,
    get_ranked_public_moments/7,
    re_register_user/4,
    convert_moments_to_public_feed_items/3,
    check_users/2,
    send_all_old_moments_to_self/1,
    sm_register_connection_hook/4,
    convert_posts_to_feed_items/1,
    send_expiry_notice/1
]).


start(_Host, _Opts) ->
    %% HalloApp
    gen_iq_handler:add_iq_handler(ejabberd_local, halloapp, pb_feed_item, ?MODULE, process_local_iq),
    ejabberd_hooks:add(add_friend, halloapp, ?MODULE, add_friend, 50),
    ejabberd_hooks:add(remove_user, halloapp, ?MODULE, remove_user, 50),
    ejabberd_hooks:add(user_send_packet, halloapp, ?MODULE, user_send_packet, 50),
    %% Katchup
    gen_iq_handler:add_iq_handler(ejabberd_local, katchup, pb_feed_item, ?MODULE, process_local_iq),
    gen_iq_handler:add_iq_handler(ejabberd_local, katchup, pb_public_feed_request, ?MODULE, process_local_iq),
    gen_iq_handler:add_iq_handler(ejabberd_local, katchup, pb_post_subscription_request, ?MODULE, process_local_iq),
    ejabberd_hooks:add(add_friend, katchup, ?MODULE, add_friend, 50),
    ejabberd_hooks:add(remove_user, katchup, ?MODULE, remove_user, 50),
    ejabberd_hooks:add(user_send_packet, katchup, ?MODULE, user_send_packet, 50),
    ejabberd_hooks:add(send_moment_notification, katchup, ?MODULE, send_moment_notification, 50),
    ejabberd_hooks:add(new_follow_relationship, katchup, ?MODULE, new_follow_relationship, 50),
    ejabberd_hooks:add(remove_follow_relationship, katchup, ?MODULE, remove_follow_relationship, 50),
    ejabberd_hooks:add(re_register_user, katchup, ?MODULE, re_register_user, 50),
    %% We must run the sm_register_connection_hook early on - so that we have access to their their previous login time.
    ejabberd_hooks:add(sm_register_connection_hook, katchup, ?MODULE, sm_register_connection_hook, 10),
    %% Photo Sharing
    gen_iq_handler:add_iq_handler(ejabberd_local, ?PHOTO_SHARING, pb_feed_item, ?MODULE, process_local_iq),
    ejabberd_hooks:add(user_send_packet, ?PHOTO_SHARING, ?MODULE, user_send_packet, 50),
    ok.

stop(_Host) ->
    gen_iq_handler:remove_iq_handler(ejabberd_local, halloapp, pb_feed_item),
    ejabberd_hooks:delete(add_friend, halloapp, ?MODULE, add_friend, 50),
    ejabberd_hooks:delete(remove_user, halloapp, ?MODULE, remove_user, 50),
    ejabberd_hooks:delete(user_send_packet, halloapp, ?MODULE, user_send_packet, 50),
    %% Katchup
    gen_iq_handler:remove_iq_handler(ejabberd_local, katchup, pb_feed_item),
    gen_iq_handler:remove_iq_handler(ejabberd_local, katchup, pb_public_feed_request),
    ejabberd_hooks:delete(add_friend, katchup, ?MODULE, add_friend, 50),
    ejabberd_hooks:delete(remove_user, katchup, ?MODULE, remove_user, 50),
    ejabberd_hooks:delete(user_send_packet, katchup, ?MODULE, user_send_packet, 50),
    ejabberd_hooks:delete(send_moment_notification, katchup, ?MODULE, send_moment_notification, 50),
    ejabberd_hooks:delete(new_follow_relationship, katchup, ?MODULE, new_follow_relationship, 50),
    ejabberd_hooks:delete(remove_follow_relationship, katchup, ?MODULE, remove_follow_relationship, 50),
    ejabberd_hooks:delete(re_register_user, katchup, ?MODULE, re_register_user, 50),
    ejabberd_hooks:delete(sm_register_connection_hook, katchup, ?MODULE, sm_register_connection_hook, 10),
    %% Photo Sharing
    gen_iq_handler:remove_iq_handler(ejabberd_local, ?PHOTO_SHARING, pb_feed_item),
    ejabberd_hooks:delete(user_send_packet, ?PHOTO_SHARING, ?MODULE, user_send_packet, 50),
    ok.

reload(_Host, _NewOpts, _OldOpts) ->
    ok.

depends(_Host, _Opts) ->
    [].

mod_options(_Host) ->
    [].


%%====================================================================
%% feed: IQs
%%====================================================================

user_send_packet({#pb_msg{id = MsgId, to_uid = ToUid, from_uid = FromUid,
        payload = #pb_feed_item{} = _Payload} = Packet, State} = _Acc) ->
    PayloadType = util:get_payload_type(Packet),
    ContentId = pb:get_content_id(Packet),
    ?INFO("Uid: ~s sending ~p message to ~s MsgId: ~s, ContentId: ~p",
        [FromUid, PayloadType, ToUid, MsgId, ContentId]),
    Packet1 = set_sender_info(Packet),
    {Packet1, State};

user_send_packet({#pb_msg{id = MsgId, to_uid = ToUid, from_uid = FromUid, rerequest_count = RerequestCount,
        payload = #pb_home_feed_rerequest{id = Id, rerequest_type = RerequestType,
        content_type = ContentType}} = Packet, _State} = Acc) ->
    PayloadType = util:get_payload_type(Packet),
    ?INFO("Uid: ~s sending ~p message to ~s MsgId: ~s, Id: ~p, RerequestType: ~p, ContentType: ~p, RerequestCount: ~p",
        [FromUid, PayloadType, ToUid, MsgId, Id, RerequestType, ContentType, RerequestCount]),
    Acc;

user_send_packet({#pb_msg{id = MsgId, to_uid = ToUid, from_uid = FromUid,
        payload = #pb_feed_items{}} = Packet, State} = _Acc) ->
    PayloadType = util:get_payload_type(Packet),
    ?INFO("Uid: ~s sending ~p message to ~s MsgId: ~s", [FromUid, PayloadType, ToUid, MsgId]),
    Packet1 = set_sender_info(Packet),
    {Packet1, State};

user_send_packet({#pb_msg{id = MsgId, to_uid = ToUid, from_uid = FromUid,
        payload = #pb_content_missing{}} = Packet, _State} = Acc) ->
    PayloadType = util:get_payload_type(Packet),
    ContentId = pb:get_content_id(Packet),
    ?INFO("Uid: ~s sending ~p message to ~s MsgId: ~s ContentId: ~p", [FromUid, PayloadType, ToUid, MsgId, ContentId]),
    Acc;


user_send_packet({#pb_msg{id = MsgId, to_uid = ToUid, from_uid = FromUid,
        payload = #pb_seen_receipt{id = PostId, thread_id = _ThreadId, timestamp = Timestamp}} = Packet, _State} = Acc) ->
    PayloadType = util:get_payload_type(Packet),
    case util_uid:get_app_type(FromUid) of
        katchup -> model_feed:mark_seen_posts(FromUid, PostId);
        _ -> ok
    end,
    ?INFO("Uid: ~s sending ~p message to ~s MsgId: ~s PostId: ~p Timestamp: ~p", [FromUid, PayloadType, ToUid, MsgId, PostId, Timestamp]),
    Acc;

user_send_packet({_Packet, _State} = Acc) ->
    Acc.


sm_register_connection_hook(_SID, #jid{luser = Uid, lresource = Resource} = _JID, _Mode, _Info) ->
    case util_ua:is_resource_extension(Resource) of
        true ->
            ?INFO("Uid: ~p ignoring session from resource: ~p", [Uid, Resource]);
        false ->
            %% TODO: Use latest location from login instead of old geotag.
            %% Fetch latest geotag, public moments (convert them to pb feed items) and calculate cursor
            %% Check for unseen content and send the message only if content discovered has new content, else discard.
            GeoTag = model_accounts:get_latest_geo_tag(Uid),
            Cursor = <<>>,
            {_ReloadFeed, NewCursor, PublicMoments, MomentScoresMap} = get_ranked_public_moments(Uid,
                GeoTag, util:now_ms(), Cursor, ?NUM_PUBLIC_FEED_ITEMS_PER_REQUEST, false, false),
            %% We dont want to be sending the public feed update with the same set of items that the user has seen already.
            %% PublicFeedUpdate messages are to be sent when there is new unseen content - meaning content that is not on the device and not seen.
            OldCursor = model_feed:get_last_cursor(Uid),
            %% Get LastConnection time.
            TimeDiffMs = case model_accounts:get_last_connection_time(Uid) of
                undefined -> ?KATCHUP_PUBLIC_FEED_REFRESH_MSECS;
                LastConnectionTimeMs -> util:now_ms() - LastConnectionTimeMs
            end,
            case OldCursor =:= NewCursor andalso TimeDiffMs < ?KATCHUP_PUBLIC_FEED_REFRESH_MSECS of
                true ->
                    ?INFO("Uid: ~p, GeoTag: ~p Cursor: ~p no new posts to send to the clients", [Uid, GeoTag, Cursor]);
                false ->
                    ?INFO("Uid: ~p, OldCursor: ~p, NewCursor: ~p, TimeDiffMs: ~p", [Uid, OldCursor, NewCursor, TimeDiffMs]),
                    case filter_seen_moments(Uid, PublicMoments) =/= [] of
                        false ->
                            ?INFO("Uid: ~p, GeoTag: ~p no unseen posts to send on public feed, so skip", [Uid, GeoTag]);
                        true ->
                            model_feed:set_last_cursor(Uid, NewCursor),
                            %% We send all fetched content but we check for unseen content.
                            PublicFeedItems = lists:map(
                                fun(PublicMoment) -> convert_moments_to_public_feed_items(Uid, PublicMoment, MomentScoresMap) end, PublicMoments),
                            MsgId = util_id:new_msg_id(),
                            Packet = #pb_msg{
                                id = MsgId,
                                to_uid = Uid,
                                payload = #pb_public_feed_update{
                                    cursor = NewCursor,
                                    public_feed_content_type = moments,
                                    items = PublicFeedItems
                                }
                            },
                            ?INFO("Uid: ~p, GeoTag: ~p sending public feed update MsgId: ~p, NewCursor: ~p, NumItems: ~p",
                                [Uid, GeoTag, MsgId, NewCursor, length(PublicFeedItems)]),
                            ejabberd_router:route(Packet)
                    end
            end
    end,
    ok.


%% Publish post.
process_local_iq(#pb_iq{from_uid = Uid, type = set,
        payload = #pb_feed_item{action = publish, item = #pb_post{} = Post} = HomeFeedSt} = IQ) ->
    PostId = Post#pb_post.id,
    PayloadBase64 = base64:encode(Post#pb_post.payload),
    PostTag = Post#pb_post.tag,
    AudienceList = Post#pb_post.audience,
    PSATag = Post#pb_post.psa_tag,
    PublisherName = model_accounts:get_name_binary(Uid),
    PublisherUsername = model_accounts:get_username_binary(Uid),
    case publish_post(Uid, PostId, PayloadBase64, PostTag, PSATag, AudienceList, HomeFeedSt) of
        {ok, ResultTsMs} ->
            SubEl = update_feed_post_st(Uid, PublisherName, PublisherUsername, HomeFeedSt, Uid, ResultTsMs),
            pb:make_iq_result(IQ, SubEl);
        {error, Reason} ->
            pb:make_error(IQ, util:err(Reason))
    end;

%% Publish comment.
process_local_iq(#pb_iq{from_uid = Uid, type = set, payload = #pb_feed_item{
        action = publish = Action, item = #pb_comment{} = Comment} = HomeFeedSt} = IQ) ->
    CommentId = Comment#pb_comment.id,
    PostId = Comment#pb_comment.post_id,
    ParentCommentId = Comment#pb_comment.parent_comment_id,
    PayloadBase64 = base64:encode(Comment#pb_comment.payload),
    case publish_comment(Uid, CommentId, PostId, ParentCommentId, PayloadBase64, HomeFeedSt) of
        {ok, ResultTsMs} ->
            SubEl = make_pb_feed_comment(Action, CommentId, PostId,
                    ParentCommentId, Uid, HomeFeedSt, ResultTsMs),
            pb:make_iq_result(IQ, SubEl);
        {error, Reason} ->
            pb:make_error(IQ, util:err(Reason))
    end;

% Retract post.
process_local_iq(#pb_iq{from_uid = Uid, type = set,
        payload = #pb_feed_item{action = retract = Action, item = #pb_post{} = Post}} = IQ) ->
    PostId = Post#pb_post.id,
    case retract_post(Uid, PostId) of
        {ok, ResultTsMs} ->
            SubEl = make_pb_feed_post(Action, PostId, Uid, <<>>, <<>>, undefined, ResultTsMs),
            pb:make_iq_result(IQ, SubEl);
        {error, Reason} ->
            pb:make_error(IQ, util:err(Reason))
    end;

% Retract comment.
process_local_iq(#pb_iq{from_uid = Uid, type = set,
        payload = #pb_feed_item{action = retract = Action, item = #pb_comment{} = Comment} = HomeFeedSt} = IQ) ->
    CommentId = Comment#pb_comment.id,
    PostId = Comment#pb_comment.post_id,
    ParentCommentId = Comment#pb_comment.parent_comment_id,
    case retract_comment(Uid, CommentId, PostId, HomeFeedSt) of
        {ok, ResultTsMs} ->
            SubEl = make_pb_feed_comment(Action, CommentId, PostId,
                    ParentCommentId, Uid, HomeFeedSt, ResultTsMs),
            pb:make_iq_result(IQ, SubEl);
        {error, Reason} ->
            pb:make_error(IQ, util:err(Reason))
    end;

% Share posts with friends.
process_local_iq(#pb_iq{from_uid = Uid, type = set,
        payload = #pb_feed_item{action = share = Action, share_stanzas = SharePostStanzas}} = IQ) ->
    Server = util:get_host(),
    ResultSharePostStanzas = lists:map(
        fun(SharePostSt) ->
            process_share_posts(Uid, Server, SharePostSt)
        end, SharePostStanzas),
    pb:make_iq_result(IQ, #pb_feed_item{action = Action, share_stanzas = ResultSharePostStanzas});

% Get public feed items
process_local_iq(#pb_iq{from_uid = Uid, payload = #pb_public_feed_request{cursor = Cursor,
    public_feed_content_type = moments, gps_location = GpsLocation, show_dev_content = ShowDevContent}} = IQ) ->
    ?INFO("Public feed request: Uid ~s, GpsLocation ~p, Cursor ~p", [Uid, GpsLocation, Cursor]),
    case GpsLocation =/= undefined of
        true ->
            ha_events:log_event(<<"server.public_feed_requests">>,
                #{
                    uid => Uid,
                    latitude => GpsLocation#pb_gps_location.latitude,
                    longitude => GpsLocation#pb_gps_location.longitude
                });
        false ->
            ok
    end,
    %% Get geotag from GeoLocation, add it to user account if it exists
    NewTag = mod_location:get_geo_tag(Uid, GpsLocation),
    case NewTag of
        undefined -> ok;
        _ ->
            ?INFO("Adding new tag ~p for Uid ~s", [NewTag, Uid]),
            model_accounts:add_geo_tag(Uid, NewTag, util:now())
    end,
    %% Fetch latest geotag, public moments (convert them to pb feed items) and calculate cursor
    GeoTag = model_accounts:get_latest_geo_tag(Uid),
    % GeoTags = case GeoTag of
    %     undefined -> [];
    %     _ -> [util:to_binary(GeoTag)]
    % end,
    {ReloadFeed, NewCursor, PublicMoments, MomentScoresMap} = get_ranked_public_moments(Uid, GeoTag, util:now_ms(), Cursor, ?NUM_PUBLIC_FEED_ITEMS_PER_REQUEST, ShowDevContent, false),
    model_feed:set_last_cursor(Uid, NewCursor),
    PublicFeedItems = lists:map(fun(PublicMoment) -> convert_moments_to_public_feed_items(Uid, PublicMoment, MomentScoresMap) end, PublicMoments),
    Ret = #pb_public_feed_response{
        result = success,
        reason = ok,
        cursor = NewCursor,
        public_feed_content_type = moments,
        cursor_restarted = ReloadFeed,
        items = PublicFeedItems
        % geo_tags = GeoTags
        %% todo: clients may have old proto - so dont send this field for now.
    },
    ?INFO("Successful public feed response: Uid ~s, NewCursor ~p, Tag ~p NumItems ~p",
        [Uid, NewCursor, GeoTag, length(PublicFeedItems)]),
    pb:make_iq_result(IQ, Ret);

process_local_iq(#pb_iq{payload = #pb_public_feed_request{public_feed_content_type = ContentType}} = IQ) ->
    %% Return error for content type other than moments
    Ret = #pb_public_feed_response{
        result = failure,
        reason = unknown_reason,
        cursor = <<>>,
        public_feed_content_type = ContentType,
        items = []
    },
    pb:make_iq_result(IQ, Ret);

process_local_iq(#pb_iq{from_uid = Uid, payload = #pb_post_subscription_request{action = subscribe, post_id = PostId}} = IQ) ->
    Ret = case model_feed:get_post(PostId) of
        {error, missing} ->
            #pb_post_subscription_response{
                result = failure,
                reason = invalid_post_id,
                items = []
            };
        {ok, Post} ->
            %% Filter if the interaction is in between blocked users.
            case model_follow:is_blocked_any(Uid, Post#post.uid) of
                true ->
                    #pb_post_subscription_response{
                        result = failure,
                        reason = invalid_post_id,
                        items = []
                    };
                false ->
                    %% Filter out comments from blocked users.
                    {ok, Comments} = model_feed:get_post_comments(PostId),
                    FilteredComments = lists:filter(
                        fun(Comment) ->
                            not model_follow:is_blocked_any(Uid, Comment#comment.publisher_uid)
                        end, Comments),
                    CommentStanzas = lists:map(
                        fun(Comment) -> convert_comments_to_feed_items(Comment, public_update_publish) end,
                        FilteredComments),
                    ok = model_feed:subscribe_uid_to_post(Uid, PostId),
                    #pb_post_subscription_response{
                        result = success,
                        items = CommentStanzas
                    }
            end
    end,
    pb:make_iq_result(IQ, Ret).


-spec add_friend(Uid :: uid(), Server :: binary(), Ouid :: uid(), WasBlocked :: boolean()) -> ok.
add_friend(Uid, _Server, Ouid, false) ->
    ?INFO("Uid: ~s, Ouid: ~s", [Uid, Ouid]),
    UidAppType = util_uid:get_app_type(Uid),
    OuidAppType = util_uid:get_app_type(Ouid),
    case UidAppType =:= OuidAppType andalso UidAppType =:= katchup of
        true ->
            %% TODO: WIP
            ok;
            % % Posts from Uid to Ouid
            % send_old_items(Uid, Ouid, Server),
            % % Posts from Ouid to Uid
            % send_old_items(Ouid, Uid, Server),
        false ->
            ok
    end,
    ok;
add_friend(_Uid, _Server, _Ouid, true) ->
    ok.


-spec remove_user(Uid :: uid(), Server :: binary()) -> ok.
remove_user(Uid, _Server) ->
    case util_uid:get_app_type(Uid) of
        katchup ->
            case model_feed:get_user_latest_post(Uid) of
                undefined -> ok;
                Post ->
                    case Post#post.expired of
                        true -> ok;
                        false ->
                            retract_post(Uid, Post#post.id)
                    end
            end,
            ok;
        _ -> ok
    end,
    ok = model_feed:remove_user(Uid),
    ok.


%% we clear all old posts of this user from the server once we send a notification.
%% since this post is no longer valid from that user.
%% when a new user follows this user - they should no longer get old posts.
send_moment_notification(Uid, _Region, NotificationId, _NotificationTime, _NotificationType, _Prompt, _HideBanner, _Reminder) ->
    AppType = util_uid:get_app_type(Uid),
    case AppType of
        katchup ->
            case model_feed:get_notification_id(Uid) of
                undefined -> ok;
                OldNotificationId ->
                    case model_feed:get_user_latest_post(Uid) of
                        undefined -> ok;
                        Post ->
                            %% Send expiry notice only if the latest post was the previous days post.
                            case Post#post.moment_info#pb_moment_info.notification_id =:= OldNotificationId of
                                true -> send_expiry_notice(Post);
                                false -> ok
                            end
                    end
            end,
            model_feed:expire_all_user_posts(Uid, NotificationId),
            model_feed:set_notification_id(Uid, NotificationId),
            model_feed:clean_ranked_feed(Uid, NotificationId),
            ok;
        _ -> ok
    end,
    ?INFO("Uid: ~p, clearing all old posts for AppType: ~p", [Uid, AppType]),
    ok.


new_follow_relationship(Uid, Ouid) ->
    ?INFO("New follow relationship, send old moment fromUid: ~p, ToUid: ~p", [Ouid, Uid]),
    send_old_moment(Ouid, Uid),
    ok.

remove_follow_relationship(Uid, Ouid) ->
    ?INFO("removed follow relationship, send old moment fromUid: ~p, ToUid: ~p", [Ouid, Uid]),
    case model_feed:get_user_latest_post(Ouid) of
        undefined -> ok;
        Post ->
            case Post#post.expired of
                true -> ok;
                false ->
                    ok = model_feed:remove_uid_from_audience(Uid, [Post#post.id]),
                    ok = model_feed:unsubscribe_uid_to_post(Uid, [Post#post.id])
            end
    end,
    ok.

-spec re_register_user(Uid :: binary(), Server :: binary(), Phone :: binary(), CampaignId :: binary()) -> ok.
re_register_user(Uid, _Server, _Phone, _CampaignId) ->
    ?INFO("re_register_user Uid: ~p", [Uid]),
    send_old_moment(Uid, Uid),
    send_all_old_moments_to_self(Uid),
    AppType = util_uid:get_app_type(Uid),
    case AppType of
        katchup ->
            Ouids = model_follow:get_all_following(Uid),
            lists:foreach(
                fun(Ouid) ->
                    send_old_moment(Ouid, Uid)
                end, Ouids);
        _ ->
            ok
    end,
    %% Clear everything on public feed as well, recompute everything.
    model_feed:clear_ranked_feed(Uid),
    model_feed:clear_past_seen_posts(Uid),
    ok.


is_psa_tag_allowed(PSATag, Uid) ->
    case is_psa_tag_allowed(PSATag) of
        true -> dev_users:is_psa_admin(Uid);
        false -> false
    end.

get_active_psa_tag_list() ->
    [
        <<"SR">>,
        <<"HA">>
    ].

is_psa_tag_allowed(<<"NEW">>) -> true;
is_psa_tag_allowed(PSATag) ->
    lists:member(PSATag, get_active_psa_tag_list()).


%%====================================================================
%% Internal functions
%%====================================================================

-spec send_expiry_notice(Post :: post()) -> ok.
send_expiry_notice(#post{id = PostId, uid = PostOwnerUid} = Post) ->
    %% get all audience, set action=retract to include everyone.
    FeedAudienceList = sets:to_list(get_feed_audience_set(retract, PostOwnerUid, Post#post.audience_list ++ Post#post.subscribed_audience_list)),
    [PostOwnerZoneOffset | AudienceListZoneOffset] = model_accounts:get_zone_offset_secs([PostOwnerUid] ++ FeedAudienceList),
    lists:foreach(
        fun({ToUid, ToUidZoneOffset}) ->
            case ToUidZoneOffset =:= PostOwnerZoneOffset andalso PostOwnerZoneOffset =/= undefined of
                true -> ok;
                false ->
                    ?INFO("send_expiry_notice about PostId: ~p, ToUid: ~p", [PostId, ToUid]),
                    Packet = #pb_msg{
                        id = util_id:new_msg_id(),
                        to_uid = ToUid,
                        from_uid = PostOwnerUid,
                        payload = #pb_feed_item{
                            action = expire,
                            item = #pb_post{
                                id = PostId,
                                is_expired = true
                            }
                        }
                    },
                    ejabberd_router:route(Packet)
            end
        end, lists:zip(FeedAudienceList, AudienceListZoneOffset)),
    ok.


-spec set_sender_info(Message :: message()) -> message().
set_sender_info(#pb_msg{id = MsgId, payload = #pb_feed_items{items = Items} = FeedItems} = Message) ->
    NewItems = [set_ts_and_publisher_username(MsgId, Item) || Item <- Items],
    NewFeedItems = FeedItems#pb_feed_items{
        items = NewItems
    },
    Message#pb_msg{payload = NewFeedItems};
    
set_sender_info(#pb_msg{id = MsgId, payload = #pb_feed_item{} = FeedItem} = Message) ->
    NewFeedItem = set_ts_and_publisher_username(MsgId, FeedItem),
    Message#pb_msg{payload = NewFeedItem}.

set_ts_and_publisher_username(MsgId, #pb_feed_item{item = Item} = FeedItem) ->
    %% TODO: remove code to get, set the timestamp after both clients implement it properly.
    {Timestamp, PublisherUid} = case Item of
        #pb_post{timestamp = undefined} ->
            ?WARNING("MsgId: ~p, Timestamp is missing", [MsgId]),
            {util:now(), Item#pb_post.publisher_uid};
        #pb_comment{timestamp = undefined} ->
            ?WARNING("MsgId: ~p, Timestamp is missing", [MsgId]),
            {util:now(), Item#pb_comment.publisher_uid};
        #pb_post{timestamp = T} -> {T, Item#pb_post.publisher_uid};
        #pb_comment{timestamp = T} -> {T, Item#pb_comment.publisher_uid}
    end,
    SenderName = model_accounts:get_name_binary(PublisherUid),
    SenderUsername = model_accounts:get_username_binary(PublisherUid),
    case Item of
        #pb_post{} -> 
            Item2 = Item#pb_post{
                timestamp = Timestamp,
                publisher_name = SenderName,
                publisher_username = SenderUsername
            },
            FeedItem#pb_feed_item{
                item = Item2
            };
        #pb_comment{} ->
            Item2 = Item#pb_comment{
                timestamp = Timestamp,
                publisher_name = SenderName,
                publisher_username = SenderUsername
            },
            FeedItem#pb_feed_item{
                item = Item2
            }
    end.


-spec has_valid_post(Uid :: uid(), LatestNotificationId :: integer()) -> boolean().
has_valid_post(Uid, LatestNotificationId) ->
    case model_feed:get_user_latest_post(Uid) of
        %% retracted posts show up as undefined.
        undefined -> false;
        OldPost ->
            %% Latest post should match notif id and also be unexpired.
            OldPost#post.moment_info#pb_moment_info.notification_id =:= LatestNotificationId andalso not OldPost#post.expired
    end.


%% TODO(murali@): update payload to be protobuf binary without base64 encoded.

-spec publish_post(Uid :: uid(), PostId :: binary(), PayloadBase64 :: binary(), PostTag :: post_tag(),
        PSATag :: binary(), AudienceListStanza ::[pb_audience()], HomeFeedSt :: pb_feed_item()) -> {ok, integer()} | {error, any()}.
publish_post(_Uid, _PostId, _PayloadBase64, _PostTag, _PSATag, undefined, _HomeFeedSt) ->
    {error, no_audience};
publish_post(_Uid, _PostId, _PayloadBase64, public_post, _PSATag, _AudienceList, _HomeFeedSt) -> {error, not_supported};
publish_post(Uid, PostId, PayloadBase64, public_moment, PSATag, AudienceList, HomeFeedSt)
        when PSATag =:= undefined; PSATag =:= <<>> ->
    ?INFO("Uid: ~s, public_moment PostId: ~s", [Uid, PostId]),
    AppType = util_uid:get_app_type(Uid),
    Action = publish,
    MediaCounters = HomeFeedSt#pb_feed_item.item#pb_post.media_counters,
    MomentInfo = HomeFeedSt#pb_feed_item.item#pb_post.moment_info,
    FilteredAudienceList1 = case AppType of
        halloapp -> AudienceList#pb_audience.uids;
        katchup -> model_follow:get_all_followers(Uid)
    end,
    FilteredAudienceList2 = sets:to_list(get_feed_audience_set(Action, Uid, FilteredAudienceList1)),
    LatestNotificationId = model_feed:get_notification_id(Uid),
    case LatestNotificationId =:= undefined orelse MomentInfo#pb_moment_info.notification_id >= LatestNotificationId of
        false ->
            ?ERROR("Uid: ~p tried to publish using old notif id", [Uid]),
            {error, old_notification_id};
        true ->
            case has_valid_post(Uid, LatestNotificationId) of
                true -> {error, other_post_exists};
                false ->
                    {ok, FinalTimestampMs} = case model_feed:get_post(PostId) of
                        {error, missing} ->
                            TimestampMs = util:now_ms(),
                            ?INFO("Uid: ~s PostId ~p published as public_moment: ~p", [Uid, PostId]),
                            ok = model_feed:publish_moment(PostId, Uid, PayloadBase64, public_moment, all, FilteredAudienceList2, TimestampMs, MomentInfo),
                            ejabberd_hooks:run(feed_item_published, AppType,
                                [Uid, Uid, PostId, post, public_moment, all, 0, MediaCounters]),
                            {ok, TimestampMs};
                        {ok, ExistingPost} ->
                            ?INFO("Uid: ~s PostId: ~s already published", [Uid, PostId]),
                            {ok, ExistingPost#post.ts_ms}
                    end,
                    broadcast_post(Uid, FilteredAudienceList2, HomeFeedSt, FinalTimestampMs),
                    {ok, FinalTimestampMs}
            end
    end;

publish_post(Uid, PostId, PayloadBase64, PostTag, PSATag, AudienceList, HomeFeedSt)
        when PSATag =:= undefined; PSATag =:= <<>> ->
    ?INFO("Uid: ~s, PostId: ~s", [Uid, PostId]),
    AppType = util_uid:get_app_type(Uid),
    Action = publish,
    FeedAudienceType = AudienceList#pb_audience.type,
    FilteredAudienceList1 = case AppType of
        halloapp -> AudienceList#pb_audience.uids;
        katchup -> model_follow:get_all_followers(Uid)
    end,
    case AppType =:= halloapp orelse PostTag =:= moment of
        false ->
            ?ERROR("Uid: ~p AppType: ~p PostTag: ~p not_supported", [Uid, AppType, PostTag]),
            {error, not_supported};
        true ->
            MediaCounters = HomeFeedSt#pb_feed_item.item#pb_post.media_counters,
            MomentInfo = HomeFeedSt#pb_feed_item.item#pb_post.moment_info,
            %% Store only the audience to be broadcasted to.
            FilteredAudienceList2 = sets:to_list(get_feed_audience_set(Action, Uid, FilteredAudienceList1)),
            {ok, FinalTimestampMs} = case model_feed:get_post(PostId) of
                {error, missing} ->
                    TimestampMs = util:now_ms(),
                    FeedAudienceSize = length(FilteredAudienceList2),
                    ?INFO("Uid: ~s PostId ~p published to ~p audience size: ~p",
                        [Uid, PostId, FeedAudienceType, FeedAudienceSize]),
                    case PostTag of
                        moment ->
                            ok = model_feed:publish_moment(PostId, Uid, PayloadBase64, PostTag,
                                    FeedAudienceType, FilteredAudienceList2, TimestampMs, MomentInfo);
                        _ ->
                            ok = model_feed:publish_post(PostId, Uid, PayloadBase64, PostTag,
                                    FeedAudienceType, FilteredAudienceList2, TimestampMs)
                    end,
                    ejabberd_hooks:run(feed_item_published, AppType,
                        [Uid, Uid, PostId, post, PostTag, FeedAudienceType, FeedAudienceSize, MediaCounters]),
                    {ok, TimestampMs};
                {ok, ExistingPost} ->
                    ?INFO("Uid: ~s PostId: ~s already published", [Uid, PostId]),
                    {ok, ExistingPost#post.ts_ms}
            end,
            broadcast_post(Uid, FilteredAudienceList2, HomeFeedSt, FinalTimestampMs),
            {ok, FinalTimestampMs}
    end;
publish_post(Uid, PostId, PayloadBase64, PostTag, PSATag, _AudienceList, HomeFeedSt) ->
    ?INFO("Uid: ~s, PostId: ~s, PSATag: ~p", [Uid, PostId, PSATag]),
    case is_psa_tag_allowed(PSATag, Uid) of
        false ->
            ?ERROR("PSA Tag not allowed: ~p, Uid: ~s", [PSATag, Uid]),
            {error, not_allowed};
        true -> publish_psa_post(Uid, PostId, PayloadBase64, PostTag, PSATag, HomeFeedSt)
    end.

publish_psa_post(Uid, PostId, PayloadBase64, PostTag, PSATag, HomeFeedSt) ->
    AppType = util_uid:get_app_type(Uid),
    MediaCounters = HomeFeedSt#pb_feed_item.item#pb_post.media_counters,
    {ok, FinalTimestampMs} = case model_feed:get_post(PostId) of
        {error, missing} ->
            TimestampMs = util:now_ms(),
            ?INFO("Uid: ~s PostId ~p published PSA Post to ~p", [Uid, PostId, PSATag]),
            ok = model_feed:publish_psa_post(PostId, Uid, PayloadBase64, PostTag, PSATag, TimestampMs),
            ejabberd_hooks:run(feed_item_published, AppType, [Uid, Uid, PostId, post, PostTag, all, -1, MediaCounters]),
            {ok, TimestampMs};
        {ok, ExistingPost} ->
            ?INFO("Uid: ~s PostId: ~s already published", [Uid, PostId]),
            {ok, ExistingPost#post.ts_ms}
    end,
    {ok, FinalTimestampMs}.


broadcast_post(Uid, FeedAudienceList, HomeFeedSt, TimestampMs) ->
    PublisherUid = Uid,
    PublisherName = model_accounts:get_name_binary(Uid),
    PublisherUsername = model_accounts:get_username_binary(Uid),
    FeedAudienceSet = sets:from_list(FeedAudienceList),
    BroadcastUids = sets:to_list(sets:del_element(Uid, FeedAudienceSet)),
    PushSet = FeedAudienceSet,
    StateBundles = HomeFeedSt#pb_feed_item.sender_state_bundles,
    StateBundlesMap = case StateBundles of
        undefined -> #{};
        _ -> lists:foldl(
                 fun(StateBundle, Acc) ->
                     Uid2 = StateBundle#pb_sender_state_bundle.uid,
                     SenderState = StateBundle#pb_sender_state_bundle.sender_state,
                     Acc#{Uid2 => SenderState}
                 end, #{}, StateBundles)
    end,
    lists:foreach(
        fun(ToUid) ->
            ResultStanza = update_feed_post_st(PublisherUid, PublisherName, PublisherUsername, HomeFeedSt, ToUid, TimestampMs),
            MsgType = get_message_type(ResultStanza, PushSet, ToUid),
            SenderState = maps:get(ToUid, StateBundlesMap, undefined),
            ResultStanza2 = ResultStanza#pb_feed_item{
                sender_state = SenderState
            },
            Packet = #pb_msg{
                id = util_id:new_msg_id(),
                to_uid = ToUid,
                from_uid = Uid,
                type = MsgType,
                payload = ResultStanza2
            },
            ejabberd_router:route(Packet)
        end, BroadcastUids),
    ok.


-spec publish_comment(Uid :: uid(), CommentId :: binary(), PostId :: binary(),
        ParentCommentId :: binary(), PayloadBase64 :: binary(),
        HomeFeedSt :: any()) -> {ok, integer()} | {error, any()}.
publish_comment(PublisherUid, CommentId, PostId, ParentCommentId, PayloadBase64, HomeFeedSt) ->
    ?INFO("Uid: ~s, CommentId: ~s, PostId: ~s", [PublisherUid, CommentId, PostId]),
    AppType = util_uid:get_app_type(PublisherUid),
    Action = publish,
    MediaCounters = HomeFeedSt#pb_feed_item.item#pb_comment.media_counters,
    CommentType = HomeFeedSt#pb_feed_item.item#pb_comment.comment_type,
    case model_feed:get_comment_data(PostId, CommentId, ParentCommentId) of
        {{error, missing}, _, _} ->
            {error, invalid_post_id};
        {{ok, Post}, {ok, Comment}, {ok, ParentPushList}} ->
            %% Comment with same id already exists: duplicate request from the client.
            ?INFO("Uid: ~s PostId: ~s CommentId: ~s already published", [PublisherUid, PostId, CommentId]),
            TimestampMs = Comment#comment.ts_ms,
            PostOwnerUid = Post#post.uid,
            FeedAudienceSet = get_feed_audience_set(Action, PostOwnerUid, Post#post.audience_list),
            PublicUpdateFeedAudienceSet = sets:from_list(Post#post.subscribed_audience_list),
            NewPushList = [PostOwnerUid, PublisherUid | ParentPushList],
            broadcast_comment(Action, CommentId, PostId, ParentCommentId, PublisherUid, HomeFeedSt,
                TimestampMs, FeedAudienceSet, NewPushList),
            broadcast_comment(public_update_publish, CommentId, PostId, ParentCommentId, PublisherUid, HomeFeedSt,
                TimestampMs, PublicUpdateFeedAudienceSet, []),
            {ok, TimestampMs};
        {{ok, Post}, {error, _}, {ok, ParentPushList}} ->
            TimestampMs = util:now_ms(),
            PostOwnerUid = Post#post.uid,
            PostAudienceSet = sets:from_list(Post#post.audience_list),
            FeedAudienceSet = get_feed_audience_set(Action, PostOwnerUid, Post#post.audience_list),
            PublicUpdateFeedAudienceSet = sets:from_list(Post#post.subscribed_audience_list),
            IsPublisherInFinalAudienceSet = sets:is_element(PublisherUid, FeedAudienceSet),
            IsPublisherInPostAudienceSet = sets:is_element(PublisherUid, PostAudienceSet),
            IsPublicPost = Post#post.tag =:= public_moment orelse Post#post.tag =:= public_post,
            IsPostValid = Post#post.expired =:= false,

            if
                (IsPublicPost orelse IsPublisherInFinalAudienceSet) andalso IsPostValid ->
                    %% PublisherUid is allowed to comment since it is part of the final audience set.
                    %% It should be stored and broadcasted.
                    NewPushList = [PostOwnerUid, PublisherUid | ParentPushList],
                    ok = model_feed:publish_comment(CommentId, PostId, PublisherUid,
                            ParentCommentId, CommentType, PayloadBase64, TimestampMs),
                    ejabberd_hooks:run(feed_item_published, AppType,
                        [PublisherUid, PostOwnerUid, CommentId, CommentType, undefined,
                        Post#post.audience_type, sets:size(FeedAudienceSet), MediaCounters]),
                    broadcast_comment(Action, CommentId, PostId, ParentCommentId, PublisherUid, HomeFeedSt,
                        TimestampMs, FeedAudienceSet, NewPushList),
                    broadcast_comment(public_update_publish, CommentId, PostId, ParentCommentId, PublisherUid, HomeFeedSt,
                        TimestampMs, PublicUpdateFeedAudienceSet, []),
                    {ok, TimestampMs};

                IsPublisherInPostAudienceSet andalso IsPostValid ->
                    %% PublisherUid is not allowed to comment.
                    %% Post was shared with them, but not in the final audience set
                    %% They could be blocked, so silently ignore it.
                    {ok, TimestampMs};

                true ->
                    ?ERROR("Failed to post, PublisherUid: ~p, PostId: ~p, CommentId: ~p", [PublisherUid, PostId, CommentId]),
                    %% PublisherUid is not allowed to comment.
                    %% Post was not shared to them, so reject with an error.
                    %% Post has already expired.
                    {error, invalid_post_id}
            end
    end.


-spec broadcast_comment(atom(), binary(), binary(), binary(), uid(), pb_feed_item(), integer(), set(), list()) -> ok.
broadcast_comment(Action, CommentId, PostId, ParentCommentId, PublisherUid,
        HomeFeedSt, TimestampMs, FeedAudienceSet, NewPushList) ->
    HomeFeedSt2 = HomeFeedSt#pb_feed_item{
        action = Action
    },
    %% send a new api message to all the clients.
    ResultStanza = make_pb_feed_comment(Action, CommentId,
            PostId, ParentCommentId, PublisherUid, HomeFeedSt2, TimestampMs),
    PushSet = sets:from_list(NewPushList),
    broadcast_event(PublisherUid, FeedAudienceSet, PushSet, ResultStanza, []).


-spec retract_post(Uid :: uid(), PostId :: binary()) -> {ok, integer()} | {error, any()}.
retract_post(Uid, PostId) ->
    ?INFO("Uid: ~s, PostId: ~s", [Uid, PostId]),
    AppType = util_uid:get_app_type(Uid),
    Action = retract,
    case model_feed:get_post(PostId) of
        {error, missing} ->
            ?INFO("Accept retract for missing post: ~p", [PostId]),
            TimestampMs = util:now_ms(),
            {ok, TimestampMs};
        {ok, ExistingPost} ->
            case ExistingPost#post.uid =:= Uid of
                false -> {error, not_authorized};
                true ->
                    TimestampMs = util:now_ms(),
                    ok = model_feed:retract_post(PostId, Uid),

                    %% send a new api message to all the clients.
                    ResultStanza1 = make_pb_feed_post(Action, PostId, Uid, <<>>, <<>>, undefined, TimestampMs),
                    FeedAudienceSet = get_feed_audience_set(Action, Uid, ExistingPost#post.audience_list),
                    ResultStanza2 = make_pb_feed_post(public_update_retract, PostId, Uid, <<>>, <<>>, undefined, TimestampMs),
                    PublicUpdateFeedAudienceSet = sets:from_list(ExistingPost#post.subscribed_audience_list),

                    PushSet = sets:new(),
                    broadcast_event(Uid, FeedAudienceSet, PushSet, ResultStanza1, []),
                    broadcast_event(Uid, PublicUpdateFeedAudienceSet, PushSet, ResultStanza2, []),
                    ejabberd_hooks:run(feed_item_retracted, AppType, [Uid, PostId, post]),

                    {ok, TimestampMs}
            end
    end.


-spec retract_comment(Uid :: uid(), CommentId :: binary(),
        PostId :: binary(), HomeFeedSt :: pb_feed_item()) -> {ok, integer()} | {error, any()}.
retract_comment(PublisherUid, CommentId, PostId, HomeFeedSt) ->
    ?INFO("Uid: ~s, CommentId: ~s, PostId: ~s", [PublisherUid, CommentId, PostId]),
    AppType = util_uid:get_app_type(PublisherUid),
    Action = retract,
    case model_feed:get_comment_data(PostId, CommentId, undefined) of
        {{error, missing}, _, _} ->
            {error, invalid_post_id};
        {{ok, _Post}, {error, _}, _} ->
            {error, invalid_comment_id};
        {{ok, Post}, {ok, Comment}, _} ->
            TimestampMs = util:now_ms(),
            PostOwnerUid = Post#post.uid,
            ParentCommentId = Comment#comment.parent_id,
            PostAudienceSet = sets:from_list(Post#post.audience_list),
            FeedAudienceSet = get_feed_audience_set(Action, PostOwnerUid, Post#post.audience_list),
            PublicUpdateFeedAudienceSet = sets:from_list(Post#post.subscribed_audience_list),
            IsPublisherInFinalAudienceSet = sets:is_element(PublisherUid, FeedAudienceSet),
            IsPublisherInPostAudienceSet = sets:is_element(PublisherUid, PostAudienceSet),
            IsPublicPost = Post#post.tag =:= public_moment orelse Post#post.tag =:= public_post,

            case PublisherUid =:= Comment#comment.publisher_uid orelse
                    (AppType =:= katchup andalso Post#post.uid =:= PublisherUid) of
                false -> {error, not_authorized};
                true ->
                    if
                        IsPublicPost orelse IsPublisherInFinalAudienceSet orelse IsPublisherInPostAudienceSet ->
                            %% PublisherUid is allowed to retract comment since
                            %% it is part of the final audience set or part of the post audience set.
                            %% It should be removed from our db and broadcasted.
                            ok = model_feed:retract_comment(CommentId, PostId),

                            %% send a new api message to all the clients.
                            ResultStanza = make_pb_feed_comment(Action, CommentId, PostId,
                                    ParentCommentId, PublisherUid, HomeFeedSt, TimestampMs),
                            PushSet = sets:new(),
                            broadcast_event(PublisherUid, FeedAudienceSet, PushSet, ResultStanza, []),
                            %% send public update_retract as well.
                            %% send a new api message to all the clients.
                            ResultStanza2 = make_pb_feed_comment(public_update_retract, CommentId, PostId,
                                    ParentCommentId, PublisherUid, HomeFeedSt, TimestampMs),
                            broadcast_event(PublisherUid, PublicUpdateFeedAudienceSet, PushSet, ResultStanza2, []),
                            ejabberd_hooks:run(feed_item_retracted, AppType,[PublisherUid, CommentId, comment]),

                            {ok, TimestampMs};

                        true ->
                            %% PublisherUid must be never allowed to comment.
                            %% This should never occur.
                            ?ERROR("Invalid state: post_id: ~p, comment_id: ~p, publisher_uid: ~p",
                                    [PostId, CommentId, PublisherUid]),
                            {error, invalid_post_id}
                    end
            end
    end.


-spec process_share_posts(Uid :: uid(), Server :: binary(),
        SharePostSt :: pb_share_stanza()) -> pb_share_stanza().
process_share_posts(_Uid, _Server, SharePostSt) ->
    %% Disable sharing posts.
    %% clients dont know the relationship anymore,
    %% so server should decide whether to broadcast or not.
    Ouid = SharePostSt#pb_share_stanza.uid,
    % case model_friends:is_friend(Uid, Ouid) of
    %     true ->
    %         PostIds = [PostId || PostId <- SharePostSt#pb_share_stanza.post_ids],
    %         share_feed_items(Uid, Ouid, Server, PostIds);
    %     false -> ok
    % end,
    #pb_share_stanza{
        uid = Ouid,
        result = <<"ok">>
    }.


-spec make_pb_feed_post(Action :: action_type(), PostId :: binary(),
        Uid :: uid(), PayloadBase64 :: binary(), EncPayload :: binary(),
        FeedAudienceType :: maybe('pb_audience.Type'), TimestampMs :: integer()) -> pb_feed_item().
make_pb_feed_post(Action, PostId, Uid, PayloadBase64, EncPayload, FeedAudienceType, TimestampMs) ->
    PbAudience = case FeedAudienceType of
        undefined -> undefined;
        except -> #pb_audience{type = all}; %% Send all even in case of except
        _ -> #pb_audience{type = FeedAudienceType}  %% Send all or only for other cases.
    end,
    #pb_feed_item{
        action = Action,
        item = #pb_post{
            id = PostId,
            publisher_uid = Uid,
            payload = base64:decode(PayloadBase64),
            publisher_name = model_accounts:get_name_binary(Uid),
            publisher_username = model_accounts:get_username_binary(Uid),
            timestamp = util:ms_to_sec(TimestampMs),
            enc_payload = EncPayload,
            audience = PbAudience
    }}.


update_feed_post_st(PublisherUid, PublisherName, PublisherUsername, HomeFeedSt, ToUid, TimestampMs) ->
    Post = HomeFeedSt#pb_feed_item.item,
    FeedAudienceType = HomeFeedSt#pb_feed_item.item#pb_post.audience#pb_audience.type,
    PbAudience = case FeedAudienceType of
        undefined -> undefined;
        except -> #pb_audience{type = all}; %% Send all even in case of except
        _ -> #pb_audience{type = FeedAudienceType}  %% Send all or only for other cases.
    end,
    MomentUnlockUid = Post#pb_post.moment_unlock_uid,
    HomeFeedSt1 = case ToUid =:= PublisherUid orelse ToUid =:= MomentUnlockUid of
        true ->
            HomeFeedSt#pb_feed_item{
                item = Post#pb_post{
                    publisher_uid = PublisherUid,
                    publisher_name = PublisherName,
                    publisher_username = PublisherUsername,
                    timestamp = util:ms_to_sec(TimestampMs),
                    moment_unlock_uid = MomentUnlockUid,
                    audience = PbAudience,
                    show_post_share_screen = dev_users:is_dev_uid(PublisherUid)
                },
                sender_state_bundles = []
            };
        false ->
            HomeFeedSt#pb_feed_item{
                item = Post#pb_post{
                    publisher_uid = PublisherUid,
                    publisher_name = PublisherName,
                    publisher_username = PublisherUsername,
                    timestamp = util:ms_to_sec(TimestampMs),
                    moment_unlock_uid = undefined,
                    audience = PbAudience
                },
                sender_state_bundles = []
            }
    end,
    HomeFeedSt1.


-spec make_pb_feed_comment(Action :: action_type(), CommentId :: binary(),
        PostId :: binary(), ParentCommentId :: binary(), Uid :: uid(),
        HomeFeedSt :: pb_feed_item(), TimestampMs :: integer()) -> pb_feed_item().
make_pb_feed_comment(Action, CommentId, PostId, ParentCommentId, PublisherUid, HomeFeedSt, TimestampMs) ->
    Comment = HomeFeedSt#pb_feed_item.item,
    HomeFeedSt#pb_feed_item{
        action = Action,
        item = Comment#pb_comment{
            id = CommentId,
            post_id = PostId,
            parent_comment_id = ParentCommentId,
            publisher_uid = PublisherUid,
            publisher_name = model_accounts:get_name_binary(PublisherUid),
            publisher_username = model_accounts:get_username_binary(PublisherUid),
            timestamp = util:ms_to_sec(TimestampMs)
        }
    }.


-spec broadcast_event(Uid :: uid(), FeedAudienceSet :: set(),
        PushSet :: set(), ResultStanza :: pb_feed_item(),
        StateBundles :: maybe([pb_sender_state_bundle()])) -> ok.
broadcast_event(Uid, FeedAudienceSet, PushSet, ResultStanza, StateBundles) ->
    BroadcastUids = sets:to_list(sets:del_element(Uid, FeedAudienceSet)),
    StateBundlesMap = case StateBundles of
        undefined -> #{};
        _ -> lists:foldl(
                 fun(StateBundle, Acc) ->
                     Uid2 = StateBundle#pb_sender_state_bundle.uid,
                     SenderState = StateBundle#pb_sender_state_bundle.sender_state,
                     Acc#{Uid2 => SenderState}
                 end, #{}, StateBundles)
    end,
    lists:foreach(
        fun(ToUid) ->
            MsgType = get_message_type(ResultStanza, PushSet, ToUid),
            SenderState = maps:get(ToUid, StateBundlesMap, undefined),
            ResultStanza2 = ResultStanza#pb_feed_item{
                sender_state = SenderState
            },
            Packet = #pb_msg{
                id = util_id:new_msg_id(),
                to_uid = ToUid,
                from_uid = Uid,
                type = MsgType,
                payload = ResultStanza2
            },
            ejabberd_router:route(Packet)
        end, BroadcastUids),
    ok.


%% message_type is used in the push notifications module to
%% decide whether to send alert/silent pushes to ios devices.
%% This will improve over the next diffs:
%% For now: the logic is as follows:
%% publish-post: headline for everyone.
%% publish-comment: headline for parent_comment notifylist
%%   this list includes post-owner; normal for everyone else.
%% retract-anything: normal for all of them. No push is sent here.
-spec get_message_type(FeedStanza :: pb_feed_item(), PushSet :: set(),
        ToUid :: uid()) -> headline | normal.
get_message_type(#pb_feed_item{action = publish, item = #pb_post{}}, _, _) -> headline;
get_message_type(#pb_feed_item{action = publish, item = #pb_comment{}}, PushSet, Uid) ->
    case sets:is_element(Uid, PushSet) of
        true -> headline;
        false -> normal
    end;
get_message_type(#pb_feed_item{action = retract}, _, _) -> normal;
get_message_type(_, _, _) -> normal.


%% This function takes Uid, their GeoTag, timestamp of the request, cursor and limit.
%% returns the final list of moments ranked in a specific order.
%% tries to return atmost Limit number of posts.
get_ranked_public_moments(Uid, GeoTag, TimestampMs, Cursor, Limit, ShowDevContent, CursorReload) ->
    Time1 = util:now_ms(),
    {RankedMomentIds, _} = model_feed:get_ranked_feed(Uid),
    {_, CursorPostId, _} = model_feed:split_cursor(Cursor),
    Result = case util:index_of(CursorPostId, RankedMomentIds) of
        undefined ->
            SentMomentIds = [],
            %% Find the next set of content items to rank and get the updated cursor.
            {Moments, Cursor2, FofUidsWithScores} = get_moments_to_rank(Uid, GeoTag, RankedMomentIds, SentMomentIds, TimestampMs, Cursor, ?PUBLIC_FEED_LIMIT_FACTOR * Limit, ShowDevContent),
            %% Rank these moments.
            {NewRankedMoments, NewRankedMomentScoresMap} = rank_moments(Uid, GeoTag, Moments, FofUidsWithScores),
            %% Fetch their ids and store them in cache.
            NewRankedMomentIds = lists:map(fun(Moment) -> Moment#post.id end, NewRankedMoments),
            %% Prepend to existing ranked feed.
            ok = model_feed:prepend_ranked_feed(Uid, NewRankedMomentIds, NewRankedMomentScoresMap),
            {Cursor3, DisplayMoments, DisplayMomentScoresMap} = fetch_items_from_ranked_feed(Uid, Cursor2, Limit, ShowDevContent),
            %% Send updated cursor and moments.
            {CursorReload, Cursor3, DisplayMoments, DisplayMomentScoresMap};
        Index ->
            SentMomentIds = lists:sublist(RankedMomentIds, Index),
            RankedMoments = model_feed:get_posts(lists:nthtail(Index, RankedMomentIds)),
            case length(RankedMoments) >= Limit of
                true ->
                    {Cursor2, DisplayMoments, NewMomentScoresMap} = fetch_items_from_ranked_feed(Uid, Cursor, Limit, ShowDevContent),
                    {false, Cursor2, DisplayMoments, NewMomentScoresMap};
                false ->
                    case check_for_interesting_content(Uid, GeoTag, Cursor) of
                        true ->
                            get_ranked_public_moments(Uid, GeoTag, util:now_ms(), <<>>, Limit, ShowDevContent, true);
                        false ->
                            %% Find the next set of content items using the old cursor to rank and get the updated cursor.
                            {Moments, Cursor2, FofUidsWithScores} = get_moments_to_rank(Uid, GeoTag, [], SentMomentIds, TimestampMs, Cursor, ?PUBLIC_FEED_LIMIT_FACTOR * Limit, ShowDevContent),
                            %% Filter out SentMomentIds from the list to be ranked so far.
                            %% All of SentMomentIds may not be seen yet.
                            %% get_moments_to_rank - filters these sent moment ids from that list and returns the list of moments to rank.
                            %% Rank these moments.
                            {NewRankedMoments, NewRankedMomentScoresMap} = rank_moments(Uid, GeoTag, Moments, FofUidsWithScores),
                            %% Fetch their ids and store them in cache.
                            NewRankedMomentIds = lists:map(fun(Moment) -> Moment#post.id end, NewRankedMoments),
                            %% Append to existing ranked feed.
                            ok = model_feed:append_ranked_feed(Uid, NewRankedMomentIds, NewRankedMomentScoresMap),
                            {Cursor3, DisplayMoments, DisplayMomentScoresMap} = fetch_items_from_ranked_feed(Uid, Cursor2, Limit, ShowDevContent),
                            %% Send updated cursor and moments.
                            {CursorReload, Cursor3, DisplayMoments, DisplayMomentScoresMap}
                    end
            end
    end,
    %% TODO: might need to update cursor timestamp depending on cursor-reload.
    Time2 = util:now_ms(),
    {_, _, ResultDisplayMoments, _} = Result,
    ?INFO("Uid: ~p, Tag: ~p Total time taken is: ~p, NumMoments: ~p", [Uid, GeoTag, (Time2 - Time1), length(ResultDisplayMoments)]),
    Result.


get_moments_to_rank(Uid, GeoTag, CurrentMomentIdsToInclude, SentMomentIds, TimestampMs, Cursor, NumLimit, ShowDevContent) ->
    %% Fetch possible geo-tagged moment ids.
    GeoTaggedMomentIds = model_feed:get_public_moments(GeoTag, TimestampMs, Cursor, NumLimit),
    GeoTaggedMoments = model_feed:get_posts(GeoTaggedMomentIds),

    %% fetch fof content here.
    {FofCursorUidScoreBin, _FofCursorTimestampMsBin} = model_feed:get_fof_cursor_index(Cursor),
    {FofUidsWithScores, NewFofScoreCursor} = model_follow:get_fof(Uid, FofCursorUidScoreBin, NumLimit),
    FofUids = maps:keys(FofUidsWithScores),
    FofPosts = model_feed:get_latest_posts(FofUids),

    %% Fetch possible global moment ids.
    GlobalMomentIds = model_feed:get_public_moments(undefined, TimestampMs, Cursor, NumLimit),
    GlobalMoments = model_feed:get_posts(GlobalMomentIds),

    %% Fetch current ranked feed posts to include.
    CurrentRankedMoments = model_feed:get_posts(CurrentMomentIdsToInclude),

    %% Fetch last moments to update cursor.
    LastGeoTaggedMoment = case GeoTaggedMoments of
        [] -> undefined;
        _ -> lists:last(GeoTaggedMoments)
    end,
    LastGlobalMoment = case GlobalMoments of
        [] -> undefined;
        _ -> lists:last(GlobalMoments)
    end,

    MomentsToRank1 = filter_public_moments(Uid, FofPosts ++ GeoTaggedMoments ++ CurrentRankedMoments, SentMomentIds, ShowDevContent),
    {MomentsToRank3, Cursor3} = case length(MomentsToRank1) > NumLimit of
        true ->
            Cursor2 = model_feed:update_cursor_post_index(Cursor, LastGeoTaggedMoment, NewFofScoreCursor, undefined),
            {MomentsToRank1, Cursor2};
        false ->
            MomentsToRank2 = filter_public_moments(Uid, MomentsToRank1 ++ GlobalMoments, SentMomentIds, ShowDevContent),
            Cursor2 = model_feed:update_cursor_post_index(Cursor, LastGeoTaggedMoment, NewFofScoreCursor, LastGlobalMoment),
            {MomentsToRank2, Cursor2}
    end,
    ?INFO("Uid: ~p, NumMoments: ~p Updated Cursor: ~p", [Uid, length(MomentsToRank3), Cursor3]),
    %% Include geotagged, global and given current moment ids as well.
    {MomentsToRank3, Cursor3, FofUidsWithScores}.


rank_moments(Uid, GeoTag, Moments, FofUidsWithScores) ->
    %% Get campus author set
    AuthorUids = lists:map(fun(PublicMoment) -> PublicMoment#post.uid end, Moments),
    AuthorUidsToGeoTagMap = model_accounts:get_latest_geo_tag(AuthorUids),

    %% Get timezones for users.
    OwnZoneOffsetHr = model_accounts:get_zone_offset_hr(Uid),
    OwnRegion = mod_moment_notification2:get_region_by_zone_offset_hr(OwnZoneOffsetHr),
    AuthorUidsToZoneOffsetHrMap = maps:from_list(lists:zip(AuthorUids, model_accounts:get_zone_offset_hr(AuthorUids))),

    %% Get num_mutual_following
    AuthorProfileMap = maps:from_list(lists:zip(AuthorUids, model_accounts:get_user_profiles(Uid, AuthorUids))),

    %% NumFollowing:
    NumFollowing = length(model_follow:get_all_following(Uid)),

    ?INFO("Uid: ~p, GeoTag: ~p, NumFollowing: ~p", [Uid, GeoTag, NumFollowing]),

    %% Score moments
    %% CampusTagScore * CampusScoreImportance + FollowingInterestScore * FollowingInterestImportance + RecencyScore * RecencyScoreImportance
    CurrentTimestampMs = util:now_ms(),
    MomentScoresMap = lists:foldl(
        fun(PublicMoment, AccMomentScoresMap) ->
            MomentId = PublicMoment#post.id,
            AuthorUid = PublicMoment#post.uid,
            CampusTagScore = case GeoTag =:= maps:get(AuthorUid, AuthorUidsToGeoTagMap, undefined) andalso GeoTag =/= undefined of
                true -> 1 * ?CAMPUS_SCORE_IMPORTANCE;
                false -> 0 * ?CAMPUS_SCORE_IMPORTANCE
            end,
            UserProfile = maps:get(AuthorUid, AuthorProfileMap, undefined),
            FollowingInterestScore = case UserProfile of
                undefined -> 0 * ?FOLLOWING_INTEREST_IMPORTANCE;
                #pb_user_profile{relevant_followers = RelevantFollowers} ->
                    case NumFollowing =:= 0 of
                        true -> 0 * ?FOLLOWING_INTEREST_IMPORTANCE;
                        false -> (length(RelevantFollowers) / NumFollowing) * ?FOLLOWING_INTEREST_IMPORTANCE
                    end
            end,
            RecencyScore = case CurrentTimestampMs - PublicMoment#post.ts_ms > ?HOURS_MS of
                true -> 0 * ?RECENCY_SCORE_IMPORTANCE;
                false -> 1 * ?RECENCY_SCORE_IMPORTANCE
            end,
            FofScore = maps:get(AuthorUid, FofUidsWithScores, 0) * ?FOF_SCORE_IMPORTANCE,
            AuthorZoneOffsetHr = maps:get(AuthorUid, AuthorUidsToZoneOffsetHrMap, undefined),
            AuthorRegion = mod_moment_notification2:get_region_by_zone_offset_hr(AuthorZoneOffsetHr),
            TimezoneScore = case OwnRegion =/= AuthorRegion andalso OwnRegion =/= undefined andalso AuthorRegion =/= undefined of
                true -> -1 * ?TIME_ZONE_IMPORTANCE;
                false -> 0 * ?TIME_ZONE_IMPORTANCE
            end,
            TotalScore = CampusTagScore +
                FollowingInterestScore +
                RecencyScore +
                FofScore +
                TimezoneScore,
            ?INFO("Uid: ~p, PostId: ~p, CampusTagScore: ~p, FollowingInterestScore: ~p, RecencyScore: ~p, FofScore: ~p, TimezoneScore: ~p, TotalScore: ~p",
                    [Uid, MomentId, CampusTagScore, FollowingInterestScore, RecencyScore, FofScore, TimezoneScore, TotalScore]),
            Explanation = "PostId: " ++ util:to_list(MomentId) ++ "; "
                ++ "Campus: " ++ util:to_list(CampusTagScore) ++ "; "
                ++ "FollowingInterest: " ++ util:to_list(FollowingInterestScore) ++ "; "
                ++ "Recency: " ++ util:to_list(RecencyScore) ++ "; "
                ++ "FofScore: " ++ util:to_list(FofScore) ++ "; "
                ++ "TimezoneScore: " ++ util:to_list(TimezoneScore) ++ "; "
                ++ "Total: " ++ util:to_list(TotalScore),
            AccMomentScoresMap#{MomentId => {TotalScore, util:to_binary(Explanation)}}

        end, #{}, Moments),
    %% These are now ranked based on campus tags, fof scores and receny scores.
    %% Will experiment these for a few days and then decide.

    RankedMoments = lists:sort(
            fun(PublicMoment1, PublicMoment2) ->
                %% This function returns if PublicMoment1 =< PublicMoment2
                %% Meaning if PublicMoment2 is more important than PublicMoment1

                MomentId1 = PublicMoment1#post.id,
                MomentId2 = PublicMoment2#post.id,
                {Score1, _} = maps:get(MomentId1, MomentScoresMap, {-1, <<"error getting score">>}),
                {Score2, _} = maps:get(MomentId2, MomentScoresMap, {-1, <<"error getting score">>}),
                TsMs1 = PublicMoment1#post.ts_ms,
                TsMs2 = PublicMoment2#post.ts_ms,

                %% We use timestamp here to break ties.
                case Score1 =:= Score2 of
                    true -> TsMs1 > TsMs2;
                    false ->
                        Score1 =< Score2
                end
            end, Moments),

    ?INFO("Uid: ~p, NumRankedMoments: ~p", [Uid, length(RankedMoments)]),
    {lists:reverse(RankedMoments), MomentScoresMap}.


-spec check_for_interesting_content(Uid :: uid(), GeoTag :: binary(), Cursor :: binary()) -> boolean().
check_for_interesting_content(Uid, GeoTag, _Cursor) ->
    %% Fetch latest content.
    LatestGeoTagMomentIds = model_feed:get_public_moments(GeoTag, util:now_ms(), <<>>, ?NUM_PUBLIC_FEED_ITEMS_PER_REQUEST),
    LatestGlobalMomentIds = model_feed:get_public_moments(undefined, util:now_ms(), <<>>, ?NUM_PUBLIC_FEED_ITEMS_PER_REQUEST),
    LatestPostIdSet = sets:from_list(LatestGeoTagMomentIds ++ LatestGlobalMomentIds),
    LatestPosts = model_feed:get_posts(sets:to_list(LatestPostIdSet)),
    FilteredLatestPosts = filter_public_moments(Uid, LatestPosts, [], false),
    FilteredLatestPostIdSet = sets:from_list(lists:map(fun(Post) -> Post#post.id end, FilteredLatestPosts)),

    {RankedMomentIds, _MomentScoresMap} = model_feed:get_ranked_feed(Uid),
    DiscoveredPostIdSet = sets:from_list(RankedMomentIds),
    %% Now - we check for any new content available and then return a boolean.
    Result = sets:size(sets:subtract(FilteredLatestPostIdSet, DiscoveredPostIdSet)) > 0,
    %% We could check for new content that is interesting to the user and only then return a boolean.
    ?INFO("Uid: ~p, GeoTag: ~p, Result: ~p", [Uid, GeoTag, Result]),
    Result.


%% Filters out content based on notification id, blocked/followed/dev users and also seen/sent-explored content.
%% sent content is the content that is currently on device already - we dont want to be re-fetching/re-ranking/resending them now.
filter_public_moments(Uid, Moments, SentMomentIds, ShowDevContent) ->
    SentMomentIdSet = sets:from_list(SentMomentIds),
    FilteredMoments1 = filter_reported_moments(Uid, filter_seen_moments(Uid, filter_moments_by_author(Uid, Moments, ShowDevContent))),
    FilteredMoments2 = lists:filter(fun(Moment) -> not sets:is_element(Moment#post.id, SentMomentIdSet) end, FilteredMoments1),
    FilteredMoments2.


filter_moments_by_author(Uid, Moments, ShowDevContent) ->
    LatestNotificationId = model_feed:get_notification_id(Uid),
    %% Filter out expired posts, old content, and posts from self, following, dev users, and blocked users
    RemoveAuthorSet = sets:from_list(model_follow:get_all_following(Uid)
        ++ [Uid]
        ++ model_follow:get_blocked_uids(Uid)
        ++ model_follow:get_blocked_by_uids(Uid)),
    Moments2 = lists:filter(
        fun
            (#post{expired = true} = _Moment) ->
                %% Filter out expired posts
                false;
            (#post{expired = false, uid = Ouid, moment_info = #pb_moment_info{notification_id = NotifId, content_type = ContentType}}) ->
                %% Ouid is ok if: not in RemoveAuthorSet AND allowed on public feed
                IsOuidOk = not sets:is_element(Ouid, RemoveAuthorSet)
                    andalso (ShowDevContent orelse dev_users:show_on_public_feed(Ouid)),
                IsNotifIdOk = LatestNotificationId >= NotifId,
                IsOuidOk andalso IsNotifIdOk;
            (_Else) ->
                false
        end,
        Moments),
    util:uniq(Moments2).


filter_seen_moments(Uid, Moments) ->
    %% Filter out seen posts.
    SeenPostIdSet = sets:from_list(model_feed:get_past_seen_posts(Uid)),
    Moments2 = lists:filter(fun(Moment) -> not sets:is_element(Moment#post.id, SeenPostIdSet) end, Moments),
    util:uniq(Moments2).


filter_reported_moments(Uid, Moments) ->
    %% Filter out reported posts.
    ReportedPostIdSet = sets:from_list(model_feed:get_past_reported_posts(Uid)),
    Moments2 = lists:filter(fun(Moment) -> not sets:is_element(Moment#post.id, ReportedPostIdSet) end, Moments),
    util:uniq(Moments2).


fetch_items_from_ranked_feed(Uid, Cursor, Limit, ShowDevContent) ->
    {_, CursorPostId, _} = model_feed:split_cursor(Cursor),
    {RankedMomentIds, MomentScoresMap} = model_feed:get_ranked_feed(Uid),
    DisplayMoments = case util:index_of(CursorPostId, RankedMomentIds) of
        undefined ->
            %% Send only some of them to the user.
            lists:sublist(model_feed:get_posts(RankedMomentIds), Limit);
        Index ->
            lists:sublist(model_feed:get_posts(lists:nthtail(Index, RankedMomentIds)), Limit)
    end,
    %% Make sure to filter out any content from newly followed users if any.
    DisplayMoments2 = filter_moments_by_author(Uid, DisplayMoments, ShowDevContent),
    NewCursorPostId = case DisplayMoments2 of
        [] -> CursorPostId;
        _ ->
            (lists:last(DisplayMoments))#post.id
    end,
    Cursor2 = model_feed:update_cursor_post_id(Cursor, NewCursorPostId),
    ?INFO("Uid: ~p, UpdatedCursor: ~p, NumMoments: ~p", [Uid, Cursor2, length(DisplayMoments2)]),
    {Cursor2, DisplayMoments2, MomentScoresMap}.


%%====================================================================
%% feed: helper internal functions
%%====================================================================


send_old_moment(FromUid, ToUid) ->
    ?INFO("send_old_moment of ~s, to ~s", [FromUid, ToUid]),
    AppType = util_uid:get_app_type(FromUid),
    {ok, FeedItems} = model_feed:get_7day_user_feed(FromUid),
    {LatestMoment, FilteredComments} = filter_latest_moment(ToUid, FeedItems),
    case LatestMoment of
        undefined ->
            ?INFO("No valid moment to sent from ~s, to ~s", [FromUid, ToUid]);
        _ ->
            PostStanzas = lists:map(fun convert_posts_to_feed_items/1, [LatestMoment]),
            CommentStanzas = lists:map(fun convert_comments_to_feed_items/1, FilteredComments),

            %% Add the touid to the audience list so that they can comment on these posts.
            FilteredPostIds = [LatestMoment#post.id],
            ok = model_feed:add_uid_to_audience(ToUid, FilteredPostIds),
            ok = model_feed:unsubscribe_uid_to_post(ToUid, FilteredPostIds),

            ?INFO("sending FromUid: ~s ToUid: ~s ~p posts and ~p comments",
                [FromUid, ToUid, length(PostStanzas), length(CommentStanzas)]),
            ?INFO("sending FromUid: ~s ToUid: ~s posts: ~p",
                [FromUid, ToUid, FilteredPostIds]),

            ejabberd_hooks:run(feed_share_old_items, AppType,
                [FromUid, ToUid, length(PostStanzas), length(CommentStanzas)]),

            Packet = #pb_msg{
                id = util_id:new_msg_id(),
                to_uid = ToUid,
                type = normal,
                payload = #pb_feed_items{
                    uid = FromUid,
                    items = PostStanzas ++ CommentStanzas
                }
            },
            ejabberd_router:route(Packet),
            ok
    end.


send_all_old_moments_to_self(Uid) ->
    AppType = util_uid:get_app_type(Uid),
    case AppType of
        katchup ->
            ?INFO("send_all_old_moments_to_self of ~s, to ~s", [Uid, Uid]),
            {ok, FeedItems} = model_feed:get_entire_user_feed(Uid),
            {Posts, Comments} = lists:partition(fun(Item) -> is_record(Item, post) end, FeedItems),
            case Posts of
                [] ->
                    ?INFO("No valid moment to sent from ~s, to ~s", [Uid, Uid]);
                _ ->
                    PostStanzas = lists:map(fun convert_posts_to_feed_items/1, Posts),
                    CommentStanzas = lists:map(fun convert_comments_to_feed_items/1, Comments),

                    ?INFO("Sending FromUid: ~s ToUid: ~s ~p posts and ~p comments",
                        [Uid, Uid, length(PostStanzas), length(CommentStanzas)]),

                    ejabberd_hooks:run(feed_share_old_items, AppType,
                        [Uid, Uid, length(PostStanzas), length(CommentStanzas)]),

                    Packet = #pb_msg{
                        id = util_id:new_msg_id(),
                        to_uid = Uid,
                        type = normal,
                        payload = #pb_feed_items{
                            uid = Uid,
                            items = PostStanzas ++ CommentStanzas
                        }
                    },
                    ejabberd_router:route(Packet),
                    ok
            end;
        _ ->
            ok
    end.


-spec send_old_items(FromUid :: uid(), ToUid :: uid(), Server :: binary()) -> ok.
send_old_items(FromUid, ToUid, _Server) ->
    ?INFO("sending old items of ~s, to ~s", [FromUid, ToUid]),
    AppType = util_uid:get_app_type(FromUid),
    {ok, FeedItems} = model_feed:get_7day_user_feed(FromUid),
    {FilteredPosts, FilteredComments} = filter_feed_items(ToUid, FeedItems),
    PostStanzas = lists:map(fun convert_posts_to_feed_items/1, FilteredPosts),
    CommentStanzas = lists:map(fun convert_comments_to_feed_items/1, FilteredComments),

    %% Add the touid to the audience list so that they can comment on these posts.
    FilteredPostIds = [P#post.id || P <- FilteredPosts],
    ok = model_feed:add_uid_to_audience(ToUid, FilteredPostIds),

    ?INFO("sending FromUid: ~s ToUid: ~s ~p posts and ~p comments",
        [FromUid, ToUid, length(PostStanzas), length(CommentStanzas)]),
    ?INFO("sending FromUid: ~s ToUid: ~s posts: ~p",
        [FromUid, ToUid, FilteredPostIds]),

    ejabberd_hooks:run(feed_share_old_items, AppType,
        [FromUid, ToUid, length(PostStanzas), length(CommentStanzas)]),

    case PostStanzas of
        [] -> ok;
        _ ->
            Packet = #pb_msg{
                id = util_id:new_msg_id(),
                to_uid = ToUid,
                type = normal,
                payload = #pb_feed_items{
                    uid = FromUid,
                    items = PostStanzas ++ CommentStanzas
                }
            },
            ejabberd_router:route(Packet),
            ok
    end.

% Uid is the user to which we want to send those posts.
% Posts should not be secret posts.
% They have to be either with audience_type all or the Uid has to be in the audience_list
-spec filter_feed_items(Uid :: uid(), Items :: [post()] | [comment()]) -> {[post()], [comment()]}.
filter_feed_items(Uid, Items) ->
    {Posts, Comments} = lists:partition(fun(Item) -> is_record(Item, post) end, Items),
    FilteredPosts = lists:filter(
            fun(Post) ->
                case {Post#post.audience_type, Post#post.tag} of
                    %% Dont resend moments to anyone including dev-users when resending history.
                    {_, moment} -> false;
                    {all, _} -> true;
                    {_, _} ->
                        lists:member(Uid, Post#post.audience_list)
                end
            end, Posts),
    FilteredPostIdsList = lists:map(fun(Post) -> Post#post.id end, FilteredPosts),
    FilteredPostIdsSet = sets:from_list(FilteredPostIdsList),
    FilteredComments = lists:filter(
            fun(Comment) ->
                sets:is_element(Comment#comment.post_id, FilteredPostIdsSet)
            end, Comments),
    {FilteredPosts, FilteredComments}.


-spec filter_latest_moment(Uid :: uid(), Items :: [post()] | [comment()]) -> {maybe(post()), [comment()]}.
filter_latest_moment(_Uid, Items) ->
    {Posts, Comments} = lists:partition(fun(Item) -> is_record(Item, post) end, Items),
    LatestMoment = lists:foldl(
            fun(Post, Acc) ->
                case Post#post.tag =:= moment orelse Post#post.tag =:= public_moment of
                    false -> Acc;
                    true ->
                        TsMs = Post#post.ts_ms,
                        case Acc =/= undefined of
                            true ->
                                case Acc#post.ts_ms < TsMs of
                                    true -> Post;
                                    false -> Acc
                                end;
                            false ->
                                Post
                        end
                end
            end, undefined, Posts),
    %% Dont send expired moments.
    case LatestMoment =/= undefined andalso LatestMoment#post.expired =:= false of
        false -> {undefined, []};
        true ->
            FilteredComments = lists:filter(
                fun(Comment) -> Comment#comment.post_id =:= LatestMoment#post.id end, Comments),
            {LatestMoment, FilteredComments}
    end.


%% TODO(murali@): Check if post-ids are related to this user only.
-spec share_feed_items(Uid :: uid(), FriendUid :: uid(),
        Server :: binary(), PostIds :: [binary()]) -> ok.
share_feed_items(Uid, FriendUid, _Server, PostIds) ->
    ?INFO("Uid: ~s, FriendUid: ~s, post_ids: ~p", [Uid, FriendUid, PostIds]),
    ok = model_feed:add_uid_to_audience(FriendUid, PostIds),
    {Posts, Comments} = get_posts_and_comments(PostIds),
    {FilteredPosts, FilteredComments} = filter_feed_items(FriendUid, Posts ++ Comments),
    PostStanzas = lists:map(fun convert_posts_to_feed_items/1, FilteredPosts),
    CommentStanzas = lists:map(fun convert_comments_to_feed_items/1, FilteredComments),

    MsgType = normal,
    Packet = #pb_msg{
        id = util_id:new_msg_id(),
        to_uid = FriendUid,
        type = MsgType,
        payload = #pb_feed_items{
            uid = Uid,
            items = PostStanzas ++ CommentStanzas
        }
    },
    ejabberd_router:route(Packet),
    ok.


-spec get_posts_and_comments(PostIds :: [binary()]) -> {any(), any()}.
get_posts_and_comments(PostIds) ->
    {Posts, CommentsAcc} = lists:foldl(
        fun(PostId, {PostAcc, CommentAcc}) ->
            case model_feed:get_post_and_its_comments(PostId) of
                {ok, {Post, Comments}} ->
                    NewPostAcc = [Post | PostAcc],
                    NewCommentAcc = [Comments | CommentAcc],
                    {NewPostAcc, NewCommentAcc};
                {error, _} ->
                    ?ERROR("Post and comments are missing in redis, post_id: ~p", [PostId]),
                    {PostAcc, CommentAcc}
            end
        end, {[], []}, PostIds),
    {Posts, lists:flatten(CommentsAcc)}.


-spec get_feed_audience_set(Action :: event_type(), Uid :: uid(), AudienceList :: [uid()]) -> set().
get_feed_audience_set(Action, Uid, AudienceList) ->
    AppType = util_uid:get_app_type(Uid),
    case AppType of
        %% Katchup
        katchup ->
            BlockedUids = model_follow:get_blocked_uids(Uid),
            FollowerUids = model_follow:get_all_followers(Uid),
            AudienceSet = sets:from_list(AudienceList),

            %% Union the audience-set with followers.
            %% There could be other uids here due to public feed subscription etc.
            %% So we include all uids in the audience + followers - blocked uids (if necessary).
            NewAudienceSet = sets:union(AudienceSet, sets:from_list(FollowerUids)),
            FinalAudienceSet = case Action of
                publish -> sets:subtract(NewAudienceSet, sets:from_list(BlockedUids));
                retract -> NewAudienceSet
            end,
            sets:add_element(Uid, FinalAudienceSet);
        %% HalloApp
        halloapp ->
            {ok, BlockedUids} = model_privacy:get_blocked_uids2(Uid),
            {ok, FriendUids} = model_friends:get_friends(Uid),
            AudienceSet = sets:from_list(AudienceList),

            %% Intersect the audience-set with friends.
            %% post-owner's uid is already included in the audience,
            %% but it may be removed during intersection.
            NewAudienceSet = sets:intersection(AudienceSet, sets:from_list(FriendUids)),
            FinalAudienceSet = case Action of
                publish -> sets:subtract(NewAudienceSet, sets:from_list(BlockedUids));
                retract -> AudienceSet
            end,
            %% Always add Uid to the audience set.
            sets:add_element(Uid, FinalAudienceSet)
    end.


-spec convert_moments_to_public_feed_items(uid(), post(), map()) -> pb_public_feed_item().
convert_moments_to_public_feed_items(Uid, #post{id = PostId, uid = OUid, payload = PayloadBase64, ts_ms = TimestampMs, tag = PostTag, moment_info = MomentInfo} = Post, MomentScoresMap) ->
    UserProfile = model_accounts:get_basic_user_profiles(Uid, OUid),
    PbPost = #pb_post{
        id = PostId,
        publisher_uid = OUid,
        publisher_name = model_accounts:get_name_binary(OUid),
        publisher_username = model_accounts:get_username_binary(OUid),
        payload = base64:decode(PayloadBase64),
        timestamp = util:ms_to_sec(TimestampMs),
        moment_info = MomentInfo,
        tag = PostTag,
        is_expired = Post#post.expired
    },
    {ok, Comments} = model_feed:get_post_comments(PostId),
    PbComments = lists:map(fun convert_comments_to_pb_comments/1, Comments),
    {Score, Explanation} = maps:get(PostId, MomentScoresMap, {-1.0, <<"error getting score">>}),
    PublicFeedItem = #pb_public_feed_item{
        user_profile = UserProfile,
        post = PbPost,
        comments = PbComments,
        reason = unknown_reason %% Setting unknown for all content right now -- but need to update.
    },
    case dev_users:is_dev_uid(Uid) of
        true -> PublicFeedItem#pb_public_feed_item{
            score = #pb_server_score{score = round(Score * 1000), explanation = Explanation, dscore = Score}};
        false -> PublicFeedItem
    end.


-spec convert_posts_to_feed_items(post()) -> pb_feed_item().
convert_posts_to_feed_items(#post{id = PostId, uid = Uid, payload = PayloadBase64, ts_ms = TimestampMs, tag = PostTag, moment_info = MomentInfo} = Post) ->
    PbPost = #pb_post{
        id = PostId,
        publisher_uid = Uid,
        publisher_name = model_accounts:get_name_binary(Uid),
        publisher_username = model_accounts:get_username_binary(Uid),
        payload = base64:decode(PayloadBase64),
        timestamp = util:ms_to_sec(TimestampMs),
        moment_info = MomentInfo,
        tag = PostTag,
        is_expired = Post#post.expired
    },
    #pb_feed_item{
        action = share,
        item = PbPost
    }.

-spec convert_comments_to_feed_items(comment()) -> pb_feed_item().
convert_comments_to_feed_items(#comment{} = Comment) ->
    convert_comments_to_feed_items(Comment, share).


convert_comments_to_feed_items(#comment{id = CommentId, post_id = PostId, publisher_uid = PublisherUid,
        parent_id = ParentId, payload = PayloadBase64, ts_ms = TimestampMs, comment_type = CommentType}, ActionType) ->
    Comment = #pb_comment{
        id = CommentId,
        post_id = PostId,
        publisher_uid = PublisherUid,
        publisher_name = model_accounts:get_name_binary(PublisherUid),
        publisher_username = model_accounts:get_username_binary(PublisherUid),
        parent_comment_id = ParentId,
        payload = base64:decode(PayloadBase64),
        timestamp = util:ms_to_sec(TimestampMs),
        comment_type = CommentType
    },
    #pb_feed_item{
        action = ActionType,
        item = Comment
    }.


convert_comments_to_pb_comments(#comment{id = CommentId, post_id = PostId, publisher_uid = PublisherUid,
        parent_id = ParentId, payload = PayloadBase64, ts_ms = TimestampMs, comment_type = CommentType}) ->
    #pb_comment{
        id = CommentId,
        post_id = PostId,
        publisher_uid = PublisherUid,
        publisher_name = model_accounts:get_name_binary(PublisherUid),
        publisher_username = model_accounts:get_username_binary(PublisherUid),
        parent_comment_id = ParentId,
        payload = base64:decode(PayloadBase64),
        timestamp = util:ms_to_sec(TimestampMs),
        comment_type = CommentType
    }.


%% Temp function to clean up expiry notices.
check_users(Uids, OldNotificationId) ->
    lists:foreach(
        fun(Uid) ->
            case model_feed:get_user_latest_post(Uid) of
                undefined -> ok;
                Post ->
                    %% Send expiry notice only if the latest post was the previous days post.
                    case Post#post.moment_info of
                        undefined ->
                            ok;
                        MomentInfo ->
                            case MomentInfo#pb_moment_info.notification_id =:= OldNotificationId of
                                true -> send_expiry_notice(Post);
                                false -> ok
                            end
                    end
            end
        end, Uids),
    ok.

