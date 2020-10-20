%%%-----------------------------------------------------------------------------------
%%% File    : mod_ha_feed.erl
%%%
%%% Copyright (C) 2020 halloappinc.
%%%
%%% TODO(murali@): Feed hooks do not contain payload since we dont need it for now.
%%%-----------------------------------------------------------------------------------

-module(mod_ha_feed).
-behaviour(gen_mod).
-author('murali').

-include("xmpp.hrl").
-include("translate.hrl").
-include("logger.hrl").
-include("feed.hrl").

-define(NS_FEED, <<"halloapp:feed">>).

%% gen_mod API.
-export([start/2, stop/1, reload/3, mod_options/1, depends/2]).

%% Hooks and API.
-export([
    process_local_iq/1,
    make_feed_post_stanza/5,
    make_feed_comment_stanza/8,
    broadcast_event/4,
    filter_feed_items/2,
    add_friend/3
]).


start(Host, _Opts) ->
    gen_iq_handler:add_iq_handler(ejabberd_local, Host, ?NS_FEED, ?MODULE, process_local_iq),
    ejabberd_hooks:add(add_friend, Host, ?MODULE, add_friend, 50),
    ok.

stop(Host) ->
    gen_iq_handler:remove_iq_handler(ejabberd_local, Host, ?NS_FEED),
    ejabberd_hooks:delete(add_friend, Host, ?MODULE, add_friend, 50),
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

%% Publish post.
process_local_iq(#iq{from = #jid{luser = Uid, lserver = _Server}, type = set,
        sub_els = [#feed_st{action = publish = Action, posts = [Post], comments = [],
        audience_list = AudienceListStanza}]} = IQ) ->
    PostId = Post#post_st.id,
    Payload = Post#post_st.payload,
    case publish_post(Uid, PostId, Payload, AudienceListStanza) of
        {ok, ResultTsMs} ->
            SubEl = make_feed_post_stanza(Action, PostId, Uid, <<>>, ResultTsMs),
            xmpp:make_iq_result(IQ, SubEl);
        {error, Reason} ->
            xmpp:make_error(IQ, util:err(Reason))
    end;

%% Publish comment.
process_local_iq(#iq{from = #jid{luser = Uid, lserver = _Server}, type = set,
        sub_els = [#feed_st{action = publish = Action, posts = [], comments = [Comment]}]} = IQ) ->
    CommentId = Comment#comment_st.id,
    PostId = Comment#comment_st.post_id,
    ParentCommentId = case Comment#comment_st.parent_comment_id of
        undefined -> <<>>;
        ParentId -> ParentId
    end,
    Payload = Comment#comment_st.payload,
    PostUid = Comment#comment_st.post_uid,
    case publish_comment(Uid, CommentId, PostId, PostUid, ParentCommentId, Payload) of
        {ok, ResultTsMs} ->
            SubEl = make_feed_comment_stanza(Action, CommentId, PostId, PostUid,
                    ParentCommentId, Uid, <<>>, ResultTsMs),
            xmpp:make_iq_result(IQ, SubEl);
        {error, Reason} ->
            xmpp:make_error(IQ, util:err(Reason))
    end;

% Retract post.
process_local_iq(#iq{from = #jid{luser = Uid, lserver = _Server}, type = set,
        sub_els = [#feed_st{action = retract = Action, posts = [Post], comments = []}]} = IQ) ->
    PostId = Post#post_st.id,
    case retract_post(Uid, PostId) of
        {ok, ResultTsMs} ->
            SubEl = make_feed_post_stanza(Action, PostId, Uid, <<>>, ResultTsMs),
            xmpp:make_iq_result(IQ, SubEl);
        {error, Reason} ->
            xmpp:make_error(IQ, util:err(Reason))
    end;

% Retract comment.
process_local_iq(#iq{from = #jid{luser = Uid, lserver = _Server}, type = set,
        sub_els = [#feed_st{action = retract = Action, posts = [], comments = [Comment]}]} = IQ) ->
    CommentId = Comment#comment_st.id,
    PostId = Comment#comment_st.post_id,
    PostUid = Comment#comment_st.post_uid,
    case retract_comment(Uid, CommentId, PostId, PostUid) of
        {ok, ResultTsMs} ->
            SubEl = make_feed_comment_stanza(Action, CommentId, PostId, PostUid,
                    <<>>, Uid, <<>>, ResultTsMs),
            xmpp:make_iq_result(IQ, SubEl);
        {error, Reason} ->
            xmpp:make_error(IQ, util:err(Reason))
    end;

% Share posts with friends.
process_local_iq(#iq{from = #jid{luser = Uid, lserver = Server}, type = set,
        sub_els = [#feed_st{action = share = Action, share_posts = SharePostStanzas}]} = IQ) ->
    ResultSharePostStanzas = lists:map(
        fun(SharePostSt) ->
            process_share_posts(Uid, Server, SharePostSt)
        end, SharePostStanzas),
    xmpp:make_iq_result(IQ, #feed_st{action = Action, share_posts = ResultSharePostStanzas}).


-spec add_friend(Uid :: uid(), Server :: binary(), Ouid :: uid()) -> ok.
add_friend(Uid, Server, Ouid) ->
    ?INFO("Uid: ~s, Ouid: ~s", [Uid, Ouid]),
    % Posts from Uid to Ouid
    send_old_items(Uid, Ouid, Server),
    % Posts from Ouid to Uid
    send_old_items(Ouid, Uid, Server),
    ok.


%%====================================================================
%% Internal functions
%%====================================================================


-spec publish_post(Uid :: uid(), PostId :: binary(), Payload :: binary(),
        AudienceListStanza ::[audience_list_st()]) -> {ok, integer()} | {error, any()}.
publish_post(_Uid, _PostId, _Payload, []) ->
    {error, no_audience};
publish_post(Uid, PostId, Payload, [AudienceListSt]) ->
    ?INFO("Uid: ~s, PostId: ~s", [Uid, PostId]),
    Server = util:get_host(),
    Action = publish,
    FeedAudienceType = AudienceListSt#audience_list_st.type,
    %% Include own Uid in the audience list always.
    FeedAudienceList = [Uid | uid_elements_to_uids(AudienceListSt#audience_list_st.uids)],
    {ok, FinalTimestampMs} = case model_feed:get_post(PostId) of
        {error, missing} ->
            TimestampMs = util:now_ms(),
            ok = model_feed:publish_post(PostId, Uid, Payload,
                    FeedAudienceType, FeedAudienceList, TimestampMs),
            ejabberd_hooks:run(feed_item_published, Server, [Uid, PostId, post]),

            {ok, TimestampMs};
        {ok, ExistingPost} ->
            {ok, ExistingPost#post.ts_ms}
    end,
    broadcast_post(Action, PostId, Uid, Payload, FinalTimestampMs, FeedAudienceList),
    {ok, FinalTimestampMs}.


broadcast_post(Action, PostId, Uid, Payload, TimestampMs, FeedAudienceList) ->
    %% send a new api message to all the clients.
    ResultStanza = make_feed_post_stanza(Action, PostId, Uid, Payload, TimestampMs),
    FeedAudienceSet = get_feed_audience_set(Action, Uid, FeedAudienceList),
    PushSet = FeedAudienceSet,
    broadcast_event(Uid, FeedAudienceSet, PushSet, ResultStanza).


-spec publish_comment(Uid :: uid(), CommentId :: binary(), PostId :: binary(), PostUid :: binary(),
        ParentCommentId :: binary(), Payload :: binary()) -> {ok, integer()} | {error, any()}.
publish_comment(PublisherUid, CommentId, PostId, PostUid, ParentCommentId, Payload) ->
    ?INFO("Uid: ~s, CommentId: ~s, PostId: ~s", [PublisherUid, CommentId, PostId]),
    Server = util:get_host(),
    Action = publish,
    case model_feed:get_comment_data(PostId, CommentId, ParentCommentId) of
        [{error, missing}, _, _] ->
            {error, <<"invalid_post_id">>};
        [{ok, Post}, {ok, Comment}, {ok, ParentPushList}] ->
            %% Comment with same id already exists: duplicate request from the client.
            TimestampMs = Comment#comment.ts_ms,
            PostOwnerUid = Post#post.uid,
            FeedAudienceSet = get_feed_audience_set(Action, PostOwnerUid, Post#post.audience_list),
            NewPushList = [PostOwnerUid, PublisherUid | ParentPushList],
            broadcast_comment(Action, CommentId, PostId, ParentCommentId,
                PublisherUid, Payload, TimestampMs, FeedAudienceSet, NewPushList, PostOwnerUid),
            
            {ok, TimestampMs};
        [{ok, Post}, {error, _}, {ok, ParentPushList}] ->
            TimestampMs = util:now_ms(),
            PostOwnerUid = Post#post.uid,
            FeedAudienceSet = get_feed_audience_set(Action, PostOwnerUid, Post#post.audience_list),
            case sets:is_element(PublisherUid, FeedAudienceSet) of
                false -> ok;
                true ->
                    NewPushList = [PostOwnerUid, PublisherUid | ParentPushList],
                    ok = model_feed:publish_comment(CommentId, PostId, PublisherUid,
                            ParentCommentId, NewPushList, Payload, TimestampMs),
                    ejabberd_hooks:run(feed_item_published, Server, [PublisherUid, CommentId,
                                       comment]),
                    broadcast_comment(Action, CommentId, PostId, ParentCommentId,
                        PublisherUid, Payload, TimestampMs, FeedAudienceSet, NewPushList,
                        PostOwnerUid)
            end,
            {ok, TimestampMs}
    end.


broadcast_comment(Action, CommentId, PostId, ParentCommentId, PublisherUid,
    Payload, TimestampMs, FeedAudienceSet, NewPushList, PostOwnerUid) ->
    %% send a new api message to all the clients.
    ResultStanza = make_feed_comment_stanza(Action, CommentId,
            PostId, PostOwnerUid, ParentCommentId, PublisherUid, Payload, TimestampMs),
    PushSet = sets:from_list(NewPushList),
    broadcast_event(PublisherUid, FeedAudienceSet, PushSet, ResultStanza).


-spec retract_post(Uid :: uid(), PostId :: binary()) -> {ok, integer()} | {error, any()}.
retract_post(Uid, PostId) ->
    ?INFO("Uid: ~s, PostId: ~s", [Uid, PostId]),
    Server = util:get_host(),
    Action = retract,
    case model_feed:get_post(PostId) of
        {error, missing} ->
            {error, <<"invalid_post_id">>};
        {ok, ExistingPost} ->
            case ExistingPost#post.uid =:= Uid of
                false -> {error, not_authorized};
                true ->
                    TimestampMs = util:now_ms(),
                    ok = model_feed:retract_post(PostId, Uid),

                    %% send a new api message to all the clients.
                    ResultStanza = make_feed_post_stanza(Action, PostId, Uid, <<>>, TimestampMs),
                    FeedAudienceSet = get_feed_audience_set(Action, Uid, ExistingPost#post.audience_list),
                    PushSet = sets:new(),
                    broadcast_event(Uid, FeedAudienceSet, PushSet, ResultStanza),
                    ejabberd_hooks:run(feed_item_retracted, Server, [Uid, PostId, post]),

                    {ok, TimestampMs}
            end
    end.


-spec retract_comment(Uid :: uid(), CommentId :: binary(),
        PostId :: binary(), PostUid :: binary()) -> {ok, integer()} | {error, any()}.
retract_comment(PublisherUid, CommentId, PostId, PostUid) ->
    ?INFO("Uid: ~s, CommentId: ~s, PostId: ~s", [PublisherUid, CommentId, PostId]),
    Server = util:get_host(),
    Action = retract,
    case model_feed:get_comment_data(PostId, CommentId, <<>>) of
        [{error, missing}, _, _] ->
            {error, <<"invalid_post_id">>};
        [{ok, _Post}, {error, _}, _] ->
            {error, invalid_comment_id};
        [{ok, Post}, {ok, Comment}, _] ->
            case PublisherUid =:= Comment#comment.publisher_uid of
                false -> {error, not_authorized};
                true ->
                    TimestampMs = util:now_ms(),
                    PostOwnerUid = Post#post.uid,
                    ok = model_feed:retract_comment(CommentId, PostId),

                    %% send a new api message to all the clients.
                    FeedAudienceSet = get_feed_audience_set(Action, PostOwnerUid, Post#post.audience_list),
                    ResultStanza = make_feed_comment_stanza(Action, CommentId, PostId, PostUid, <<>>,
                            PublisherUid, <<>>, TimestampMs),
                    PushSet = sets:new(),
                    broadcast_event(PublisherUid, FeedAudienceSet, PushSet, ResultStanza),
                    ejabberd_hooks:run(feed_item_retracted, Server, [PublisherUid, CommentId, comment]),

                    {ok, TimestampMs}
            end
    end.


-spec process_share_posts(Uid :: uid(), Server :: binary(),
        SharePostSt :: share_posts_st()) -> share_posts_st().
process_share_posts(Uid, Server, SharePostSt) ->
    Ouid = SharePostSt#share_posts_st.uid,
    case model_friends:is_friend(Uid, Ouid) of
        true ->
            PostIds = [PostSt#post_st.id || PostSt <- SharePostSt#share_posts_st.posts],
            share_feed_items(Uid, Ouid, Server, PostIds),
            #share_posts_st{
                uid = Ouid,
                result = ok
            };
        false ->
            #share_posts_st{
                uid = Ouid,
                result = failed,
                reason = invalid_friend_uid
            }
    end.


-spec make_feed_post_stanza(Action :: action_type(), PostId :: binary(),
        Uid :: uid(), Payload :: binary(), TimestampMs :: integer()) -> feed_st().
make_feed_post_stanza(Action, PostId, Uid, Payload, TimestampMs) ->
    #feed_st{
        action = Action,
        posts = [
            #post_st{
                id = PostId,
                uid = Uid,
                payload = Payload,
                timestamp = integer_to_binary(util:ms_to_sec(TimestampMs))
    }]}.


-spec make_feed_comment_stanza(Action :: action_type(), CommentId :: binary(),
        PostId :: binary(), PostUid :: binary(), ParentCommentId :: binary(), Uid :: uid(),
        Payload :: binary(), TimestampMs :: integer()) -> feed_st().
make_feed_comment_stanza(Action, CommentId, PostId, PostUid,
        ParentCommentId, PublisherUid, Payload, TimestampMs) ->
    #feed_st{
        action = Action,
        comments = [
            #comment_st{
                id = CommentId,
                post_id = PostId,
                post_uid = PostUid,
                parent_comment_id = ParentCommentId,
                publisher_uid = PublisherUid,
                publisher_name = model_accounts:get_name_binary(PublisherUid),
                payload = Payload,
                timestamp = integer_to_binary(util:ms_to_sec(TimestampMs))
    }]}.


-spec broadcast_event(Uid :: uid(), FeedAudienceSet :: set(),
        PushSet :: set(), ResultStanza :: feed_st()) -> ok.
broadcast_event(Uid, FeedAudienceSet, PushSet, ResultStanza) ->
    Server = util:get_host(),
    BroadcastUids = sets:to_list(sets:del_element(Uid, FeedAudienceSet)),
    From = jid:make(Server),
    lists:foreach(
        fun(ToUid) ->
            MsgType = get_message_type(ResultStanza, PushSet, ToUid),
            Packet = #message{
                id = util:new_msg_id(),
                to = jid:make(ToUid, Server),
                from = From,
                type = MsgType,
                sub_els = [ResultStanza]
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
-spec get_message_type(FeedStanza :: feed_st(), PushSet :: set(),
        ToUid :: uid()) -> headline | normal.
get_message_type(#feed_st{action = publish, posts = [#post_st{}]}, _, _) -> headline;
get_message_type(#feed_st{action = publish, comments = [#comment_st{}]}, PushSet, Uid) ->
    case sets:is_element(Uid, PushSet) of
        true -> headline;
        false -> normal
    end;
get_message_type(#feed_st{action = retract}, _, _) -> normal.


%%====================================================================
%% feed: helper internal functions
%%====================================================================


-spec send_old_items(FromUid :: uid(), ToUid :: uid(), Server :: binary()) -> ok.
send_old_items(FromUid, ToUid, Server) ->
    ?INFO("sending old items of ~s, to ~s", [FromUid, ToUid]),

    {ok, FeedItems} = model_feed:get_7day_user_feed(FromUid),
    {FilteredPosts, FilteredComments} = filter_feed_items(ToUid, FeedItems),
    PostStanzas = lists:map(fun convert_posts_to_stanzas/1, FilteredPosts),
    CommentStanzas = lists:map(fun convert_comments_to_stanzas/1, FilteredComments),

    ?INFO_MSG("sending FromUid: ~s ToUid: ~s ~p posts and ~p comments",
        [FromUid, ToUid, length(PostStanzas), length(CommentStanzas)]),
    ?INFO_MSG("sending FromUid: ~s ToUid: ~s posts: ~p",
        [FromUid, ToUid, [P#post.id || P <- FilteredPosts]]),

    case PostStanzas of
        [] -> ok;
        _ ->
            Packet = #message{
                id = util:new_msg_id(),
                to = jid:make(ToUid, Server),
                from = jid:make(Server),
                type = normal,
                sub_els = [#feed_st{
                    action = share,
                    posts = PostStanzas,
                    comments = CommentStanzas}]
            },
            ejabberd_router:route(Packet),
            ok
    end.

% Uid is the user to which we want to send those posts.
% Posts have to be either with audience_type all or the Uid has to be in the audience_list
-spec filter_feed_items(Uid :: uid(), Items :: [post()] | [comment()]) -> {[post()], [comment()]}.
filter_feed_items(Uid, Items) ->
    {Posts, Comments} = lists:partition(fun(Item) -> is_record(Item, post) end, Items),
    FilteredPosts = lists:filter(
            fun(Post) ->
                case Post#post.audience_type of
                    all -> true;
                    _ ->
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
share_feed_items(Uid, FriendUid, Server, PostIds) ->
    ?INFO("Uid: ~s, FriendUid: ~s, post_ids: ~p", [Uid, FriendUid, PostIds]),
    ok = model_feed:add_uid_to_audience(FriendUid, PostIds),
    {Posts, Comments} = get_posts_and_comments(PostIds),
    PostStanzas = lists:map(fun convert_posts_to_stanzas/1, Posts),
    CommentStanzas = lists:map(fun convert_comments_to_stanzas/1, Comments),

    MsgType = normal,
    From = jid:make(Server),
    Packet = #message{
        id = util:new_msg_id(),
        to = jid:make(FriendUid, Server),
        from = From,
        type = MsgType,
        sub_els = [#feed_st{
            action = share,
            posts = PostStanzas,
            comments = CommentStanzas}]
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
    {ok, BlockedUids} = model_privacy:get_blocked_uids(Uid),
    {ok, FriendUids} = model_friends:get_friends(Uid),
    AudienceSet = sets:from_list(AudienceList),

    %% Intersect the audience-set with friends, but include the post-owner's uid as well.
    NewAudienceSet = sets:add_element(Uid, sets:intersection(AudienceSet, sets:from_list(FriendUids))),
    FinalAudienceSet = case Action of
        publish -> sets:subtract(NewAudienceSet, sets:from_list(BlockedUids));
        retract -> AudienceSet
    end,
    %% TODO(murali@): adding this for debugging purposes.. remove this case later..
    %% TODO(murali@): Send the final audience set back to the client in the response.
    case AudienceSet =:= FinalAudienceSet of
        true -> ok;
        false ->
            ?ERROR("FinalAudienceSet: ~p, AudienceSet: ~p", [FinalAudienceSet, AudienceSet])
    end,
    FinalAudienceSet.


-spec convert_posts_to_stanzas(post()) -> post_st().
convert_posts_to_stanzas(#post{id = PostId, uid = Uid, payload = Payload, ts_ms = TimestampMs}) ->
    #post_st{
        id = PostId,
        uid = Uid,
        payload = Payload,
        timestamp = integer_to_binary(util:ms_to_sec(TimestampMs))
    }.

-spec convert_comments_to_stanzas(comment()) -> comment_st().
convert_comments_to_stanzas(#comment{id = CommentId, post_id = PostId, publisher_uid = PublisherUid,
        parent_id = ParentId, payload = Payload, ts_ms = TimestampMs}) ->
    #comment_st{
        id = CommentId,
        post_id = PostId,
        publisher_uid = PublisherUid,
        publisher_name = model_accounts:get_name_binary(PublisherUid),
        parent_comment_id = ParentId,
        payload = Payload,
        timestamp = integer_to_binary(util:ms_to_sec(TimestampMs))
    }.


%% TODO(murali@): move this function to a util module.
-spec uid_elements_to_uids([uid_element()]) -> uid().
uid_elements_to_uids(UidEls) ->
    lists:map(
        fun(UidEl) ->
            UidEl#uid_element.uid
        end, UidEls).


