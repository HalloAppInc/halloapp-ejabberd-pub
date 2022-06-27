-module(groupfeed_tests).

-compile([nowarn_export_all, export_all]).
-include("suite.hrl").
-include("packets.hrl").
-include("account_test_data.hrl").
-include_lib("stdlib/include/assert.hrl").

-define(GROUP_NAME1, <<"feed_group1">>).
-define(GROUP_NAME2, <<"feed_group2">>).

-define(POST1_ID, <<"post1">>).
-define(POST2_ID, <<"post2">>).

-define(POST1_PAYLOAD, <<"payload1">>).
-define(POST2_PAYLOAD, <<"payload2">>).

-define(COMMENT1_ID, <<"comment1">>).
-define(COMMENT2_ID, <<"comment2">>).

-define(COMMENT1_PAYLOAD, <<"comment1_pl">>).


group() ->
    {groupfeed, [sequence], [
        groupfeed_dummy_test,
        groupfeed_create_group_test,
        groupfeed_post_test,
        groupfeed_comment_test,
        groupfeed_retract_comment_test,
        groupfeed_retract_post_test
    ]}.

dummy_test(_Conf) ->
    ok.

% Create group with Uid1 and Uid2, make sure Uid2 gets msg about the group.
% We need the group to test the group feed
create_group_test(_Conf) ->
    {ok, C1} = ha_client:connect_and_login(?UID1, ?KEYPAIR1),

    Payload = #pb_group_stanza{
        action = create,
        name = ?GROUP_NAME1,
        members = [
            #pb_group_member{uid = ?UID2},
            #pb_group_member{uid = ?UID3},
            #pb_group_member{uid = ?UID4}
        ]
    },
    Result = ha_client:send_iq(C1, set, Payload),
    % check the create_group result
    ct:pal("Result ~p", [Result]),
    #pb_packet{
        stanza = #pb_iq{
            type = result,
            payload = #pb_group_stanza{
                action = create,
                gid = Gid,
                name = ?GROUP_NAME1,
                members = [
                    #pb_group_member{uid = ?UID2, type = member, result = <<"ok">>, reason = undefined},
                    #pb_group_member{uid = ?UID3, type = member, result = <<"ok">>, reason = undefined},
                    #pb_group_member{uid = ?UID4, type = member, result = <<"ok">>, reason = undefined}
                ]
            }
        }
    } = Result,


    ct:pal("Group Gid ~p", [Gid]),

    {save_config, [{gid, Gid}]}.


% Uid1 makes group post in Group1. Make sure all the members get the post.
post_test(Conf) ->
    {groupfeed_create_group_test, SConfig} = ?config(saved_config, Conf),
    Gid = ?config(gid, SConfig),
    ?assertEqual([?UID1, ?UID2, ?UID3, ?UID4], model_groups:get_member_uids(Gid)),

    {ok, C1} = ha_client:connect_and_login(?UID1, ?KEYPAIR1),

    % Uid1 makes a post to the group
    Payload = #pb_group_feed_item{
        action = publish,
        gid = Gid,
        item = #pb_post{
            id = ?POST1_ID,
            payload = ?POST1_PAYLOAD
        }
    },

    Result = ha_client:send_iq(C1, set, Payload),
    ct:pal("Post result ~p", [Result]),
    % check the result of the iq
    #pb_packet{
        stanza = #pb_iq{
            type = result,
            payload = #pb_group_feed_item{
                gid = Gid,
                action = publish,
                name = ?GROUP_NAME1,
                avatar_id = undefined,
                item = #pb_post{
                    id = ?POST1_ID,
                    payload = ?POST1_PAYLOAD,
                    timestamp = PostTs,
                    publisher_uid = ?UID1,
                    publisher_name = ?NAME1
                }
            }
        }
    } = Result,

    % make sure Uid2, Uid3 and Uid4 get message about the group post
    lists:map(
        fun({User, Password}) ->
            {ok, C2} = ha_client:connect_and_login(User, Password),
            GroupMsg = ha_client:wait_for_msg(C2, pb_group_feed_item),
            GroupFeedItem = GroupMsg#pb_packet.stanza#pb_msg.payload,
            ct:pal("GroupFeedItem ~p", [GroupFeedItem]),
            #pb_group_feed_item{
                action = publish,
                gid = Gid,
                name = ?GROUP_NAME1,
                avatar_id = undefined,
                item = #pb_post{
                    id = ?POST1_ID,
                    payload = ?POST1_PAYLOAD,
                    publisher_uid = ?UID1,
                    publisher_name = ?NAME1,
                    timestamp = PostTs
                }
            } = GroupFeedItem
        end,
        [{?UID2, ?KEYPAIR2}, {?UID3, ?KEYPAIR3}, {?UID4, ?KEYPAIR4}]),

    {save_config, [{gid, Gid}]}.


% Uid2 makes a comment on the Post.
comment_test(Conf) ->
    {groupfeed_post_test, SConfig} = ?config(saved_config, Conf),
    Gid = ?config(gid, SConfig),
    ?assertEqual([?UID1, ?UID2, ?UID3, ?UID4], model_groups:get_member_uids(Gid)),

    {ok, C2} = ha_client:connect_and_login(?UID2, ?KEYPAIR2),

    % Uid2 makes a post to the group
    Payload = #pb_group_feed_item{
        action = publish,
        gid = Gid,
        item = #pb_comment{
            id = ?COMMENT1_ID,
            post_id = ?POST1_ID,
            parent_comment_id = undefined,
            payload = ?COMMENT1_PAYLOAD
        }
    },

    Comment = ha_client:send_iq(C2, set, Payload),
    ct:pal("Comment result ~p", [Comment]),
    % check the result of the iq
    #pb_packet{
        stanza = #pb_iq{
            type = result,
            payload = #pb_group_feed_item{
                gid = Gid,
                action = publish,
                name = ?GROUP_NAME1,
                avatar_id = undefined,
                item = #pb_comment{
                    id = ?COMMENT1_ID,
                    payload = ?COMMENT1_PAYLOAD,
                    parent_comment_id = undefined,
                    post_id = ?POST1_ID,
                    timestamp = CommentTs,
                    publisher_uid = ?UID2,
                    publisher_name = ?NAME2
                }
            }
        }
    } = Comment,

    % make sure Uid1, Uid3 and Uid4 get message about the comment
    lists:map(
        fun({User, Password}) ->
            {ok, CX} = ha_client:connect_and_login(User, Password),
            GroupMsg = ha_client:wait_for_msg(CX, pb_group_feed_item),
            GroupFeedItem = GroupMsg#pb_packet.stanza#pb_msg.payload,
            ct:pal("GroupFeedItem ~p", [GroupFeedItem]),
            #pb_group_feed_item{
                action = publish,
                gid = Gid,
                name = ?GROUP_NAME1,
                avatar_id = undefined,
                item = #pb_comment{
                    id = ?COMMENT1_ID,
                    payload = ?COMMENT1_PAYLOAD,
                    parent_comment_id = undefined,
                    post_id = ?POST1_ID,
                    publisher_uid = ?UID2,
                    publisher_name = ?NAME2,
                    timestamp = CommentTs
                }
            } = GroupFeedItem
        end,
        [{?UID1, ?KEYPAIR1}, {?UID3, ?KEYPAIR3}, {?UID4, ?KEYPAIR4}]),

    {save_config, [{gid, Gid}]}.


% Uid2 deletes the comment.
retract_comment_test(Conf) ->
    {groupfeed_comment_test, SConfig} = ?config(saved_config, Conf),
    Gid = ?config(gid, SConfig),
    ?assertEqual([?UID1, ?UID2, ?UID3, ?UID4], model_groups:get_member_uids(Gid)),

    {ok, C2} = ha_client:connect_and_login(?UID2, ?KEYPAIR2),

    % Uid2 retracts the comment
    Payload = #pb_group_feed_item{
        action = retract,
        gid = Gid,
        item = #pb_comment{
            id = ?COMMENT1_ID,
            post_id = ?POST1_ID
        }
    },

    RetractComment = ha_client:send_iq(C2, set, Payload),
    ct:pal("RetractComment result ~p", [RetractComment]),
    % check the result of the iq
    #pb_packet{
        stanza = #pb_iq{
            type = result,
            payload = #pb_group_feed_item{
                gid = Gid,
                action = retract,
                name = ?GROUP_NAME1,
                avatar_id = undefined,
                item = #pb_comment{
                    id = ?COMMENT1_ID,
                    payload = <<>>,
                    parent_comment_id = <<>>,
                    post_id = ?POST1_ID,
                    publisher_uid = ?UID2,
                    publisher_name = ?NAME2
                }
            }
        }
    } = RetractComment,

    % make sure Uid1, Uid3 and Uid4 get message about the retracted comment
    lists:map(
        fun({User, Password}) ->
            {ok, CX} = ha_client:connect_and_login(User, Password),
            GroupMsg = ha_client:wait_for_msg(CX, pb_group_feed_item),
            GroupFeedItem = GroupMsg#pb_packet.stanza#pb_msg.payload,
            ct:pal("GroupFeedItem ~p", [GroupFeedItem]),
            #pb_group_feed_item{
                action = retract,
                gid = Gid,
                name = ?GROUP_NAME1,
                avatar_id = undefined,
                item = #pb_comment{
                    id = ?COMMENT1_ID,
                    post_id = ?POST1_ID,
                    publisher_uid = ?UID2,
                    publisher_name = ?NAME2
                }
            } = GroupFeedItem
        end,
        [{?UID1, ?KEYPAIR1}, {?UID3, ?KEYPAIR3}, {?UID4, ?KEYPAIR4}]),

    {save_config, [{gid, Gid}]}.


% Uid1 retracts post
retract_post_test(Conf) ->
    {groupfeed_retract_comment_test, SConfig} = ?config(saved_config, Conf),
    Gid = ?config(gid, SConfig),
    ?assertEqual([?UID1, ?UID2, ?UID3, ?UID4], model_groups:get_member_uids(Gid)),

    {ok, C1} = ha_client:connect_and_login(?UID1, ?KEYPAIR1),

    % Uid1 makes a post to the group
    Payload = #pb_group_feed_item{
        action = retract,
        gid = Gid,
        item = #pb_post{
            id = ?POST1_ID
        }
    },

    RetractPost = ha_client:send_iq(C1, set, Payload),
    ct:pal("RetractPost result ~p", [RetractPost]),
    % check the result of the iq
    #pb_packet{
        stanza = #pb_iq{
            type = result,
            payload = #pb_group_feed_item{
                gid = Gid,
                action = retract,
                name = ?GROUP_NAME1,
                avatar_id = undefined,
                item = #pb_post{
                    id = ?POST1_ID
                }
            }
        }
    } = RetractPost,

    % make sure Uid2, Uid3 and Uid4 get message about the retracted comment
    lists:map(
        fun({User, Password}) ->
            {ok, C2} = ha_client:connect_and_login(User, Password),
            GroupMsg = ha_client:wait_for_msg(C2, pb_group_feed_item),
            GroupFeedItem = GroupMsg#pb_packet.stanza#pb_msg.payload,
            ct:pal("GroupFeedItem ~p", [GroupFeedItem]),
            #pb_group_feed_item{
                action = retract,
                gid = Gid,
                name = ?GROUP_NAME1,
                avatar_id = undefined,
                item = #pb_post{
                    id = ?POST1_ID,
                    payload = <<>>,
                    publisher_uid = ?UID1,
                    publisher_name = ?NAME1
                }
            } = GroupFeedItem
        end,
        [{?UID2, ?KEYPAIR2}, {?UID3, ?KEYPAIR3}, {?UID4, ?KEYPAIR4}]),

    {save_config, [{gid, Gid}]}.


% TODO: test posting to group you are not a member of.
% TODO: what happens if someone leaves a group and after that comments have deleted.
