%%%-----------------------------------------------------------------------------------
%%% File    : mod_group_feed.erl
%%%
%%% Copyright (C) 2020 halloappinc.
%%%
%%%-----------------------------------------------------------------------------------

-module(mod_group_feed).
-behaviour(gen_mod).
-author('murali').

-include("xmpp.hrl").
-include("logger.hrl").
-include("feed.hrl").
-include("groups.hrl").


%% gen_mod API.
-export([start/2, stop/1, reload/3, mod_options/1, depends/2]).

%% Hooks and API.
-export([
    process_local_iq/1,
    re_register_user/3
]).


start(Host, _Opts) ->
    ?INFO("start", []),
    gen_iq_handler:add_iq_handler(ejabberd_local, Host, ?NS_GROUPS_FEED, ?MODULE, process_local_iq),
    ejabberd_hooks:add(re_register_user, Host, ?MODULE, re_register_user, 50),
    ok.

stop(Host) ->
    ?INFO("stop", []),
    ejabberd_hooks:delete(re_register_user, Host, ?MODULE, re_register_user, 50),
    gen_iq_handler:remove_iq_handler(ejabberd_local, Host, ?NS_GROUPS_FEED),
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
process_local_iq(#iq{from = #jid{luser = Uid}, type = set,
        sub_els = [#group_feed_st{gid = Gid, action = publish,
        posts = [Post], comments = []} = GroupFeedSt]} = IQ) ->
    PostId = Post#group_post_st.id,
    Payload = Post#group_post_st.payload,
    case publish_post(Gid, Uid, PostId, Payload, GroupFeedSt) of
        {error, Reason} ->
            xmpp:make_error(IQ, util:err(Reason));
        {ok, NewGroupFeedSt} ->
            xmpp:make_iq_result(IQ, NewGroupFeedSt)
    end;

%% Publish comment.
process_local_iq(#iq{from = #jid{luser = Uid}, type = set,
        sub_els = [#group_feed_st{gid = Gid, action = publish,
        posts = [], comments = [Comment]} = GroupFeedSt]} = IQ) ->
    CommentId = Comment#group_comment_st.id,
    PostId = Comment#group_comment_st.post_id,
    ParentCommentId = Comment#group_comment_st.parent_comment_id,
    Payload = Comment#group_comment_st.payload,
    case publish_comment(Gid, Uid, CommentId, PostId, ParentCommentId, Payload, GroupFeedSt) of
        {error, Reason} ->
            xmpp:make_error(IQ, util:err(Reason));
        {ok, NewGroupFeedSt} ->
            xmpp:make_iq_result(IQ, NewGroupFeedSt)
    end;

%% Retract post.
process_local_iq(#iq{from = #jid{luser = Uid}, type = set,
        sub_els = [#group_feed_st{gid = Gid, action = retract,
        posts = [Post], comments = []} = GroupFeedSt]} = IQ) ->
    PostId = Post#group_post_st.id,
    case retract_post(Gid, Uid, PostId, GroupFeedSt) of
        {error, Reason} ->
            xmpp:make_error(IQ, util:err(Reason));
        {ok, NewGroupFeedSt} ->
            xmpp:make_iq_result(IQ, NewGroupFeedSt)
    end;

%% Retract comment.
process_local_iq(#iq{from = #jid{luser = Uid}, type = set,
        sub_els = [#group_feed_st{gid = Gid, action = retract,
        posts = [], comments = [Comment]} = GroupFeedSt]} = IQ) ->
    CommentId = Comment#group_comment_st.id,
    PostId = Comment#group_comment_st.post_id,
    case retract_comment(Gid, Uid, CommentId, PostId, GroupFeedSt) of
        {error, Reason} ->
            xmpp:make_error(IQ, util:err(Reason));
        {ok, NewGroupFeedSt} ->
            xmpp:make_iq_result(IQ, NewGroupFeedSt)
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


%%====================================================================
%% Internal functions
%%====================================================================


%% TODO(murali@): log stats for different group-feed activity.
-spec publish_post(Gid :: gid(), Uid :: uid(), PostId :: binary(), Payload :: binary(),
        GroupFeedSt :: group_feed_st()) -> {ok, group_feed_st()} | {error, atom()}.
publish_post(Gid, Uid, PostId, Payload, GroupFeedSt) ->
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
                    ok = model_feed:publish_post(PostId, Uid, Payload,
                            AudienceType, AudienceList, TimestampMs, Gid),
                    ejabberd_hooks:run(group_feed_item_published, Server, [Gid, Uid, PostId, post]),
                    {ok, TimestampMs};
                {ok, ExistingPost} ->
                    {ok, ExistingPost#post.ts_ms}
            end,

            NewGroupFeedSt = make_group_feed_st(GroupInfo, Uid,
                    SenderName, GroupFeedSt, FinalTimestampMs),
            ?INFO("Fan Out MSG: ~p", [NewGroupFeedSt]),
            ok = broadcast_group_feed_event(Uid, AudienceSet, PushSet, NewGroupFeedSt),
            {ok, NewGroupFeedSt}
    end.


-spec publish_comment(Gid :: gid(), Uid :: uid(), CommentId :: binary(),
        PostId :: binary(), ParentCommentId :: binary(), Payload :: binary(),
        GroupFeedSt :: group_feed_st()) -> {ok, group_feed_st()} | {error, atom()}.
publish_comment(Gid, Uid, CommentId, PostId, ParentCommentId, Payload, GroupFeedSt) ->
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
                [{error, missing}, _, _] ->
                    {error, invalid_post_id};
                [{ok, Post}, {ok, Comment}, {ok, ParentPushList}] ->
                    %% Comment with same id already exists: duplicate request from the client.
                    TimestampMs = Comment#comment.ts_ms,
                    PostOwnerUid = Post#post.uid,
                    AudienceList = Post#post.audience_list,
                    AudienceSet = sets:from_list(AudienceList),
                    PushSet = sets:from_list([PostOwnerUid, Uid | ParentPushList]),

                    NewGroupFeedSt = make_group_feed_st(GroupInfo, Uid,
                            SenderName, GroupFeedSt, TimestampMs),
                    ?INFO("Fan Out MSG: ~p", [NewGroupFeedSt]),
                    ok = broadcast_group_feed_event(Uid, AudienceSet, PushSet, NewGroupFeedSt),
                    {ok, NewGroupFeedSt};

                [{ok, Post}, {error, _}, {ok, ParentPushList}] ->
                    TimestampMs = util:now_ms(),
                    PostOwnerUid = Post#post.uid,
                    AudienceList = Post#post.audience_list,
                    AudienceSet = sets:from_list(AudienceList),
                    PushList = [PostOwnerUid, Uid | ParentPushList],
                    PushSet = sets:from_list([PostOwnerUid, Uid | ParentPushList]),

                    ok = model_feed:publish_comment(CommentId, PostId, Uid,
                            ParentCommentId, PushList, Payload, TimestampMs),
                    ejabberd_hooks:run(group_feed_item_published, Server,
                            [Gid, Uid, CommentId, comment]),

                    NewGroupFeedSt = make_group_feed_st(GroupInfo, Uid,
                            SenderName, GroupFeedSt, TimestampMs),
                    ?INFO("Fan Out MSG: ~p", [NewGroupFeedSt]),
                    ok = broadcast_group_feed_event(Uid, AudienceSet, PushSet, NewGroupFeedSt),
                    {ok, NewGroupFeedSt}
            end
    end.


-spec retract_post(Gid :: gid(), Uid :: uid(), PostId :: binary(),
        GroupFeedSt :: group_feed_st()) -> {ok, group_feed_st()} | {error, atom()}.
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

                            NewGroupFeedSt = make_group_feed_st(GroupInfo, Uid,
                                    SenderName, GroupFeedSt, TimestampMs),
                            ?INFO("Fan Out MSG: ~p", [NewGroupFeedSt]),
                            ok = broadcast_group_feed_event(Uid, AudienceSet, PushSet, NewGroupFeedSt),
                            {ok, NewGroupFeedSt}
                    end
            end
    end.


-spec retract_comment(Gid :: gid(), Uid :: uid(), CommentId :: binary(), PostId :: binary(),
        GroupFeedSt :: group_feed_st()) -> {ok, group_feed_st()} | {error, atom()}.
retract_comment(Gid, Uid, CommentId, PostId, GroupFeedSt) ->
    ?INFO("Gid: ~s Uid: ~s", [Gid, Uid]),
    Server = util:get_host(),
    case model_groups:check_member(Gid, Uid) of
        false ->
            %% also possible the group does not exists
            {error, not_member};
        true ->
            case model_feed:get_comment_data(PostId, CommentId, undefined) of
                [{error, missing}, _, _] ->
                    {error, invalid_post_id};
                [{ok, _Post}, {error, _}, _] ->
                    {error, invalid_comment_id};
                [{ok, Post}, {ok, ExistingComment}, _] ->
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

                            NewGroupFeedSt = make_group_feed_st(GroupInfo, Uid,
                                    SenderName, GroupFeedSt, TimestampMs),
                            ?INFO("Fan Out MSG: ~p", [NewGroupFeedSt]),
                            ok = broadcast_group_feed_event(Uid, AudienceSet, PushSet, NewGroupFeedSt),
                            {ok, NewGroupFeedSt}
                    end
            end
    end.


-spec broadcast_group_feed_event(Uid :: uid(), AudienceSet :: set(),
        PushSet :: set(), ResultStanza :: feed_st()) -> ok.
broadcast_group_feed_event(Uid, AudienceSet, PushSet, GroupFeedStanza) ->
    Server = util:get_host(),
    BroadcastUids = sets:to_list(sets:del_element(Uid, AudienceSet)),
    From = jid:make(Uid, Server),
    lists:foreach(
        fun(ToUid) ->
            MsgType = get_message_type(GroupFeedStanza, PushSet, ToUid),
            Packet = #message{
                id = util:new_msg_id(),
                to = jid:make(ToUid, Server),
                from = From,
                type = MsgType,
                sub_els = [GroupFeedStanza]
            },
            ejabberd_router:route(Packet)
        end, BroadcastUids),
    ok.


-spec get_message_type(FeedStanza :: feed_st(), PushSet :: set(),
        ToUid :: uid()) -> headline | normal.
get_message_type(#group_feed_st{action = publish, posts = [#group_post_st{}]}, _, _) -> headline;
get_message_type(#group_feed_st{action = publish, comments = [#group_comment_st{}]}, PushSet, Uid) ->
    case sets:is_element(Uid, PushSet) of
        true -> headline;
        false -> normal
    end;
get_message_type(#group_feed_st{action = retract}, _, _) -> normal.


-spec make_group_feed_st(GroupInfo :: group_info(), Uid :: uid(), SenderName :: binary(),
        GroupFeedSt :: group_feed_st(), Ts :: integer()) -> group_chat().
make_group_feed_st(GroupInfo, Uid, SenderName, GroupFeedSt, TsMs) ->
    TsBin = integer_to_binary(util:ms_to_sec(TsMs)),
    Posts = case GroupFeedSt#group_feed_st.posts of
        [] -> [];
        [P] -> [P#group_post_st{publisher_uid = Uid, publisher_name = SenderName, timestamp = TsBin}]
    end,
    Comments = case GroupFeedSt#group_feed_st.comments of
        [] -> [];
        [C] -> [C#group_comment_st{publisher_uid = Uid, publisher_name = SenderName, timestamp = TsBin}]
    end,
    GroupFeedSt#group_feed_st{
        gid = GroupInfo#group_info.gid,
        name = GroupInfo#group_info.name,
        avatar_id = GroupInfo#group_info.avatar,
        posts = Posts,
        comments = Comments
    }.


%% TODO(murali@): Similar logic exists in mod_feed as well.
-spec share_group_feed(Gid :: binary(), Uid :: binary()) -> ok.
share_group_feed(Gid, Uid) ->
    Server = util:get_host(),
    {ok, FeedItems} = model_feed:get_entire_group_feed(Gid),
    {FilteredPosts, FilteredComments} = filter_group_feed_items(Uid, FeedItems),
    PostStanzas = lists:map(fun convert_posts_to_group_stanzas/1, FilteredPosts),
    CommentStanzas = lists:map(fun convert_comments_to_group_stanzas/1, FilteredComments),
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
            Packet = #message{
                id = util:new_msg_id(),
                to = jid:make(Uid, Server),
                from = jid:make(Server),
                type = normal,
                sub_els = [#group_feed_st{
                    action = share,
                    gid = GroupInfo#group_info.gid,
                    name = GroupInfo#group_info.name,
                    avatar_id = GroupInfo#group_info.avatar,
                    posts = PostStanzas,
                    comments = CommentStanzas}]
            },
            ejabberd_router:route(Packet),
            ok
    end,
    ok.


% Uid is the user to which we want to send those posts.
% Posts must have Uid in the audience_list
-spec filter_group_feed_items(Uid :: uid(), Items :: [post()] | [comment()]) -> {[post()], [comment()]}.
filter_group_feed_items(Uid, Items) ->
    {Posts, Comments} = lists:partition(fun(Item) -> is_record(Item, post) end, Items),
    FilteredPosts = lists:filter(
            fun(Post) ->
                lists:member(Uid, Post#post.audience_list)
            end, Posts),
    FilteredPostIdsList = lists:map(fun(Post) -> Post#post.id end, FilteredPosts),
    FilteredPostIdsSet = sets:from_list(FilteredPostIdsList),
    FilteredComments = lists:filter(
            fun(Comment) ->
                sets:is_element(Comment#comment.post_id, FilteredPostIdsSet)
            end, Comments),
    {FilteredPosts, FilteredComments}.


-spec convert_posts_to_group_stanzas(post()) -> post_st().
convert_posts_to_group_stanzas(#post{id = PostId, uid = Uid, payload = Payload, ts_ms = TimestampMs}) ->
    #group_post_st{
        id = PostId,
        publisher_uid = Uid,
        publisher_name = model_accounts:get_name_binary(Uid),
        payload = Payload,
        timestamp = integer_to_binary(util:ms_to_sec(TimestampMs))
    }.


-spec convert_comments_to_group_stanzas(comment()) -> comment_st().
convert_comments_to_group_stanzas(#comment{id = CommentId, post_id = PostId, publisher_uid = PublisherUid,
        parent_id = ParentId, payload = Payload, ts_ms = TimestampMs}) ->
    #group_comment_st{
        id = CommentId,
        post_id = PostId,
        parent_comment_id = ParentId,
        publisher_uid = PublisherUid,
        publisher_name = model_accounts:get_name_binary(PublisherUid),
        payload = Payload,
        timestamp = integer_to_binary(util:ms_to_sec(TimestampMs))
    }.


