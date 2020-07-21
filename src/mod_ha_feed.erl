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
    add_friend/3
]).


start(Host, _Opts) ->
    gen_iq_handler:add_iq_handler(ejabberd_local, Host, ?NS_FEED, ?MODULE, process_local_iq),
    ejabberd_hooks:add(add_friend, Host, ?MODULE, add_friend, 50),
    ok.

stop(Host) ->
    ejabberd_hooks:delete(add_friend, Host, ?MODULE, add_friend, 50),
    gen_iq_handler:remove_iq_handler(ejabberd_local, Host, ?NS_FEED),
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

process_local_iq(#iq{from = #jid{luser = Uid, lserver = _Server}, type = set,
        sub_els = [#feed_st{action = publish = Action, posts = [Post], comments = []}]} = IQ) ->
    PostId = Post#post_st.id,
    Payload = Post#post_st.payload,
    case publish_post(Uid, PostId, Payload) of
        {ok, ResultTsMs} ->
            SubEl = make_feed_post_stanza(Action, PostId, Uid, <<>>, ResultTsMs),
            xmpp:make_iq_result(IQ, SubEl);
        {error, Reason} ->
            xmpp:make_error(IQ, #stream_error{reason = Reason})
    end;
    

process_local_iq(#iq{from = #jid{luser = Uid, lserver = _Server}, type = set,
        sub_els = [#feed_st{action = publish = Action, posts = [], comments = [Comment]}]} = IQ) ->
    CommentId = Comment#comment_st.id,
    PostId = Comment#comment_st.post_id,
    ParentCommentId = Comment#comment_st.parent_comment_id,
    Payload = Comment#comment_st.payload,
    case publish_comment(Uid, CommentId, PostId, ParentCommentId, Payload) of
        {ok, ResultTsMs} ->
            SubEl = make_feed_comment_stanza(Action, CommentId, PostId,
                    ParentCommentId, Uid, <<>>, ResultTsMs),
            xmpp:make_iq_result(IQ, SubEl);
        {error, Reason} ->
            xmpp:make_error(IQ, #stream_error{reason = Reason})
    end;

process_local_iq(#iq{from = #jid{luser = Uid, lserver = _Server}, type = set,
        sub_els = [#feed_st{action = retract = Action, posts = [Post], comments = []}]} = IQ) ->
    PostId = Post#post_st.id,
    case retract_post(Uid, PostId) of
        {ok, ResultTsMs} ->
            SubEl = make_feed_post_stanza(Action, PostId, Uid, <<>>, ResultTsMs),
            xmpp:make_iq_result(IQ, SubEl);
        {error, Reason} ->
            xmpp:make_error(IQ, #stream_error{reason = Reason})
    end;

process_local_iq(#iq{from = #jid{luser = Uid, lserver = _Server}, type = set,
        sub_els = [#feed_st{action = retract = Action, posts = [], comments = [Comment]}]} = IQ) ->
    CommentId = Comment#comment_st.id,
    PostId = Comment#comment_st.post_id,
    case retract_comment(Uid, CommentId, PostId) of
        {ok, ResultTsMs} ->
            SubEl = make_feed_comment_stanza(Action, CommentId, PostId,
                    <<>>, Uid, <<>>, ResultTsMs),
            xmpp:make_iq_result(IQ, SubEl);
        {error, Reason} ->
            xmpp:make_error(IQ, #stream_error{reason = Reason})
    end.


%%====================================================================
%% Internal functions
%%====================================================================


-spec publish_post(Uid :: uid(), PostId :: binary(),
        Payload :: binary()) -> {ok, integer()} | {error, any()}.
publish_post(Uid, PostId, Payload) ->
    ?INFO_MSG("Uid: ~s, PostId: ~s", [Uid, PostId]),
    Server = util:get_host(),
    Action = publish,
    case model_feed:get_post(PostId) of
        {error, missing} ->
            TimestampMs = util:now_ms(),
            ok = model_feed:publish_post(PostId, Uid, Payload, TimestampMs),
            ResultStanza = make_feed_post_stanza(Action, PostId, Uid, Payload, TimestampMs),
            FeedAudienceSet = get_feed_audience_set(Uid),
            broadcast_event(Uid, FeedAudienceSet, ResultStanza),
            ejabberd_hooks:run(feed_item_published, Server, [Uid, PostId, post]),
            {ok, TimestampMs};
        {ok, ExistingPost} ->
            {ok, ExistingPost#post.ts_ms}
    end.


-spec publish_comment(Uid :: uid(), CommentId :: binary(), PostId :: binary(),
        ParentCommentId :: binary(), Payload :: binary()) -> {ok, integer()} | {error, any()}.
publish_comment(PublisherUid, CommentId, PostId, ParentCommentId, Payload) ->
    ?INFO_MSG("Uid: ~s, CommentId: ~s, PostId: ~s", [PublisherUid, CommentId, PostId]),
    Server = util:get_host(),
    Action = publish,
    case model_feed:get_post_and_comment(PostId, CommentId) of
        [{error, missing}, _] ->
            {error, invalid_post_id};
        [{ok, Post}, {error, _}] ->
            TimestampMs = util:now_ms(),
            PostOwnerUid = Post#post.uid,
            FeedAudienceSet = get_feed_audience_set(PostOwnerUid),
            case sets:is_element(PublisherUid, FeedAudienceSet) of
                false -> ok;
                true ->
                    ok = model_feed:publish_comment(CommentId, PostId, PublisherUid,
                            ParentCommentId, Payload, TimestampMs),
                    ResultStanza = make_feed_comment_stanza(Action, CommentId,
                            PostId, ParentCommentId, PublisherUid, Payload, TimestampMs),
                    broadcast_event(PublisherUid, PostOwnerUid, FeedAudienceSet, ResultStanza),
                    ejabberd_hooks:run(feed_item_published, Server,
                            [PublisherUid, CommentId, comment])
            end,
            {ok, TimestampMs};
        [{ok, _Post}, {ok, Comment}] ->
            {ok, Comment#comment.ts_ms}
    end.


-spec retract_post(Uid :: uid(), PostId :: binary()) -> {ok, integer()} | {error, any()}.
retract_post(Uid, PostId) ->
    ?INFO_MSG("Uid: ~s, PostId: ~s", [Uid, PostId]),
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
                    ResultStanza = make_feed_post_stanza(Action, PostId, Uid, <<>>, TimestampMs),
                    FeedAudienceSet = get_feed_audience_set(Uid),
                    broadcast_event(Uid, FeedAudienceSet, ResultStanza),
                    ejabberd_hooks:run(feed_item_retracted, Server, [Uid, PostId, post]),
                    {ok, TimestampMs}
            end
    end.


-spec retract_comment(Uid :: uid(), CommentId :: binary(),
        PostId :: binary()) -> {ok, integer()} | {error, any()}.
retract_comment(PublisherUid, CommentId, PostId) ->
    ?INFO_MSG("Uid: ~s, CommentId: ~s, PostId: ~s", [PublisherUid, CommentId, PostId]),
    Server = util:get_host(),
    Action = retract,
    case model_feed:get_post_and_comment(PostId, CommentId) of
        [{error, missing}, _] ->
            {error, invalid_post_id};
        [{ok, _Post}, {error, _}] ->
            {error, invalid_comment_id};
        [{ok, Post}, {ok, Comment}] ->
            case PublisherUid =:= Comment#comment.publisher_uid of
                false -> {error, not_authorized};
                true ->
                    TimestampMs = util:now_ms(),
                    PostOwnerUid = Post#post.uid,
                    ok = model_feed:retract_comment(CommentId, PostId),
                    FeedAudienceSet = get_feed_audience_set(PostOwnerUid),
                    ResultStanza = make_feed_comment_stanza(Action, CommentId, PostId, <<>>,
                            PublisherUid, <<>>, TimestampMs),
                    broadcast_event(PublisherUid, PostOwnerUid, FeedAudienceSet, ResultStanza),
                    ejabberd_hooks:run(feed_item_retracted, Server,
                            [PublisherUid, CommentId, comment]),
                    {ok, TimestampMs}
            end
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
        PostId :: binary(), ParentCommentId :: binary(), Uid :: uid(),
        Payload :: binary(), TimestampMs :: integer()) -> feed_st().
make_feed_comment_stanza(Action, CommentId, PostId,
        ParentCommentId, PublisherUid, Payload, TimestampMs) ->
    #feed_st{
        action = Action,
        comments = [
            #comment_st{
                id = CommentId,
                post_id = PostId,
                parent_comment_id = ParentCommentId,
                publisher_uid = PublisherUid,
                publisher_name = model_accounts:get_name_binary(PublisherUid),
                payload = Payload,
                timestamp = integer_to_binary(util:ms_to_sec(TimestampMs))
    }]}.


-spec broadcast_event(Uid :: uid(), FeedAudienceSet :: set(), ResultStanza :: feed_st()) -> ok.
broadcast_event(Uid, FeedAudienceSet, ResultStanza) ->
    broadcast_event(Uid, Uid, FeedAudienceSet, ResultStanza).

-spec broadcast_event(Uid :: uid(), PostOwnerUid :: uid(),
        FeedAudienceSet :: set(), ResultStanza :: feed_st()) -> ok.
broadcast_event(Uid, PostOwnerUid, FeedAudienceSet, ResultStanza) ->
    Server = util:get_host(),
    BroadcastUids = sets:to_list(sets:del_element(Uid, FeedAudienceSet)),
    From = jid:make(Server),
    lists:foreach(
        fun(ToUid) ->
            MsgType = get_message_type(ResultStanza, PostOwnerUid, ToUid),
            Packet = #message{
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
%% publish-comment: headline for post-owner, normal for everyone else.
%% retract-anything: normal for all of them. No push is sent here.
-spec get_message_type(FeedStanza :: feed_st(), PostOwnerUid :: uid(),
        ToUid :: uid()) -> headline | normal.
get_message_type(#feed_st{action = publish, posts = [#post_st{}]}, _, _) -> headline;
get_message_type(#feed_st{action = publish, comments = [#comment_st{}]}, PostOwnerUid, Uid) ->
    case PostOwnerUid =:= Uid of
        true -> headline;
        false -> normal
    end;
get_message_type(#feed_st{action = retract}, _, _) -> normal.


%%====================================================================
%% feed: add_friend
%%====================================================================

%% Still using the old logic for now.
%% This will change in the coming diffs.
-spec add_friend(UserId :: binary(), Server :: binary(), ContactId :: binary()) -> ok.
add_friend(UserId, Server, ContactId) ->
    ?INFO_MSG("Uid: ~s, ContactId: ~s", [UserId, ContactId]),
    {ok, TsMs1} = model_accounts:get_creation_ts_ms(UserId),
    {ok, TsMs2} = model_accounts:get_creation_ts_ms(ContactId),
    NowMs = util:now_ms(),
    TimeDiff = 10 * ?MINUTES_MS,

    case NowMs - TsMs1 < TimeDiff of
        true ->
            ?INFO_MSG("sending old items of ~s, to ~s", [ContactId, UserId]),
            send_old_items_to_contact(ContactId, Server, UserId);
        false ->
            ok
    end,
    case NowMs - TsMs2 < TimeDiff of
        true ->
            ?INFO_MSG("sending old items of ~s, to ~s", [UserId, ContactId]),
            send_old_items_to_contact(UserId, Server, ContactId);
        false ->
            ?INFO_MSG("Ignoring add_friend here, Uid: ~s, ContactId: ~s", [UserId, ContactId])
    end,
    ok.


%%====================================================================
%% feed: helper internal functions
%%====================================================================


-spec send_old_items_to_contact(Uid :: uid(), Server :: binary(), ContactId :: binary()) -> ok.
send_old_items_to_contact(Uid, Server, ContactId) ->
    {ok, Items} = model_feed:get_7day_user_feed(Uid),
    [Posts, Comments] = lists:partition(fun(Item) -> is_record(Item, post) end, Items),
    PostStanzas = convert_posts_to_stanzas(Posts),
    CommentStanzas = convert_comments_to_stanzas(Comments),
    %% TODO(murali@): remove this code after successful migration to redis.
    {ok, PubsubItems} = mod_feed_mnesia:get_all_items(<<"feed-", Uid/binary>>),
    {PubsubPostStanzas, PubsubCommentStanzas} = convert_pubsub_items_to_stanzas(PubsubItems),
    MsgType = normal,
    From = jid:make(Server),
    Packet = #message{
        to = jid:make(ContactId, Server),
        from = From,
        type = MsgType,
        sub_els = [#feed_st{
            posts = PostStanzas ++ PubsubPostStanzas,
            comments = CommentStanzas ++ PubsubCommentStanzas}]
    },
    ejabberd_router:route(Packet).


%% Currently, we still use the old-way to compute audience based on Uid.
%% This will change over the next couple of diffs to use the audience from post-id.
-spec get_feed_audience_set(Uid :: uid()) -> set().
get_feed_audience_set(Uid) ->
    AudienceUidSet = case mod_user_privacy:get_privacy_type(Uid) of
        all ->
            {ok, FriendUids} = model_friends:get_friends(Uid),
            sets:from_list(FriendUids);
        except ->
            {ok, FriendUids} = model_friends:get_friends(Uid),
            {ok, ExceptUidsList} = model_privacy:get_except_uids(Uid),
            sets:subtract(sets:from_list(FriendUids), sets:from_list(ExceptUidsList));
        only ->
            {ok, OnlyUidsList} = model_privacy:get_only_uids(Uid),
            sets:from_list(OnlyUidsList)
    end,
    sets:add_element(Uid, AudienceUidSet).


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


%% TODO(murali@): remove this code after successful migration to redis.
-spec convert_pubsub_items_to_stanzas([item()]) -> [].
convert_pubsub_items_to_stanzas(Items) ->
    ResultItems = lists:map(
        fun(Item) ->
            ItemId = element(1, Item#item.key),
            PublisherUid = Item#item.uid,
            TimestampMs = Item#item.creation_ts_ms,
            Payload = Item#item.payload,
            case Item#item.type of
                feedpost ->
                    #post_st{
                        id = ItemId,
                        uid = PublisherUid,
                        payload = Payload,
                        timestamp = integer_to_binary(util:ms_to_sec(TimestampMs))
                    };
                comment ->
                    #comment_st{
                        id = ItemId,
                        post_id = <<>>,
                        parent_comment_id = <<>>,
                        publisher_uid = PublisherUid,
                        publisher_name = model_accounts:get_name_binary(PublisherUid),
                        payload = Payload,
                        timestamp = integer_to_binary(util:ms_to_sec(TimestampMs))
                    }
            end
        end, Items),
    lists:partition(fun(Item) -> is_record(Item, post_st) end, ResultItems).

