%%%-------------------------------------------------------------------
%%% @copyright (C) 2023, HalloApp, Inc.
%%% @doc
%%%
%%% @end
%%%-------------------------------------------------------------------
-module(mod_halloapp_friends).
-author('murali').

-include("ha_types.hrl").
-include("logger.hrl").
-include("packets.hrl").

%% gen_mod API
-export([start/2, stop/1, reload/3, depends/2, mod_options/1]).

%% API
-export([
    process_local_iq/1,
    remove_user/2,
    notify_profile_update/2,
    notify_profile_update/3,
    username_updated/3,
    user_avatar_published/3,
    account_name_updated/2
]).

%% Number of users to return RelationshipList request
-define(USERS_PER_PAGE, 256).

%%====================================================================
%% gen_mod API
%%====================================================================

start(_Host, _Opts) ->
    gen_iq_handler:add_iq_handler(ejabberd_local, halloapp, pb_friendship_request, ?MODULE, process_local_iq),
    gen_iq_handler:add_iq_handler(ejabberd_local, halloapp, pb_friend_list_request, ?MODULE, process_local_iq),
    ejabberd_hooks:add(remove_user, halloapp, ?MODULE, remove_user, 50),
    ejabberd_hooks:add(username_updated, halloapp, ?MODULE, username_updated, 50),
    ejabberd_hooks:add(user_avatar_published, halloapp, ?MODULE, 50),
    ejabberd_hooks:add(account_name_updated, halloapp, ?MODULE, account_name_updated, 50),
    ok.

stop(_Host) ->
    gen_iq_handler:remove_iq_handler(ejabberd_local, halloapp, pb_friendship_request),
    gen_iq_handler:remove_iq_handler(ejabberd_local, halloapp, pb_friend_list_request),
    ejabberd_hooks:delete(remove_user, halloapp, ?MODULE, remove_user, 50),
    ejabberd_hooks:delete(username_updated, halloapp, ?MODULE, username_updated, 50),
    ejabberd_hooks:delete(user_avatar_published, halloapp, ?MODULE, 50),
    ejabberd_hooks:delete(account_name_updated, halloapp, ?MODULE, account_name_updated, 50),
    ok.

depends(_Host, _Opts) ->
    [].

reload(_Host, _NewOpts, _OldOpts) ->
    ok.

mod_options(_Host) ->
    [].

%%====================================================================
%% IQ handlers
%%====================================================================

%% get FriendList (action = get_friends)
process_local_iq(#pb_iq{from_uid = Uid, type = get,
        payload = #pb_friend_list_request{action = get_friends, cursor = Cursor}} = IQ) ->
    ?INFO("~s get_friends", [Uid]),
    {FriendUids, NewCursor} = model_halloapp_friends:get_friends(Uid, Cursor, ?USERS_PER_PAGE),
    FriendProfiles = model_accounts:get_halloapp_user_profiles(Uid, FriendUids),
    pb:make_iq_result(IQ, #pb_friend_list_response{cursor = NewCursor, friend_profiles = FriendProfiles});

%% get FriendList (action = get_incoming_pending)
process_local_iq(#pb_iq{from_uid = Uid, type = get,
        payload = #pb_friend_list_request{action = get_incoming_pending, cursor = Cursor}} = IQ) ->
    ?INFO("~s get_incoming_pending", [Uid]),
    {IncomingFriendUids, NewCursor} = model_halloapp_friends:get_incoming_friends(Uid, Cursor, ?USERS_PER_PAGE),
    IncomingFriendProfiles = model_accounts:get_halloapp_user_profiles(Uid, IncomingFriendUids),
    pb:make_iq_result(IQ, #pb_friend_list_response{cursor = NewCursor, friend_profiles = IncomingFriendProfiles});

%% get FriendList (action = get_outgoing_pending)
process_local_iq(#pb_iq{from_uid = Uid, type = get,
        payload = #pb_friend_list_request{action = get_outgoing_pending, cursor = Cursor}} = IQ) ->
    ?INFO("~s get_outgoing_pending", [Uid]),
    {OutgoingFriendUids, NewCursor} = model_halloapp_friends:get_outgoing_friends(Uid, Cursor, ?USERS_PER_PAGE),
    OutgoingFriendProfiles = model_accounts:get_halloapp_user_profiles(Uid, OutgoingFriendUids),
    pb:make_iq_result(IQ, #pb_friend_list_response{cursor = NewCursor, friend_profiles = OutgoingFriendProfiles});

% %% get FriendList (action = get_suggestions)
% process_local_iq(#pb_iq{from_uid = Uid, type = get,
%         payload = #pb_friend_list_request{action = get_suggestions, cursor = Cursor}} = IQ) ->
%     ?INFO("~s get_suggestions", [Uid]),
%     %% TODO: Fix this.
%     {SuggestedFriendUids, NewCursor} = {[], <<>>},
%     SuggestedProfiles = model_accounts:get_halloapp_user_profiles(Uid, SuggestedFriendUids),
%     pb:make_iq_result(IQ, #pb_friend_list_response{cursor = NewCursor, friend_profiles = SuggestedProfiles});

%% set FriendList (action = reject)
process_local_iq(#pb_iq{from_uid = Uid, type = set,
        payload = #pb_friendship_request{action = reject_suggestion, uid = Ouid}} = IQ) ->
    ok = model_accounts:add_rejected_suggestions(Ouid, [Uid]),
    ?INFO("~s add_rejected_suggestions ~s", [Uid, Ouid]),
    pb:make_iq_result(IQ, #pb_friendship_response{result = ok});


%% set FriendshipRequest (action = add_friend)
process_local_iq(#pb_iq{from_uid = Uid, type = set,
        payload = #pb_friendship_request{action = add_friend, uid = Ouid}} = IQ) ->
    ok = model_halloapp_friends:add_friend_request(Uid, Ouid),
    FriendProfile = model_accounts:get_halloapp_user_profiles(Uid, Ouid),
    notify_profile_update(Uid, Ouid),
    ?INFO("~s add_friend ~s", [Uid, Ouid]),
    pb:make_iq_result(IQ, #pb_friendship_response{result = ok, profile = FriendProfile});


%% set FriendshipRequest (action = accept_friend)
process_local_iq(#pb_iq{from_uid = Uid, type = set,
        payload = #pb_friendship_request{action = accept_friend, uid = Ouid}} = IQ) ->
    ok = model_halloapp_friends:accept_friend_request(Uid, Ouid),
    add_friend_hook(Uid, Ouid),
    FriendProfile = model_accounts:get_halloapp_user_profiles(Uid, Ouid),
    notify_profile_update(Uid, Ouid),
    ?INFO("~s accept_friend ~s", [Uid, Ouid]),
    pb:make_iq_result(IQ, #pb_friendship_response{result = ok, profile = FriendProfile});


%% set FriendshipRequest (action = remove_friend)
process_local_iq(#pb_iq{from_uid = Uid, type = set,
        payload = #pb_friendship_request{action = remove_friend, uid = Ouid}} = IQ) ->
    ok = model_halloapp_friends:remove_friend(Uid, Ouid),
    remove_friend_hook(Uid, Ouid, false),
    OuidProfile = model_accounts:get_halloapp_user_profiles(Uid, Ouid),
    notify_profile_update(Uid, Ouid),
    ?INFO("~s remove_friend ~s", [Uid, Ouid]),
    pb:make_iq_result(IQ, #pb_friendship_response{result = ok, profile = OuidProfile});


%% set FriendshipRequest (action = block)
process_local_iq(#pb_iq{from_uid = Uid, type = set,
        payload = #pb_friendship_request{action = block, uid = Ouid}} = IQ) ->
    Notify = model_halloapp_friends:is_friend(Uid, Ouid) orelse model_halloapp_friends:is_friend_pending(Uid, Ouid),
    ok = model_halloapp_friends:block(Uid, Ouid),
    remove_friend_hook(Uid, Ouid, true),
    AppType = util_uid:get_app_type(Uid),
    ejabberd_hooks:run(block_uids, AppType, [Uid, util:get_host(), [Ouid]]),
    case Notify of
        true ->
            ok = notify_account_deleted(Uid, Ouid);
        false -> ok
    end,
    OuidProfile = model_accounts:get_halloapp_user_profiles(Uid, Ouid),
    ?INFO("~s blocked ~s", [Uid, Ouid]),
    pb:make_iq_result(IQ, #pb_friendship_response{result = ok, profile = OuidProfile});


%% set FriendshipRequest (action = unblock)
process_local_iq(#pb_iq{from_uid = Uid, type = set,
        payload = #pb_friendship_request{action = unblock, uid = Ouid}} = IQ) ->
    ok = model_halloapp_friends:unblock(Uid, Ouid),
    AppType = util_uid:get_app_type(Uid),
    ejabberd_hooks:run(unblock_uids, AppType, [Uid, util:get_host(), [Ouid]]),
    OuidProfile = model_accounts:get_halloapp_user_profiles(Uid, Ouid),
    ?INFO("~s unblocked ~s", [Uid, Ouid]),
    pb:make_iq_result(IQ, #pb_friendship_response{result = ok, profile = OuidProfile}).


%%====================================================================
%% API
%%====================================================================

-spec add_friend_hook(Uid :: uid(), Ouid :: uid()) -> ok.
add_friend_hook(Uid, Ouid) ->
    Server = util:get_host(),
    AppType = util_uid:get_app_type(Uid),
    ejabberd_hooks:run(add_friend, AppType, [Uid, Server, Ouid, false]).


-spec remove_friend_hook(Uid :: uid(), Ouid :: uid(), WasBlocked :: boolean()) -> ok.
remove_friend_hook(Uid, Ouid, WasBlocked) ->
    Server = util:get_host(),
    AppType = util_uid:get_app_type(Uid),
    ejabberd_hooks:run(remove_friend, AppType, [Uid, Server, Ouid, WasBlocked]).


remove_user(Uid, _Server) ->
    %% Remove all friends
    FriendUids = model_halloapp_friends:get_all_friends(Uid),
    OutgoingFriendUids = model_halloapp_friends:get_all_outgoing_friends(Uid),
    IncomingFriendUids = model_halloapp_friends:get_all_incoming_friends(Uid),
    ok = model_halloapp_friends:remove_all_friends(Uid),
    ok = model_halloapp_friends:remove_all_outgoing_friends(Uid),
    ok = model_halloapp_friends:remove_all_incoming_friends(Uid),
    lists:foreach(
        fun(Ouid) -> notify_account_deleted(Uid, Ouid) end,
        FriendUids ++ OutgoingFriendUids ++ IncomingFriendUids),
    %% Remove all block/blocked by relationships
    model_halloapp_friends:remove_all_blocked_uids(Uid),
    model_halloapp_friends:remove_all_blocked_by_uids(Uid),
    ?INFO("Removed all following/follower, blocked/blocked by lists for ~s", [Uid]),
    ok.


%% Username is the last step after first login.
%% So we wait to get this info and then send new user notifications.
-spec username_updated(Uid :: uid(), Username :: binary(), IsFirstTime :: boolean()) -> ok.
username_updated(Uid, _Username, true) ->
    ?INFO("Uid: ~p", [Uid]),
    %% Users transitioning will set a username, so we'll carry over their existing friends.
    {ok, FriendUids} = model_friends:get_friends(Uid),
    lists:foreach(
        fun(Ouid) -> model_halloapp_friends:accept_friend_request(Uid, Ouid) end,
        FriendUids),
    ok;
username_updated(Uid, _Username, false) ->
    ?INFO("Uid: ~p", [Uid]),
    FriendUids = model_halloapp_friends:get_all_friends(Uid),
    OutgoingFriendUids = model_halloapp_friends:get_all_outgoing_friends(Uid),
    IncomingFriendUids = model_halloapp_friends:get_all_incoming_friends(Uid),
    notify_profile_update(Uid, FriendUids ++ OutgoingFriendUids ++ IncomingFriendUids, normal),
    ok.


-spec account_name_updated(Uid :: uid(), Name :: binary()) -> ok.
account_name_updated(Uid, _Name) ->
    ?INFO("Uid: ~p", [Uid]),
    FriendUids = model_halloapp_friends:get_all_friends(Uid),
    OutgoingFriendUids = model_halloapp_friends:get_all_outgoing_friends(Uid),
    IncomingFriendUids = model_halloapp_friends:get_all_incoming_friends(Uid),
    notify_profile_update(Uid, FriendUids ++ OutgoingFriendUids ++ IncomingFriendUids, normal),
    ok.


-spec user_avatar_published(Uid :: uid(), Server :: binary(), AvatarId :: binary()) -> ok.
user_avatar_published(Uid, _Server, _AvatarId) ->
    ?INFO("Uid: ~p", [Uid]),
    %% TODO: notify contacts as well?
    FriendUids = model_halloapp_friends:get_all_friends(Uid),
    OutgoingFriendUids = model_halloapp_friends:get_all_outgoing_friends(Uid),
    IncomingFriendUids = model_halloapp_friends:get_all_incoming_friends(Uid),
    notify_profile_update(Uid, FriendUids ++ OutgoingFriendUids ++ IncomingFriendUids, normal),
    ok.


-spec notify_profile_update(Uid :: uid() | list(uid()), Ouid :: uid() | list(uid())) -> ok.
notify_profile_update(Uid, Ouid)  ->
    notify_profile_update(Uid, Ouid, normal).


-spec notify_profile_update(Uid :: uid() | list(uid()), Ouid :: uid() | list(uid()), UpdateType :: 'pb_halloapp_profile_update.Type'()) -> ok.
notify_profile_update(Uid, Ouids, UpdateType) when is_list(Ouids) ->
    %% Notify Ouids about a change to Uid's profile
    Profiles = model_accounts:get_halloapp_user_profiles(Ouids, Uid),
    lists:foreach(
        fun({Ouid, Profile}) ->
            send_msg(Uid, Ouid, #pb_halloapp_profile_update{type = UpdateType, profile = Profile})
        end,
        lists:zip(Ouids, Profiles));

notify_profile_update(Uid, Ouid, UpdateType) ->
    %% Notify Ouid about a change to Uid's profile
    ProfileUpdate = #pb_halloapp_profile_update{type = UpdateType, profile = model_accounts:get_halloapp_user_profiles(Ouid, Uid)},
    send_msg(Uid, Ouid, ProfileUpdate).

%%====================================================================
%% Internal functions
%%====================================================================

notify_account_deleted(Uid, Ouid) ->
    %% Notify Ouid that Uid's account no longer exists
    ProfileUpdate = #pb_halloapp_profile_update{type = delete, profile = #pb_halloapp_user_profile{uid = Uid}},
    send_msg(Uid, Ouid, ProfileUpdate).


send_msg(From, To, Payload) ->
    MsgId = util_id:new_msg_id(),
    ?INFO("FromUid: ~p, ToUid: ~p, MsgId: ~p", [From, To, MsgId]),
    Msg = #pb_msg{
        id = MsgId,
        to_uid = To,
        from_uid = From,
        payload = Payload
    },
    ejabberd_router:route(Msg).

