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

-define(NS_FEED, <<"halloapp:feed">>).

%% gen_mod API.
-export([start/2, stop/1, reload/3, mod_options/1, depends/2]).

%% Hooks and API.
-export([
    user_send_packet/1,
    process_local_iq/1,
    add_friend/4,
    remove_user/2,
    is_secret_post_allowed/1
]).


start(Host, _Opts) ->
    gen_iq_handler:add_iq_handler(ejabberd_local, Host, pb_feed_item, ?MODULE, process_local_iq),
    ejabberd_hooks:add(add_friend, Host, ?MODULE, add_friend, 50),
    ejabberd_hooks:add(remove_user, Host, ?MODULE, remove_user, 50),
    ejabberd_hooks:add(user_send_packet, Host, ?MODULE, user_send_packet, 50),
    ok.

stop(Host) ->
    gen_iq_handler:remove_iq_handler(ejabberd_local, Host, pb_feed_item),
    ejabberd_hooks:delete(add_friend, Host, ?MODULE, add_friend, 50),
    ejabberd_hooks:delete(remove_user, Host, ?MODULE, remove_user, 50),
    ejabberd_hooks:delete(user_send_packet, Host, ?MODULE, user_send_packet, 50),
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
        payload = #pb_feed_item{}} = Packet, State} = _Acc) ->
    PayloadType = util:get_payload_type(Packet),
    ?INFO("Uid: ~s sending ~p message to ~s MsgId: ~s", [FromUid, PayloadType, ToUid, MsgId]),
    Packet1 = set_sender_info(Packet),
    {Packet1, State};

user_send_packet({#pb_msg{id = MsgId, to_uid = ToUid, from_uid = FromUid,
        payload = #pb_feed_items{}} = Packet, State} = _Acc) ->
    PayloadType = util:get_payload_type(Packet),
    ?INFO("Uid: ~s sending ~p message to ~s MsgId: ~s", [FromUid, PayloadType, ToUid, MsgId]),
    Packet1 = set_sender_info(Packet),
    {Packet1, State};

user_send_packet({_Packet, _State} = Acc) ->
    Acc.

%% Publish post.
process_local_iq(#pb_iq{from_uid = Uid, type = set,
        payload = #pb_feed_item{action = publish = Action, item = #pb_post{} = Post} = HomeFeedSt} = IQ) ->
    PostId = Post#pb_post.id,
    PayloadBase64 = base64:encode(Post#pb_post.payload),
    PostTag = Post#pb_post.tag,
    AudienceList = Post#pb_post.audience,
    case publish_post(Uid, PostId, PayloadBase64, PostTag, AudienceList, HomeFeedSt) of
        {ok, ResultTsMs} ->
            FeedAudienceType = AudienceList#pb_audience.type,
            SubEl = make_pb_feed_post(Action, PostId, Uid, <<>>, <<>>, FeedAudienceType, ResultTsMs),
            pb:make_iq_result(IQ, SubEl);
        {error, Reason} ->
            pb:make_error(IQ, util:err(Reason))
    end;

%% Publish comment.
process_local_iq(#pb_iq{from_uid = Uid, type = set,
        payload = #pb_feed_item{action = publish = Action, item = #pb_comment{} = Comment}} = IQ) ->
    CommentId = Comment#pb_comment.id,
    PostId = Comment#pb_comment.post_id,
    ParentCommentId = Comment#pb_comment.parent_comment_id,
    PayloadBase64 = base64:encode(Comment#pb_comment.payload),
    EncPayload = Comment#pb_comment.enc_payload,
    MediaCounters = Comment#pb_comment.media_counters,
    case publish_comment(Uid, CommentId, PostId, ParentCommentId,
            PayloadBase64, EncPayload, MediaCounters) of
        {ok, ResultTsMs} ->
            SubEl = make_pb_feed_comment(Action, CommentId, PostId,
                    ParentCommentId, Uid, <<>>, <<>>, ResultTsMs),
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
        payload = #pb_feed_item{action = retract = Action, item = #pb_comment{} = Comment}} = IQ) ->
    CommentId = Comment#pb_comment.id,
    PostId = Comment#pb_comment.post_id,
    ParentCommentId = Comment#pb_comment.parent_comment_id,
    case retract_comment(Uid, CommentId, PostId) of
        {ok, ResultTsMs} ->
            SubEl = make_pb_feed_comment(Action, CommentId, PostId,
                    ParentCommentId, Uid, <<>>, <<>>, ResultTsMs),
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
    pb:make_iq_result(IQ, #pb_feed_item{action = Action, share_stanzas = ResultSharePostStanzas}).


-spec add_friend(Uid :: uid(), Server :: binary(), Ouid :: uid(), WasBlocked :: boolean()) -> ok.
add_friend(Uid, Server, Ouid, false) ->
    ?INFO("Uid: ~s, Ouid: ~s", [Uid, Ouid]),
    % Posts from Uid to Ouid
    send_old_items(Uid, Ouid, Server),
    % Posts from Ouid to Uid
    send_old_items(Ouid, Uid, Server),
    ok;
add_friend(_Uid, _Server, _Ouid, true) ->
    ok.


-spec remove_user(Uid :: uid(), Server :: binary()) -> ok.
remove_user(Uid, _Server) ->
    ok = model_feed:remove_user(Uid),
    ok.


-spec is_secret_post_allowed({Uid :: uid(), Phone :: binary()}) -> boolean().
is_secret_post_allowed({Uid, Phone}) ->
    case dev_users:is_dev_uid(Uid) of
        true -> true;
        false -> mod_libphonenumber:get_cc(Phone) =:= <<"SR">>
    end;
is_secret_post_allowed(Uid) ->
    {ok, Phone} = model_accounts:get_phone(Uid),
    is_secret_post_allowed({Uid, Phone}).


%%====================================================================
%% Internal functions
%%====================================================================

-spec set_sender_info(Message :: pb_msg()) -> pb_msg().
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
        AudienceListStanza ::[pb_audience()], HomeFeedSt :: pb_feed_item()) -> {ok, integer()} | {error, any()}.
publish_post(_Uid, _PostId, _PayloadBase64, _PostTag, undefined, _HomeFeedSt) ->
    {error, no_audience};
publish_post(Uid, PostId, PayloadBase64, PostTag, AudienceList, HomeFeedSt) ->
    ?INFO("Uid: ~s, PostId: ~s", [Uid, PostId]),
    Server = util:get_host(),
    Action = publish,
    FeedAudienceType = AudienceList#pb_audience.type,
    %% Filter audience in case of secret-posts - broadcast only to dev_users.
    %% -or-
    %% countries where we rolled out the feature
    FilteredAudienceList1 = filter_audience_by_tag(PostTag, AudienceList),
    MediaCounters = HomeFeedSt#pb_feed_item.item#pb_post.media_counters,
    %% Store only the audience to be broadcasted to.
    FilteredAudienceList2 = sets:to_list(get_feed_audience_set(Action, Uid, FilteredAudienceList1)),
    {ok, FinalTimestampMs} = case model_feed:get_post(PostId) of
        {error, missing} ->
            TimestampMs = util:now_ms(),
            ?INFO("Uid: ~s PostId ~p published to ~p audience size: ~p",
                [Uid, PostId, FeedAudienceType, length(FilteredAudienceList2)]),
            ok = model_feed:publish_post(PostId, Uid, PayloadBase64, PostTag,
                    FeedAudienceType, FilteredAudienceList2, TimestampMs),
            ejabberd_hooks:run(feed_item_published, Server, [Uid, PostId, post, PostTag, FeedAudienceType, MediaCounters]),
            {ok, TimestampMs};
        {ok, ExistingPost} ->
            ?INFO("Uid: ~s PostId: ~s already published", [Uid, PostId]),
            {ok, ExistingPost#post.ts_ms}
    end,
    broadcast_post(Action, PostId, Uid, PayloadBase64, FinalTimestampMs, FilteredAudienceList2, FeedAudienceType, HomeFeedSt),
    {ok, FinalTimestampMs}.



broadcast_post(Action, PostId, Uid, PayloadBase64, TimestampMs, FeedAudienceList, FeedAudienceType, HomeFeedSt) ->
    %% send a new api message to all the clients.
    #pb_feed_item{item = #pb_post{} = Post} = HomeFeedSt,
    EncPayload = Post#pb_post.enc_payload,
    ResultStanza = make_pb_feed_post(Action, PostId, Uid, PayloadBase64, EncPayload, FeedAudienceType, TimestampMs),
    FeedAudienceSet = sets:from_list(FeedAudienceList),
    PushSet = FeedAudienceSet,
    broadcast_event(Uid, FeedAudienceSet, PushSet, ResultStanza,
        HomeFeedSt#pb_feed_item.sender_state_bundles).


-spec publish_comment(Uid :: uid(), CommentId :: binary(), PostId :: binary(),
        ParentCommentId :: binary(), PayloadBase64 :: binary(),
        EncPayload :: binary(), MediaCounters :: pb_media_counters()) -> {ok, integer()} | {error, any()}.
publish_comment(PublisherUid, CommentId, PostId, ParentCommentId, PayloadBase64, EncPayload, MediaCounters) ->
    ?INFO("Uid: ~s, CommentId: ~s, PostId: ~s", [PublisherUid, CommentId, PostId]),
    Server = util:get_host(),
    Action = publish,

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
            broadcast_comment(Action, CommentId, PostId, ParentCommentId,
                PublisherUid, PayloadBase64, EncPayload, TimestampMs, FeedAudienceSet, NewPushList),

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
                            ParentCommentId, PayloadBase64, TimestampMs),
                    ejabberd_hooks:run(feed_item_published, Server, [PublisherUid, CommentId,
                                       comment, undefined, Post#post.audience_type, MediaCounters]),
                    broadcast_comment(Action, CommentId, PostId, ParentCommentId,
                        PublisherUid, PayloadBase64, EncPayload, TimestampMs, FeedAudienceSet, NewPushList),
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


broadcast_comment(Action, CommentId, PostId, ParentCommentId, PublisherUid,
    PayloadBase64, EncPayload, TimestampMs, FeedAudienceSet, NewPushList) ->
    %% send a new api message to all the clients.
    ResultStanza = make_pb_feed_comment(Action, CommentId,
            PostId, ParentCommentId, PublisherUid, PayloadBase64, EncPayload, TimestampMs),
    PushSet = sets:from_list(NewPushList),
    broadcast_event(PublisherUid, FeedAudienceSet, PushSet, ResultStanza, []).


-spec retract_post(Uid :: uid(), PostId :: binary()) -> {ok, integer()} | {error, any()}.
retract_post(Uid, PostId) ->
    ?INFO("Uid: ~s, PostId: ~s", [Uid, PostId]),
    Server = util:get_host(),
    Action = retract,
    case model_feed:get_post(PostId) of
        {error, missing} ->
            {error, invalid_post_id};
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
                    ejabberd_hooks:run(feed_item_retracted, Server, [Uid, PostId, post]),

                    {ok, TimestampMs}
            end
    end.


-spec retract_comment(Uid :: uid(), CommentId :: binary(),
        PostId :: binary()) -> {ok, integer()} | {error, any()}.
retract_comment(PublisherUid, CommentId, PostId) ->
    ?INFO("Uid: ~s, CommentId: ~s, PostId: ~s", [PublisherUid, CommentId, PostId]),
    Server = util:get_host(),
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
                                    ParentCommentId, PublisherUid, <<>>, <<>>, TimestampMs),
                            PushSet = sets:new(),
                            broadcast_event(PublisherUid, FeedAudienceSet, PushSet, ResultStanza, []),
                            ejabberd_hooks:run(feed_item_retracted, Server,[PublisherUid, CommentId, comment]),

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
process_share_posts(Uid, Server, SharePostSt) ->
    %% clients dont know the relationship anymore,
    %% so server should decide whether to broadcast or not.
    Ouid = SharePostSt#pb_share_stanza.uid,
    case model_friends:is_friend(Uid, Ouid) of
        true ->
            PostIds = [PostId || PostId <- SharePostSt#pb_share_stanza.post_ids],
            share_feed_items(Uid, Ouid, Server, PostIds);
        false -> ok
    end,
    #pb_share_stanza{
        uid = Ouid,
        result = <<"ok">>
    }.


-spec make_pb_feed_post(Action :: action_type(), PostId :: binary(),
        Uid :: uid(), PayloadBase64 :: binary(), EncPayload :: binary(),
        FeedAudienceType :: 'pb_audience.Type', TimestampMs :: integer()) -> pb_feed_item().
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


-spec make_pb_feed_comment(Action :: action_type(), CommentId :: binary(),
        PostId :: binary(), ParentCommentId :: binary(), Uid :: uid(),
        PayloadBase64 :: binary(), EncPayload :: binary(),
        TimestampMs :: integer()) -> pb_feed_item().
make_pb_feed_comment(Action, CommentId, PostId,
        ParentCommentId, PublisherUid, PayloadBase64, EncPayload, TimestampMs) ->
    #pb_feed_item{
        action = Action,
        item = #pb_comment{
            id = CommentId,
            post_id = PostId,
            parent_comment_id = ParentCommentId,
            publisher_uid = PublisherUid,
            publisher_name = model_accounts:get_name_binary(PublisherUid),
            payload = base64:decode(PayloadBase64),
            timestamp = util:ms_to_sec(TimestampMs),
            enc_payload = EncPayload
    }}.


-spec broadcast_event(Uid :: uid(), FeedAudienceSet :: set(),
        PushSet :: set(), ResultStanza :: pb_feed_item(),
        StateBundles :: [pb_sender_state_bundle()]) -> ok.
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


%%====================================================================
%% feed: helper internal functions
%%====================================================================


-spec filter_audience_by_tag(PostTag :: post_tag(), AudienceList :: [pb_audience()]) -> [uid()].
filter_audience_by_tag(_PostTag, #pb_audience{uids = undefined}) -> [];
filter_audience_by_tag(_PostTag, #pb_audience{uids = []}) -> [];
filter_audience_by_tag(PostTag, AudienceList) ->
    AudienceUids = AudienceList#pb_audience.uids,
    AudiencePhones = model_accounts:get_phones(AudienceUids),
    AudienceUidsAndPhones = lists:zip(AudienceUids, AudiencePhones),
    case PostTag =:= secret_post of
        true -> lists:filtermap(
                fun({Uid, Phone}) ->
                    case is_secret_post_allowed({Uid, Phone}) of
                        false -> false;
                        true -> {true, Uid}
                    end
                end, AudienceUidsAndPhones);
        false -> AudienceList#pb_audience.uids
    end.


-spec send_old_items(FromUid :: uid(), ToUid :: uid(), Server :: binary()) -> ok.
send_old_items(FromUid, ToUid, Server) ->
    ?INFO("sending old items of ~s, to ~s", [FromUid, ToUid]),

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

    ejabberd_hooks:run(feed_share_old_items, Server,
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
                    {_, secret_post} -> false;
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
    sets:add_element(Uid, FinalAudienceSet).


-spec convert_posts_to_feed_items(post()) -> pb_post().
convert_posts_to_feed_items(#post{id = PostId, uid = Uid, payload = PayloadBase64, ts_ms = TimestampMs}) ->
    Post = #pb_post{
        id = PostId,
        publisher_uid = Uid,
        publisher_name = model_accounts:get_name_binary(Uid),
        payload = base64:decode(PayloadBase64),
        timestamp = util:ms_to_sec(TimestampMs)
    },
    #pb_feed_item{
        action = share,
        item = Post
    }.

-spec convert_comments_to_feed_items(comment()) -> pb_comment().
convert_comments_to_feed_items(#comment{id = CommentId, post_id = PostId, publisher_uid = PublisherUid,
        parent_id = ParentId, payload = PayloadBase64, ts_ms = TimestampMs}) ->
    Comment = #pb_comment{
        id = CommentId,
        post_id = PostId,
        publisher_uid = PublisherUid,
        publisher_name = model_accounts:get_name_binary(PublisherUid),
        parent_comment_id = ParentId,
        payload = base64:decode(PayloadBase64),
        timestamp = util:ms_to_sec(TimestampMs)
    },
    #pb_feed_item{
        action = share,
        item = Comment
    }.

