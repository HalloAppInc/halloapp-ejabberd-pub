-module(group_feed_parser).

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
    PbItem = case {SubEl#group_feed_st.post, SubEl#group_feed_st.comment} of
        {PostSt, undefined} ->
            group_post_st_to_post(PostSt);
        {undefined, CommentSt} ->
            group_comment_st_to_comment(CommentSt)
    end,
    #pb_group_feed_item{
        action = SubEl#group_feed_st.action,
        gid = SubEl#group_feed_st.gid,
        name = SubEl#group_feed_st.name,
        avatar_id = SubEl#group_feed_st.avatar_id,
        item = PbItem
    }.

%% -------------------------------------------- %%
%% Protobuf to XMPP
%% -------------------------------------------- %%


proto_to_xmpp(PbPacket) when is_record(PbPacket, pb_group_feed_item) ->
    Action = PbPacket#pb_group_feed_item.action,
    XmppStanza = case PbPacket#pb_group_feed_item.item of
        #pb_post{} = Post ->
            PostSt = post_to_group_post_st(Post),
            #group_feed_st{
                action = Action,
                gid = PbPacket#pb_group_feed_item.gid,
                post = PostSt
            };
        #pb_comment{} = Comment ->
            CommentSt = comment_to_group_comment_st(Comment),
            #group_feed_st{
                action = Action,
                gid = PbPacket#pb_group_feed_item.gid,
                comment = CommentSt
            }
    end,
    XmppStanza.


%% -------------------------------------------- %%
%% internal helper functions
%% -------------------------------------------- %%


group_comment_st_to_comment(CommentSt) ->
    Comment = #pb_comment{
        id = CommentSt#group_comment_st.id,
        post_id = CommentSt#group_comment_st.post_id,
        parent_comment_id = CommentSt#group_comment_st.parent_comment_id,
        publisher_uid = util_parser:xmpp_to_proto_uid(CommentSt#group_comment_st.publisher_uid),
        publisher_name = CommentSt#group_comment_st.publisher_name,
        timestamp = util_parser:maybe_convert_to_integer(CommentSt#group_comment_st.timestamp),
        payload = util_parser:maybe_base64_decode(CommentSt#group_comment_st.payload)
    },
    Comment.

group_post_st_to_post(PostSt) ->
    Post = #pb_post{
        id = PostSt#group_post_st.id,
        publisher_uid = util_parser:xmpp_to_proto_uid(PostSt#group_post_st.publisher_uid),
        publisher_name = PostSt#group_post_st.publisher_name,
        payload = util_parser:maybe_base64_decode(PostSt#group_post_st.payload),
        timestamp = util_parser:maybe_convert_to_integer(PostSt#group_post_st.timestamp)
    },
    Post.

comment_to_group_comment_st(Comment) ->
    CommentSt = #group_comment_st{
        id = Comment#pb_comment.id,
        post_id = Comment#pb_comment.post_id,
        parent_comment_id = Comment#pb_comment.parent_comment_id,
        publisher_uid = util_parser:proto_to_xmpp_uid(Comment#pb_comment.publisher_uid),
        publisher_name = Comment#pb_comment.publisher_name,
        payload = util_parser:maybe_base64_encode(Comment#pb_comment.payload),
        timestamp = util_parser:maybe_convert_to_binary(Comment#pb_comment.timestamp)
    },
    CommentSt.

post_to_group_post_st(Post) ->
    PostSt = #group_post_st{
        id = Post#pb_post.id,
        publisher_uid = util_parser:proto_to_xmpp_uid(Post#pb_post.publisher_uid),
        publisher_name = Post#pb_post.publisher_name,
        payload = util_parser:maybe_base64_encode(Post#pb_post.payload),
        timestamp = util_parser:maybe_convert_to_binary(Post#pb_post.timestamp)
    },
    PostSt.

