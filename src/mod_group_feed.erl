%%%-----------------------------------------------------------------------------------
%%% File    : mod_group_feed.erl
%%%
%%% Copyright (C) 2020 halloappinc.
%%%
%%%-----------------------------------------------------------------------------------

-module(mod_group_feed).
-behaviour(gen_mod).
-author('murali').

-include("logger.hrl").
-include("feed.hrl").
-include("groups.hrl").
-include("packets.hrl").


%% gen_mod API.
-export([start/2, stop/1, reload/3, mod_options/1, depends/2]).

%% Hooks and API.
-export([
    process_local_iq/1,
    re_register_user/3,
    group_member_added/3
]).


start(Host, _Opts) ->
    ?INFO("start", []),
    gen_iq_handler:add_iq_handler(ejabberd_local, Host, pb_group_feed_item, ?MODULE, process_local_iq),
    ejabberd_hooks:add(re_register_user, Host, ?MODULE, re_register_user, 50),
    ejabberd_hooks:add(group_member_added, Host, ?MODULE, group_member_added, 50),
    ok.

stop(Host) ->
    ?INFO("stop", []),
    ejabberd_hooks:delete(re_register_user, Host, ?MODULE, re_register_user, 50),
    ejabberd_hooks:delete(group_member_added, Host, ?MODULE, group_member_added, 50),
    gen_iq_handler:remove_iq_handler(ejabberd_local, Host, pb_group_feed_item),
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
process_local_iq(#pb_iq{from_uid = Uid, type = set,
        payload = #pb_group_feed_item{gid = Gid, action = publish,
        item = #pb_post{} = Post} = GroupFeedSt} = IQ) ->
    PostId = Post#pb_post.id,
    PayloadBase64 = base64:encode(Post#pb_post.payload),
    case publish_post(Gid, Uid, PostId, PayloadBase64, GroupFeedSt) of
        {error, Reason} ->
            pb:make_error(IQ, util:err(Reason));
        {ok, NewGroupFeedSt} ->
            pb:make_iq_result(IQ, NewGroupFeedSt)
    end;

%% Publish comment.
process_local_iq(#pb_iq{from_uid = Uid, type = set,
        payload = #pb_group_feed_item{gid = Gid, action = publish,
        item = #pb_comment{} = Comment} = GroupFeedSt} = IQ) ->
    CommentId = Comment#pb_comment.id,
    PostId = Comment#pb_comment.post_id,
    ParentCommentId = Comment#pb_comment.parent_comment_id,
    PayloadBase64 = base64:encode(Comment#pb_comment.payload),
    case publish_comment(Gid, Uid, CommentId, PostId, ParentCommentId, PayloadBase64, GroupFeedSt) of
        {error, Reason} ->
            pb:make_error(IQ, util:err(Reason));
        {ok, NewGroupFeedSt} ->
            pb:make_iq_result(IQ, NewGroupFeedSt)
    end;

%% Retract post.
process_local_iq(#pb_iq{from_uid = Uid, type = set,
        payload = #pb_group_feed_item{gid = Gid, action = retract,
        item = #pb_post{} = Post} = GroupFeedSt} = IQ) ->
    PostId = Post#pb_post.id,
    case retract_post(Gid, Uid, PostId, GroupFeedSt) of
        {error, Reason} ->
            pb:make_error(IQ, util:err(Reason));
        {ok, NewGroupFeedSt} ->
            pb:make_iq_result(IQ, NewGroupFeedSt)
    end;

%% Retract comment.
process_local_iq(#pb_iq{from_uid = Uid, type = set,
        payload = #pb_group_feed_item{gid = Gid, action = retract,
        item = #pb_comment{} = Comment} = GroupFeedSt} = IQ) ->
    CommentId = Comment#pb_comment.id,
    PostId = Comment#pb_comment.post_id,
    case retract_comment(Gid, Uid, CommentId, PostId, GroupFeedSt) of
        {error, Reason} ->
            pb:make_error(IQ, util:err(Reason));
        {ok, NewGroupFeedSt} ->
            pb:make_iq_result(IQ, NewGroupFeedSt)
    end.


-spec re_register_user(Uid :: binary(), Server :: binary(), Phone :: binary()) -> ok.
re_register_user(Uid, _Server, _Phone) ->
    Gids = model_groups:get_groups(Uid),
    ?INFO("Uid: ~s, Gids: ~p", [Uid, Gids]),
    lists:foreach(
        fun(Gid) ->
            share_group_feed(Gid, Uid)
        end, Gids),
    ok.


-spec group_member_added(Gid :: binary(), Uid :: binary(), AddedByUid :: binary()) -> ok.
group_member_added(Gid, Uid, AddedByUid) ->
    ?INFO("Gid: ~p, Uid: ~p, AddedByUid: ~p", [Gid, Uid, AddedByUid]),
    share_group_feed(Gid, Uid),
    ok.


%%====================================================================
%% Internal functions
%%====================================================================


%% TODO(murali@): log stats for different group-feed activity.
-spec publish_post(Gid :: gid(), Uid :: uid(), PostId :: binary(), PayloadBase64 :: binary(),
        GroupFeedSt :: pb_group_feed_item()) -> {ok, pb_group_feed_item()} | {error, atom()}.
publish_post(Gid, Uid, PostId, PayloadBase64, GroupFeedSt) ->
    ?INFO("Gid: ~s Uid: ~s", [Gid, Uid]),
    Server = util:get_host(),
    case model_groups:check_member(Gid, Uid) of
        false ->
            %% also possible the group does not exists
            {error, not_member};
        true ->
            AudienceType = group,
            AudienceList = model_groups:get_member_uids(Gid),
            AudienceSet = sets:from_list(AudienceList),
            PushSet = AudienceSet,
            GroupInfo = model_groups:get_group_info(Gid),
            {ok, SenderName} = model_accounts:get_name(Uid),

            {ok, FinalTimestampMs} = case model_feed:get_post(PostId) of
                {error, missing} ->
                    TimestampMs = util:now_ms(),
                    ok = model_feed:publish_post(PostId, Uid, PayloadBase64,
                            AudienceType, AudienceList, TimestampMs, Gid),
                    ejabberd_hooks:run(group_feed_item_published, Server, [Gid, Uid, PostId, post]),
                    {ok, TimestampMs};
                {ok, ExistingPost} ->
                    {ok, ExistingPost#post.ts_ms}
            end,

            NewGroupFeedSt = make_pb_group_feed_item(GroupInfo, Uid,
                    SenderName, GroupFeedSt, FinalTimestampMs),
            ?INFO("Fan Out MSG: ~p", [NewGroupFeedSt]),
            ok = broadcast_group_feed_event(Uid, AudienceSet, PushSet, NewGroupFeedSt),
            {ok, NewGroupFeedSt}
    end.


-spec publish_comment(Gid :: gid(), Uid :: uid(), CommentId :: binary(),
        PostId :: binary(), ParentCommentId :: binary(), PayloadBase64 :: binary(),
        GroupFeedSt :: pb_group_feed_item()) -> {ok, pb_group_feed_item()} | {error, atom()}.
publish_comment(Gid, Uid, CommentId, PostId, ParentCommentId, PayloadBase64, GroupFeedSt) ->
    ?INFO("Gid: ~s Uid: ~s", [Gid, Uid]),
    Server = util:get_host(),
    case model_groups:check_member(Gid, Uid) of
        false ->
            %% also possible the group does not exists
            {error, not_member};
        true ->
            GroupInfo = model_groups:get_group_info(Gid),
            {ok, SenderName} = model_accounts:get_name(Uid),

            case model_feed:get_comment_data(PostId, CommentId, ParentCommentId) of
                {{error, missing}, _, _} ->
                    {error, invalid_post_id};
                {{ok, Post}, {ok, Comment}, {ok, ParentPushList}} ->
                    %% Comment with same id already exists: duplicate request from the client.
                    TimestampMs = Comment#comment.ts_ms,
                    PostOwnerUid = Post#post.uid,
                    AudienceList = Post#post.audience_list,
                    AudienceSet = sets:from_list(AudienceList),
                    PushSet = sets:from_list([PostOwnerUid, Uid | ParentPushList]),

                    NewGroupFeedSt = make_pb_group_feed_item(GroupInfo, Uid,
                            SenderName, GroupFeedSt, TimestampMs),
                    ?INFO("Fan Out MSG: ~p", [NewGroupFeedSt]),
                    ok = broadcast_group_feed_event(Uid, AudienceSet, PushSet, NewGroupFeedSt),
                    {ok, NewGroupFeedSt};

                {{ok, Post}, {error, _}, {ok, ParentPushList}} ->
                    TimestampMs = util:now_ms(),
                    PostOwnerUid = Post#post.uid,
                    AudienceList = Post#post.audience_list,
                    AudienceSet = sets:from_list(AudienceList),
                    PushSet = sets:from_list([PostOwnerUid, Uid | ParentPushList]),

                    ok = model_feed:publish_comment(CommentId, PostId, Uid,
                            ParentCommentId, PayloadBase64, TimestampMs),
                    ejabberd_hooks:run(group_feed_item_published, Server,
                            [Gid, Uid, CommentId, comment]),

                    NewGroupFeedSt = make_pb_group_feed_item(GroupInfo, Uid,
                            SenderName, GroupFeedSt, TimestampMs),
                    ?INFO("Fan Out MSG: ~p", [NewGroupFeedSt]),
                    ok = broadcast_group_feed_event(Uid, AudienceSet, PushSet, NewGroupFeedSt),
                    {ok, NewGroupFeedSt}
            end
    end.


-spec retract_post(Gid :: gid(), Uid :: uid(), PostId :: binary(),
        GroupFeedSt :: pb_group_feed_item()) -> {ok, pb_group_feed_item()} | {error, atom()}.
retract_post(Gid, Uid, PostId, GroupFeedSt) ->
    ?INFO("Gid: ~s Uid: ~s", [Gid, Uid]),
    Server = util:get_host(),
    case model_groups:check_member(Gid, Uid) of
        false ->
            %% also possible the group does not exists
            {error, not_member};
        true ->
            case model_feed:get_post(PostId) of
                {error, missing} ->
                    {error, invalid_post_id};
                {ok, ExistingPost} ->
                    case ExistingPost#post.uid =:= Uid of
                        false -> {error, not_authorized};
                        true ->
                            AudienceList = ExistingPost#post.audience_list,
                            AudienceSet = sets:from_list(AudienceList),
                            PushSet = sets:new(),
                            GroupInfo = model_groups:get_group_info(Gid),
                            {ok, SenderName} = model_accounts:get_name(Uid),

                            TimestampMs = util:now_ms(),
                            ok = model_feed:retract_post(PostId, Uid),
                            ejabberd_hooks:run(group_feed_item_retracted, Server,
                                    [Gid, Uid, PostId, post]),

                            NewGroupFeedSt = make_pb_group_feed_item(GroupInfo, Uid,
                                    SenderName, GroupFeedSt, TimestampMs),
                            ?INFO("Fan Out MSG: ~p", [NewGroupFeedSt]),
                            ok = broadcast_group_feed_event(Uid, AudienceSet, PushSet, NewGroupFeedSt),
                            {ok, NewGroupFeedSt}
                    end
            end
    end.


-spec retract_comment(Gid :: gid(), Uid :: uid(), CommentId :: binary(), PostId :: binary(),
        GroupFeedSt :: pb_group_feed_item()) -> {ok, pb_group_feed_item()} | {error, atom()}.
retract_comment(Gid, Uid, CommentId, PostId, GroupFeedSt) ->
    ?INFO("Gid: ~s Uid: ~s", [Gid, Uid]),
    Server = util:get_host(),
    case model_groups:check_member(Gid, Uid) of
        false ->
            %% also possible the group does not exists
            {error, not_member};
        true ->
            case model_feed:get_comment_data(PostId, CommentId, undefined) of
                {{error, missing}, _, _} ->
                    {error, invalid_post_id};
                {{ok, _Post}, {error, _}, _} ->
                    {error, invalid_comment_id};
                {{ok, Post}, {ok, ExistingComment}, _} ->
                    case ExistingComment#comment.publisher_uid =:= Uid of
                        false -> {error, not_authorized};
                        true ->
                            AudienceList = Post#post.audience_list,
                            AudienceSet = sets:from_list(AudienceList),
                            PushSet = sets:new(),
                            GroupInfo = model_groups:get_group_info(Gid),
                            {ok, SenderName} = model_accounts:get_name(Uid),

                            TimestampMs = util:now_ms(),
                            ok = model_feed:retract_comment(CommentId, PostId),
                            ejabberd_hooks:run(group_feed_item_retracted, Server,
                                    [Gid, Uid, CommentId, comment]),

                            NewGroupFeedSt = make_pb_group_feed_item(GroupInfo, Uid,
                                    SenderName, GroupFeedSt, TimestampMs),
                            ?INFO("Fan Out MSG: ~p", [NewGroupFeedSt]),
                            ok = broadcast_group_feed_event(Uid, AudienceSet, PushSet, NewGroupFeedSt),
                            {ok, NewGroupFeedSt}
                    end
            end
    end.


-spec broadcast_group_feed_event(Uid :: uid(), AudienceSet :: set(),
        PushSet :: set(), PBGroupFeed :: pb_group_feed_item()) -> ok.
broadcast_group_feed_event(Uid, AudienceSet, PushSet, PBGroupFeed) ->
    BroadcastUids = sets:to_list(sets:del_element(Uid, AudienceSet)),
    StateBundles = PBGroupFeed#pb_group_feed_item.sender_state_bundles,
    PBGroupFeed2 = PBGroupFeed#pb_group_feed_item{
        sender_state_bundles = []
    },
    StateBundlesMap = case StateBundles of
        undefined -> #{};
        _ -> lists:foldl(
                 fun(StateBundle, Acc) ->
                     Uid2 = StateBundle#pb_sender_state_bundle.uid,
                     EncState = StateBundle#pb_sender_state_bundle.enc_sender_state,
                     Acc#{Uid2 => EncState}
                 end, #{}, StateBundles)
    end,
    lists:foreach(
        fun(ToUid) ->
            MsgType = get_message_type(PBGroupFeed2, PushSet, ToUid),
            PBGroupFeed3 = add_sender_state(PBGroupFeed2, ToUid, StateBundlesMap),
            Packet = #pb_msg{
                id = util_id:new_msg_id(),
                to_uid = ToUid,
                from_uid = Uid,
                type = MsgType,
                payload = PBGroupFeed3
            },
            ejabberd_router:route(Packet)
        end, BroadcastUids),
    ok.


-spec get_message_type(FeedStanza :: pb_group_feed_item(), PushSet :: set(),
        ToUid :: uid()) -> headline | normal.
get_message_type(#pb_group_feed_item{action = publish, item = #pb_post{}}, _, _) -> headline;
get_message_type(#pb_group_feed_item{action = publish, item = #pb_comment{}}, PushSet, Uid) ->
    case sets:is_element(Uid, PushSet) of
        true -> headline;
        false -> normal
    end;
get_message_type(#pb_group_feed_item{action = retract}, _, _) -> normal.


-spec add_sender_state(GroupFeedSt :: pb_group_feed_item(),
        ToUid :: uid(), StateBundlesMap :: #{}) -> pb_group_feed_item().
add_sender_state(GroupFeedSt, Uid, StateBundlesMap) ->
    EncSenderState2 = maps:get(Uid, StateBundlesMap, undefined),
    GroupFeedSt#pb_group_feed_item{
        enc_sender_state = EncSenderState2
    }.


-spec make_pb_group_feed_item(GroupInfo :: group_info(), Uid :: uid(), SenderName :: binary(),
        GroupFeedSt :: pb_group_feed_item(), Ts :: integer()) -> pb_group_feed_item().
make_pb_group_feed_item(GroupInfo, Uid, SenderName, GroupFeedSt, TsMs) ->
    Ts = util:ms_to_sec(TsMs),
    Item = case GroupFeedSt#pb_group_feed_item.item of
        #pb_post{} = Post ->
            Post#pb_post{publisher_uid = Uid, publisher_name = SenderName, timestamp = Ts};
        #pb_comment{} = Comment ->
            Comment#pb_comment{publisher_uid = Uid, publisher_name = SenderName, timestamp = Ts}
    end,
    GroupFeedSt#pb_group_feed_item{
        gid = GroupInfo#group_info.gid,
        name = GroupInfo#group_info.name,
        avatar_id = GroupInfo#group_info.avatar,
        item = Item
    }.


%% TODO(murali@): Similar logic exists in mod_feed as well.
-spec share_group_feed(Gid :: binary(), Uid :: binary()) -> ok.
share_group_feed(Gid, Uid) ->
    Server = util:get_host(),
    {ok, FeedItems} = model_feed:get_entire_group_feed(Gid),
    {FilteredPosts, FilteredComments} = filter_group_feed_items(Uid, FeedItems),
    %% Add the touid to the audience list so that they can comment on these posts.
    FilteredPostIds = [P#post.id || P <- FilteredPosts],
    ok = model_feed:add_uid_to_audience(Uid, FilteredPostIds),

    PostStanzas = lists:map(fun convert_posts_to_groupfeeditem/1, FilteredPosts),
    CommentStanzas = lists:map(fun convert_comments_to_groupfeeditem/1, FilteredComments),
    GroupInfo = model_groups:get_group_info(Gid),

    FilteredPostIds = [P#post.id || P <- FilteredPosts],
    ?INFO_MSG("sending Gid: ~s ToUid: ~s ~p posts and ~p comments",
            [Gid, Uid, length(PostStanzas), length(CommentStanzas)]),
    ?INFO_MSG("sending Gid: ~s ToUid: ~s posts: ~p", [Gid, Uid, FilteredPostIds]),
    ejabberd_hooks:run(group_feed_share_old_items, Server,
            [Gid, Uid, length(PostStanzas), length(CommentStanzas)]),
    case PostStanzas of
        [] -> ok;
        _ ->
            Packet = #pb_msg{
                id = util_id:new_msg_id(),
                to_uid = Uid,
                type = normal,
                payload = #pb_group_feed_items{
                    gid = GroupInfo#group_info.gid,
                    name = GroupInfo#group_info.name,
                    avatar_id = GroupInfo#group_info.avatar,
                    items = PostStanzas ++ CommentStanzas}
            },
            ejabberd_router:route(Packet),
            ok
    end,
    ok.


%% Uid is the user to which we want to send those posts.
%% Now, we share all group feed posts to this user.
-spec filter_group_feed_items(Uid :: uid(), Items :: [post()] | [comment()]) -> {[post()], [comment()]}.
filter_group_feed_items(_Uid, Items) ->
    {Posts, Comments} = lists:partition(fun(Item) -> is_record(Item, post) end, Items),
    FilteredPosts = Posts,
    FilteredPostIdsList = lists:map(fun(Post) -> Post#post.id end, FilteredPosts),
    FilteredPostIdsSet = sets:from_list(FilteredPostIdsList),
    FilteredComments = lists:filter(
            fun(Comment) ->
                sets:is_element(Comment#comment.post_id, FilteredPostIdsSet)
            end, Comments),
    {FilteredPosts, FilteredComments}.


-spec convert_posts_to_groupfeeditem(post()) -> pb_post().
convert_posts_to_groupfeeditem(#post{id = PostId, uid = Uid, payload = PayloadBase64, ts_ms = TimestampMs}) ->
    #pb_group_feed_item{
        item = #pb_post{
            id = PostId,
            publisher_uid = Uid,
            publisher_name = model_accounts:get_name_binary(Uid),
            payload = base64:decode(PayloadBase64),
            timestamp = util:ms_to_sec(TimestampMs)
        }
    }.


-spec convert_comments_to_groupfeeditem(comment()) -> pb_comment().
convert_comments_to_groupfeeditem(#comment{id = CommentId, post_id = PostId, publisher_uid = PublisherUid,
        parent_id = ParentId, payload = PayloadBase64, ts_ms = TimestampMs}) ->
    #pb_group_feed_item{
        item = #pb_comment{
            id = CommentId,
            post_id = PostId,
            parent_comment_id = ParentId,
            publisher_uid = PublisherUid,
            publisher_name = model_accounts:get_name_binary(PublisherUid),
            payload = base64:decode(PayloadBase64),
            timestamp = util:ms_to_sec(TimestampMs)
        }
    }.


