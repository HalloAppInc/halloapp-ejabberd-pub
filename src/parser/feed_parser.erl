-module(feed_parser).

-include("packets.hrl").
-include("logger.hrl").
-include("xmpp.hrl").

-export([
    xmpp_to_proto/1,
    proto_to_xmpp/1
]).


%% -------------------------------------------- %%
%% XMPP to Protobuf
%% -------------------------------------------- %%

xmpp_to_proto(SubEl) ->
    PbStanza = case SubEl#feed_st.action of
        share = Action ->
            case SubEl#feed_st.share_posts of
                [] ->
                    Posts = lists:map(
                        fun(PostSt) ->
                            Post = post_st_to_post(PostSt),
                            #pb_feed_item{
                                item = {post, Post}
                            }
                        end, SubEl#feed_st.posts),
                    Comments = lists:map(
                        fun(CommentSt) ->
                            Comment = comment_st_to_comment(CommentSt),
                            #pb_feed_item{
                                item = {comment, Comment}
                            }
                        end, SubEl#feed_st.comments),
                    Uid = case SubEl#feed_st.posts of
                        [PostSt | _] ->
                            util_parser:xmpp_to_proto_uid(PostSt#post_st.uid);
                        _ ->
                            undefined
                    end,
                    #pb_feed_items{
                        uid = Uid,
                        items = Posts ++ Comments
                    };
                _ ->
                    PbShareStanzas = lists:map(
                        fun(SharePostsSt) ->
                            #pb_share_stanza{
                                uid = util_parser:xmpp_to_proto_uid(SharePostsSt#share_posts_st.uid),
                                result = util_parser:maybe_convert_to_binary(SharePostsSt#share_posts_st.result),
                                reason = util_parser:maybe_convert_to_binary(SharePostsSt#share_posts_st.reason)
                            }
                        end, SubEl#feed_st.share_posts),
                    #pb_feed_item{
                        action = Action,
                        share_stanzas = PbShareStanzas
                    }
            end;
        Action ->
            case {SubEl#feed_st.posts, SubEl#feed_st.comments} of
                {[PostSt], []} ->
                    Post = post_st_to_post(PostSt),
                    #pb_feed_item{
                        action = Action,
                        item = {post, Post}
                    };
                {[], [CommentSt]} ->
                    Comment = comment_st_to_comment(CommentSt),
                    #pb_feed_item{
                        action = Action,
                        item = {comment, Comment}
                    }
            end
    end,
    PbStanza.

%% -------------------------------------------- %%
%% Protobuf to XMPP
%% -------------------------------------------- %%


proto_to_xmpp(PbPacket) when is_record(PbPacket, pb_feed_item) ->
    Action = PbPacket#pb_feed_item.action,
    XmppStanza = case PbPacket#pb_feed_item.item of
        {post, Post} ->
            PostSt = post_to_post_st(Post),
            AudienceLists = case Post#pb_post.audience of
                undefined -> [];
                Audience ->
                    UidEls = lists:map(
                        fun(Uid) ->
                            #uid_element{uid = util_parser:proto_to_xmpp_uid(Uid)}
                        end, Audience#pb_audience.uids),
                    [#audience_list_st{
                        type = Audience#pb_audience.type,
                        uids = UidEls
                    }]
            end,
            #feed_st{
                action = Action,
                posts = [PostSt],
                audience_list = AudienceLists
            };
        {comment, Comment} ->
            CommentSt = comment_to_comment_st(Comment),
            #feed_st{
                action = Action,
                comments = [CommentSt]
            };
        undefined ->
            SharePostsStanzas = lists:map(
                    fun(PbShareStanza) ->
                        Posts = lists:map(
                            fun(PostId) ->
                                #post_st{id = PostId}
                            end, PbShareStanza#pb_share_stanza.post_ids),
                        #share_posts_st{
                            uid = util_parser:proto_to_xmpp_uid(PbShareStanza#pb_share_stanza.uid),
                            posts = Posts
                        }
                    end, PbPacket#pb_feed_item.share_stanzas),
            #feed_st{
                action = Action,
                share_posts = SharePostsStanzas
            }
    end,
    XmppStanza.


%% -------------------------------------------- %%
%% internal helper functions
%% -------------------------------------------- %%


comment_st_to_comment(CommentSt) ->
    Comment = #pb_comment{
        id = CommentSt#comment_st.id,
        post_id = CommentSt#comment_st.post_id,
        parent_comment_id = CommentSt#comment_st.parent_comment_id,
        publisher_uid = binary_to_integer(CommentSt#comment_st.publisher_uid),
        publisher_name = CommentSt#comment_st.publisher_name,
        timestamp = binary_to_integer(CommentSt#comment_st.timestamp),
        payload = CommentSt#comment_st.payload
    },
    Comment.

post_st_to_post(PostSt) ->
    Post = #pb_post{
        id = PostSt#post_st.id,
        uid = binary_to_integer(PostSt#post_st.uid),
        payload = PostSt#post_st.payload,
        timestamp = binary_to_integer(PostSt#post_st.timestamp)
    },
    Post.

comment_to_comment_st(Comment) ->
    CommentSt = #comment_st{
        id = Comment#pb_comment.id,
        post_id = Comment#pb_comment.post_id,
        parent_comment_id = Comment#pb_comment.parent_comment_id,
        publisher_uid = integer_to_binary(Comment#pb_comment.publisher_uid),
        publisher_name = Comment#pb_comment.publisher_name,
        payload = Comment#pb_comment.payload,
        timestamp = integer_to_binary(Comment#pb_comment.timestamp)
    },
    CommentSt.

post_to_post_st(Post) ->
    PostSt = #post_st{
        id = Post#pb_post.id,
        uid = util:to_binary(Post#pb_post.uid),
        payload = Post#pb_post.payload,
        timestamp = integer_to_binary(Post#pb_post.timestamp)
    },
    PostSt.

