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

-dialyzer({no_match, make_pb_feed_post/7}).
-dialyzer({no_match, broadcast_event/5}).

-define(NS_FEED, <<"halloapp:feed">>).

%% functions used in tests
-ifdef(TEST).
-export([
    get_public_moments/4
]).
-endif.

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
    send_moment_notification/1,
    new_follow_relationship/2
]).


start(_Host, _Opts) ->
    %% HalloApp
    gen_iq_handler:add_iq_handler(ejabberd_local, halloapp, pb_feed_item, ?MODULE, process_local_iq),
    ejabberd_hooks:add(add_friend, halloapp, ?MODULE, add_friend, 50),
    ejabberd_hooks:add(remove_user, halloapp, ?MODULE, remove_user, 50),
    ejabberd_hooks:add(user_send_packet, halloapp, ?MODULE, user_send_packet, 50),
    %% Katchup
    gen_iq_handler:add_iq_handler(ejabberd_local, katchup, pb_feed_item, ?MODULE, process_local_iq),
    ejabberd_hooks:add(add_friend, katchup, ?MODULE, add_friend, 50),
    ejabberd_hooks:add(remove_user, katchup, ?MODULE, remove_user, 50),
    ejabberd_hooks:add(user_send_packet, katchup, ?MODULE, user_send_packet, 50),
    ejabberd_hooks:add(send_moment_notification, katchup, ?MODULE, send_moment_notification, 50),
    ejabberd_hooks:add(new_follow_relationship, katchup, ?MODULE, new_follow_relationship, 50),
    ok.

stop(_Host) ->
    gen_iq_handler:remove_iq_handler(ejabberd_local, halloapp, pb_feed_item),
    ejabberd_hooks:delete(add_friend, halloapp, ?MODULE, add_friend, 50),
    ejabberd_hooks:delete(remove_user, halloapp, ?MODULE, remove_user, 50),
    ejabberd_hooks:delete(user_send_packet, halloapp, ?MODULE, user_send_packet, 50),
    %% Katchup
    gen_iq_handler:remove_iq_handler(ejabberd_local, katchup, pb_feed_item),
    ejabberd_hooks:delete(add_friend, katchup, ?MODULE, add_friend, 50),
    ejabberd_hooks:delete(remove_user, katchup, ?MODULE, remove_user, 50),
    ejabberd_hooks:delete(user_send_packet, katchup, ?MODULE, user_send_packet, 50),
    ejabberd_hooks:delete(send_moment_notification, katchup, ?MODULE, send_moment_notification, 50),
    ejabberd_hooks:add(new_follow_relationship, katchup, ?MODULE, new_follow_relationship, 50),
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

user_send_packet({_Packet, _State} = Acc) ->
    Acc.

%% Publish post.
process_local_iq(#pb_iq{from_uid = Uid, type = set,
        payload = #pb_feed_item{action = publish, item = #pb_post{} = Post} = HomeFeedSt} = IQ) ->
    PostId = Post#pb_post.id,
    PayloadBase64 = base64:encode(Post#pb_post.payload),
    PostTag = Post#pb_post.tag,
    AudienceList = Post#pb_post.audience,
    PSATag = Post#pb_post.psa_tag,
    PublisherName = model_accounts:get_name_binary(Uid),
    case publish_post(Uid, PostId, PayloadBase64, PostTag, PSATag, AudienceList, HomeFeedSt) of
        {ok, ResultTsMs} ->
            SubEl = update_feed_post_st(Uid, PublisherName, HomeFeedSt, Uid, ResultTsMs),
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
    public_feed_content_type = moments, gps_location = GpsLocation}} = IQ) ->
    ?INFO("Public feed request: Uid ~s, GpsLocation ~p, Cursor ~p", [Uid, GpsLocation, Cursor]),
    try
        %% Get geotag from GeoLocation, add it to user account if it exists
        NewTag = mod_location:get_geo_tag(Uid, GpsLocation),
        case NewTag of
            undefined -> ok;
            _ ->
                ?INFO("Adding new tag ~p for Uid ~s", [NewTag, Uid]),
                model_accounts:add_geo_tag(Uid, NewTag, util:now())
        end,
        %% Fetch latest geotag, public moments (convert them to pb feed items) and calculate cursor
        Tag = model_accounts:get_latest_geo_tag(Uid),
        PublicMoments = get_public_moments(Tag, util:now_ms(), Cursor, ?NUM_PUBLIC_FEED_ITEMS_PER_REQUEST),
        PublicFeedItems = lists:map(fun convert_posts_to_feed_items/1, PublicMoments),
        NewCursor = case PublicMoments of
            [] -> <<>>;
            _ ->
                PostId = (lists:last(PublicMoments))#post.id,
                PostTsMs = model_feed:get_post_timestamp_ms(PostId),
                model_feed:join_cursor(PostId, PostTsMs)
        end,
        Ret = #pb_public_feed_response{
            result = success,
            reason = ok,
            cursor = NewCursor,
            public_feed_content_type = moments,
            items = PublicFeedItems
        },
        ?INFO("Successful public feed response: Uid ~s, NewCursor ~p, Tag ~p NumItems ~p",
            [Uid, NewCursor, Tag, length(PublicFeedItems)]),
        pb:make_iq_result(IQ, Ret)
    catch
        error:invalid_cursor ->
            ErrRet = #pb_public_feed_response{
                result = failure,
                reason = invalid_cursor},
            pb:make_iq_result(IQ, ErrRet);
        Error:Reason ->
            ?ERROR("Error processing public feed request: ~p: ~p", [Error, Reason]),
            ErrRet = #pb_public_feed_response{
                result = failure,
                reason = unknown_reason},
            pb:make_iq_result(IQ, ErrRet)
    end;

process_local_iq(#pb_iq{payload = #pb_public_feed_request{public_feed_content_type = ContentType}} = IQ) ->
    %% Return error for content type other than moments
    Ret = #pb_public_feed_response{
        result = failure,
        reason = unknown_reason,
        cursor = <<>>,
        public_feed_content_type = ContentType,
        items = []
    },
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
    ok = model_feed:remove_user(Uid),
    ok.


%% we clear all old posts of this user from the server once we send a notification.
%% since this post is no longer valid from that user.
%% when a new user follows this user - they should no longer get old posts.
send_moment_notification(Uid) ->
    AppType = util_uid:get_app_type(Uid),
    case AppType of
        katchup -> model_feed:remove_all_user_posts(Uid);
        _ -> ok
    end,
    ?INFO("Uid: ~p, clearing all old posts for AppType: ~p", [Uid, AppType]),
    ok.


new_follow_relationship(Uid, Ouid) ->
    ?INFO("New follow relationship, send old moment fromUid: ~p, ToUid: ~p", [Ouid, Uid]),
    send_old_moment(Ouid, Uid),
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

-spec set_sender_info(Message :: message()) -> message().
set_sender_info(#pb_msg{id = MsgId, payload = #pb_feed_items{items = Items} = FeedItems} = Message) ->
    NewItems = [set_ts_and_publisher_name(MsgId, Item) || Item <- Items],
    NewFeedItems = FeedItems#pb_feed_items{
        items = NewItems
    },
    Message#pb_msg{payload = NewFeedItems};
    
set_sender_info(#pb_msg{id = MsgId, payload = #pb_feed_item{} = FeedItem} = Message) ->
    NewFeedItem = set_ts_and_publisher_name(MsgId, FeedItem),
    Message#pb_msg{payload = NewFeedItem}.

set_ts_and_publisher_name(MsgId, #pb_feed_item{item = Item} = FeedItem) ->
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
    {ok, SenderName} = model_accounts:get_name(PublisherUid),
    case Item of
        #pb_post{} -> 
            Item2 = Item#pb_post{
                timestamp = Timestamp,
                publisher_name = SenderName
            },
            FeedItem#pb_feed_item{
                item = Item2
            };
        #pb_comment{} ->
            Item2 = Item#pb_comment{
                timestamp = Timestamp,
                publisher_name = SenderName
            },
            FeedItem#pb_feed_item{
                item = Item2
            }
    end.


%% TODO(murali@): update payload to be protobuf binary without base64 encoded.

-spec publish_post(Uid :: uid(), PostId :: binary(), PayloadBase64 :: binary(), PostTag :: post_tag(),
        PSATag :: binary(), AudienceListStanza ::[pb_audience()], HomeFeedSt :: pb_feed_item()) -> {ok, integer()} | {error, any()}.
publish_post(_Uid, _PostId, _PayloadBase64, _PostTag, _PSATag, undefined, _HomeFeedSt) ->
    {error, no_audience};
publish_post(_Uid, _PostId, _PayloadBase64, public_post, _PSATag, _AudienceList, _HomeFeedSt) -> {error, not_supported};
publish_post(Uid, PostId, PayloadBase64, public_moment, PSATag, _AudienceList, HomeFeedSt)
        when PSATag =:= undefined; PSATag =:= <<>> ->
    ?INFO("Uid: ~s, public_moment PostId: ~s", [Uid, PostId]),
    AppType = util_uid:get_app_type(Uid),
    MediaCounters = HomeFeedSt#pb_feed_item.item#pb_post.media_counters,
    MomentInfo = HomeFeedSt#pb_feed_item.item#pb_post.moment_info,
    %% Store only the audience to be broadcasted to.
    {ok, FinalTimestampMs} = case model_feed:get_post(PostId) of
        {error, missing} ->
            TimestampMs = util:now_ms(),
            ?INFO("Uid: ~s PostId ~p published as public_moment: ~p", [Uid, PostId]),
            ok = model_feed:publish_moment(PostId, Uid, PayloadBase64, public_moment, all, [], TimestampMs, MomentInfo),
            ejabberd_hooks:run(feed_item_published, AppType,
                [Uid, Uid, PostId, post, public_moment, all, 0, MediaCounters]),
            {ok, TimestampMs};
        {ok, ExistingPost} ->
            ?INFO("Uid: ~s PostId: ~s already published", [Uid, PostId]),
            {ok, ExistingPost#post.ts_ms}
    end,
    {ok, FinalTimestampMs};
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
    {ok, FinalTimestampMs};
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
            ResultStanza = update_feed_post_st(PublisherUid, PublisherName, HomeFeedSt, ToUid, TimestampMs),
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
        HomeFeedSt :: pb_feed_item()) -> {ok, integer()} | {error, any()}.
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
            NewPushList = [PostOwnerUid, PublisherUid | ParentPushList],
            broadcast_comment(CommentId, PostId, ParentCommentId, PublisherUid, HomeFeedSt,
                TimestampMs, FeedAudienceSet, NewPushList),
            {ok, TimestampMs};
        {{ok, Post}, {error, _}, {ok, ParentPushList}} ->
            TimestampMs = util:now_ms(),
            PostOwnerUid = Post#post.uid,
            PostAudienceSet = sets:from_list(Post#post.audience_list),
            FeedAudienceSet = get_feed_audience_set(Action, PostOwnerUid, Post#post.audience_list),
            IsPublisherInFinalAudienceSet = sets:is_element(PublisherUid, FeedAudienceSet),
            IsPublisherInPostAudienceSet = sets:is_element(PublisherUid, PostAudienceSet),

            if
                IsPublisherInFinalAudienceSet ->
                    %% PublisherUid is allowed to comment since it is part of the final audience set.
                    %% It should be stored and broadcasted.
                    NewPushList = [PostOwnerUid, PublisherUid | ParentPushList],
                    ok = model_feed:publish_comment(CommentId, PostId, PublisherUid,
                            ParentCommentId, CommentType, PayloadBase64, TimestampMs),
                    ejabberd_hooks:run(feed_item_published, AppType,
                        [PublisherUid, PostOwnerUid, CommentId, CommentType, undefined,
                        Post#post.audience_type, sets:size(FeedAudienceSet), MediaCounters]),
                    broadcast_comment(CommentId, PostId, ParentCommentId, PublisherUid, HomeFeedSt,
                        TimestampMs, FeedAudienceSet, NewPushList),
                    {ok, TimestampMs};

                IsPublisherInPostAudienceSet ->
                    %% PublisherUid is not allowed to comment.
                    %% Post was shared with them, but not in the final audience set
                    %% They could be blocked, so silently ignore it.
                    {ok, TimestampMs};

                true ->
                    %% PublisherUid is not allowed to comment.
                    %% Post was not shared to them, so reject with an error.
                    {error, invalid_post_id}
            end
    end.



broadcast_comment(CommentId, PostId, ParentCommentId, PublisherUid,
        HomeFeedSt, TimestampMs, FeedAudienceSet, NewPushList) ->
    Action = HomeFeedSt#pb_feed_item.action,
    %% send a new api message to all the clients.
    ResultStanza = make_pb_feed_comment(Action, CommentId,
            PostId, ParentCommentId, PublisherUid, HomeFeedSt, TimestampMs),
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
                    ResultStanza = make_pb_feed_post(Action, PostId, Uid, <<>>, <<>>, undefined, TimestampMs),
                    FeedAudienceSet = get_feed_audience_set(Action, Uid, ExistingPost#post.audience_list),
                    PushSet = sets:new(),
                    broadcast_event(Uid, FeedAudienceSet, PushSet, ResultStanza, []),
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
            IsPublisherInFinalAudienceSet = sets:is_element(PublisherUid, FeedAudienceSet),
            IsPublisherInPostAudienceSet = sets:is_element(PublisherUid, PostAudienceSet),

            case PublisherUid =:= Comment#comment.publisher_uid of
                false -> {error, not_authorized};
                true ->
                    if
                        IsPublisherInFinalAudienceSet orelse IsPublisherInPostAudienceSet ->
                            %% PublisherUid is allowed to retract comment since
                            %% it is part of the final audience set or part of the post audience set.
                            %% It should be removed from our db and broadcasted.
                            ok = model_feed:retract_comment(CommentId, PostId),

                            %% send a new api message to all the clients.
                            ResultStanza = make_pb_feed_comment(Action, CommentId, PostId,
                                    ParentCommentId, PublisherUid, HomeFeedSt, TimestampMs),
                            PushSet = sets:new(),
                            broadcast_event(PublisherUid, FeedAudienceSet, PushSet, ResultStanza, []),
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
            timestamp = util:ms_to_sec(TimestampMs),
            enc_payload = EncPayload,
            audience = PbAudience
    }}.


update_feed_post_st(PublisherUid, PublisherName, HomeFeedSt, ToUid, TimestampMs) ->
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
get_message_type(#pb_feed_item{action = retract}, _, _) -> normal.


get_public_moments(Tag, TimestampMs, Cursor, Limit) ->
    get_public_moments(Tag, TimestampMs, Cursor, Limit, []).


get_public_moments(Tag, TimestampMs, Cursor, Limit, PublicMoments) ->
    case length(PublicMoments) >= Limit of
        true ->
            %% Base case: Limit has been reached
            lists:sublist(PublicMoments, Limit);
        false ->
            %% Fetch 20% more items than needed to account for possible deleted posts
            NumNeeded = Limit - length(PublicMoments),
            NumToFetch = round(NumNeeded * 1.2),
            NewPublicMomentIds = model_feed:get_public_moments(Tag, TimestampMs, Cursor, NumToFetch),
            %% Filter out deleted posts and convert PostIds to Posts
            NewPublicMoments = model_feed:get_posts(NewPublicMomentIds),
            case length(NewPublicMomentIds) < NumToFetch of
                true ->
                    %% If length(NewPublicMomentIds) is less than the number of items we tried to fetch,
                    %% we must have reached the end of the possible items, so we should return here
                    lists:sublist(PublicMoments ++ NewPublicMoments, Limit);
                false ->
                    %% Otherwise, recurse
                    PostTsMs = model_feed:get_post_timestamp_ms(lists:last(NewPublicMomentIds)),
                    NewCursor = model_feed:join_cursor(lists:last(NewPublicMomentIds), PostTsMs),
                    get_public_moments(Tag, TimestampMs, NewCursor,
                        Limit, PublicMoments ++ NewPublicMoments)
            end
    end.

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
                case Post#post.tag =:= moment of
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
    case LatestMoment of
        undefined -> {undefined, []};
        _ ->
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

            %% Intersect the audience-set with followers.
            %% post-owner's uid is already included in the audience,
            %% but it may be removed during intersection.
            NewAudienceSet = sets:intersection(AudienceSet, sets:from_list(FollowerUids)),
            FinalAudienceSet = case Action of
                publish -> sets:subtract(NewAudienceSet, sets:from_list(BlockedUids));
                retract -> AudienceSet
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


-spec convert_posts_to_feed_items(post()) -> pb_feed_item().
convert_posts_to_feed_items(#post{id = PostId, uid = Uid, payload = PayloadBase64, ts_ms = TimestampMs, tag = PostTag, moment_info = MomentInfo}) ->
    Post = #pb_post{
        id = PostId,
        publisher_uid = Uid,
        publisher_name = model_accounts:get_name_binary(Uid),
        payload = base64:decode(PayloadBase64),
        timestamp = util:ms_to_sec(TimestampMs),
        moment_info = MomentInfo,
        tag = PostTag
    },
    #pb_feed_item{
        action = share,
        item = Post
    }.

-spec convert_comments_to_feed_items(comment()) -> pb_feed_item().
convert_comments_to_feed_items(#comment{id = CommentId, post_id = PostId, publisher_uid = PublisherUid,
        parent_id = ParentId, payload = PayloadBase64, ts_ms = TimestampMs, comment_type = CommentType}) ->
    Comment = #pb_comment{
        id = CommentId,
        post_id = PostId,
        publisher_uid = PublisherUid,
        publisher_name = model_accounts:get_name_binary(PublisherUid),
        parent_comment_id = ParentId,
        payload = base64:decode(PayloadBase64),
        timestamp = util:ms_to_sec(TimestampMs),
        comment_type = CommentType
    },
    #pb_feed_item{
        action = share,
        item = Comment
    }.

