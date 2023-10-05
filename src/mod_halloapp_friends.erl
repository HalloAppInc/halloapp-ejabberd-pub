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
    HalloappUserProfiles = model_accounts:get_halloapp_user_profiles(Uid, FriendUids),
    FriendProfiles = [#pb_friend_profile{user_profile = UserProfile} || UserProfile <- HalloappUserProfiles],
    pb:make_iq_result(IQ, #pb_friend_list_response{cursor = NewCursor, friend_profiles = FriendProfiles});

%% get FriendList (action = get_incoming_pending)
process_local_iq(#pb_iq{from_uid = Uid, type = get,
        payload = #pb_friend_list_request{action = get_incoming_pending, cursor = Cursor}} = IQ) ->
    ?INFO("~s get_incoming_pending", [Uid]),
    {IncomingFriendUids, NewCursor} = model_halloapp_friends:get_incoming_friends(Uid, Cursor, ?USERS_PER_PAGE),
    HalloappUserProfiles = model_accounts:get_halloapp_user_profiles(Uid, IncomingFriendUids),
    FriendProfiles = [#pb_friend_profile{user_profile = UserProfile} || UserProfile <- HalloappUserProfiles],
    pb:make_iq_result(IQ, #pb_friend_list_response{cursor = NewCursor, friend_profiles = FriendProfiles});

%% get FriendList (action = get_outgoing_pending)
process_local_iq(#pb_iq{from_uid = Uid, type = get,
        payload = #pb_friend_list_request{action = get_outgoing_pending, cursor = Cursor}} = IQ) ->
    ?INFO("~s get_outgoing_pending", [Uid]),
    {OutgoingFriendUids, NewCursor} = model_halloapp_friends:get_outgoing_friends(Uid, Cursor, ?USERS_PER_PAGE),
    HalloappUserProfiles = model_accounts:get_halloapp_user_profiles(Uid, OutgoingFriendUids),
    FriendProfiles = [#pb_friend_profile{user_profile = UserProfile} || UserProfile <- HalloappUserProfiles],
    pb:make_iq_result(IQ, #pb_friend_list_response{cursor = NewCursor, friend_profiles = FriendProfiles});

%% get FriendList (action = get_suggestions)
process_local_iq(#pb_iq{from_uid = Uid, type = get,
        payload = #pb_friend_list_request{action = get_suggestions, cursor = _Cursor}} = IQ) ->
    ?INFO("~s get_suggestions", [Uid]),
    SuggestedFriendProfiles = mod_friend_suggestions:fetch_friend_suggestions(Uid),
    NewCursor = <<>>, %% no cursor for now.
    pb:make_iq_result(IQ, #pb_friend_list_response{cursor = NewCursor, friend_profiles = SuggestedFriendProfiles});

%% get FriendList (action = get_blocked)
process_local_iq(#pb_iq{from_uid = Uid, type = get,
        payload = #pb_friend_list_request{action = get_blocked, cursor = Cursor}} = IQ) ->
    ?INFO("~s get_blocked", [Uid]),
    BlockedUids = model_halloapp_friends:get_blocked_uids(Uid),
    HalloappUserProfiles = model_accounts:get_halloapp_user_profiles(Uid, BlockedUids),
    FriendProfiles = [#pb_friend_profile{user_profile = UserProfile} || UserProfile <- HalloappUserProfiles],
    pb:make_iq_result(IQ, #pb_friend_list_response{friend_profiles = FriendProfiles});

%% set FriendList (action = reject)
process_local_iq(#pb_iq{from_uid = Uid, type = set,
        payload = #pb_friendship_request{action = reject_suggestion, uid = Ouid}} = IQ) ->
    ok = model_accounts:add_rejected_suggestions(Uid, [Ouid]),
    stat:count("HA/friends", reject_suggestion),
    ?INFO("~s add_rejected_suggestions ~s", [Uid, Ouid]),
    pb:make_iq_result(IQ, #pb_friendship_response{result = ok});


%% set FriendshipRequest (action = add_friend)
process_local_iq(#pb_iq{from_uid = Uid, type = set,
        payload = #pb_friendship_request{action = add_friend, uid = Ouid}} = IQ) ->
    case model_halloapp_friends:is_incoming_friend(Uid, Ouid) of
        false ->
            ?INFO("~s add_friend ~s", [Uid, Ouid]),
            ok = model_halloapp_friends:add_friend_request(Uid, Ouid),
            notify_profile_update(Uid, Ouid, incoming_friend_request),
            stat:count("HA/friends", "add_friend"),
            ok;
        true ->
            ?INFO("~s accept_friend ~s", [Uid, Ouid]),
            ok = model_halloapp_friends:accept_friend_request(Uid, Ouid),
            add_friend_hook(Uid, Ouid),
            notify_profile_update(Uid, Ouid, friend_notice),
            stat:count("HA/friends", "accept_friend"),
            ok
    end,
    stat:count("HA/friends", "request_add_friend"),
    FriendProfile = model_accounts:get_halloapp_user_profiles(Uid, Ouid),
    pb:make_iq_result(IQ, #pb_friendship_response{result = ok, profile = FriendProfile});


%% set FriendshipRequest (action = accept_friend)
process_local_iq(#pb_iq{from_uid = Uid, type = set,
        payload = #pb_friendship_request{action = accept_friend, uid = Ouid}} = IQ) ->
    case model_halloapp_friends:is_incoming_friend(Uid, Ouid) of
        false ->
            ?INFO("~s add_friend ~s", [Uid, Ouid]),
            ok = model_halloapp_friends:add_friend_request(Uid, Ouid),
            notify_profile_update(Uid, Ouid, incoming_friend_request),
            stat:count("HA/friends", "add_friend"),
            ok;
        true ->
            ?INFO("~s accept_friend ~s", [Uid, Ouid]),
            ok = model_halloapp_friends:accept_friend_request(Uid, Ouid),
            add_friend_hook(Uid, Ouid),
            notify_profile_update(Uid, Ouid, friend_notice),
            stat:count("HA/friends", "accept_friend"),
            ok
    end,
    stat:count("HA/friends", "request_accept_friend"),
    FriendProfile = model_accounts:get_halloapp_user_profiles(Uid, Ouid),
    pb:make_iq_result(IQ, #pb_friendship_response{result = ok, profile = FriendProfile});


%% set FriendshipRequest (action = remove_friend)
process_local_iq(#pb_iq{from_uid = Uid, type = set,
        payload = #pb_friendship_request{action = remove_friend, uid = Ouid}} = IQ) ->
    IsFriends = model_halloapp_friends:is_friend(Uid, Ouid),
    ok = model_halloapp_friends:remove_friend(Uid, Ouid),
    case IsFriends of
        true -> remove_friend_hook(Uid, Ouid, false);
        false -> ok %% Dont run hook if they were never friends in the first place.
    end,
    stat:count("HA/friends", "remove_friend"),
    OuidProfile = model_accounts:get_halloapp_user_profiles(Uid, Ouid),
    notify_profile_update(Uid, Ouid),
    ?INFO("~s remove_friend ~s", [Uid, Ouid]),
    pb:make_iq_result(IQ, #pb_friendship_response{result = ok, profile = OuidProfile});


%% set FriendshipRequest (action = withdraw_friend)
process_local_iq(#pb_iq{from_uid = Uid, type = set,
        payload = #pb_friendship_request{action = withdraw_friend_request, uid = Ouid}} = IQ) ->
    IsFriends = model_halloapp_friends:is_friend(Uid, Ouid),
    ok = model_halloapp_friends:remove_friend(Uid, Ouid),
    case IsFriends of
        true -> remove_friend_hook(Uid, Ouid, false);
        false -> ok %% Dont run hook if they were never friends in the first place.
    end,
    stat:count("HA/friends", "withdraw_friend_request"),
    OuidProfile = model_accounts:get_halloapp_user_profiles(Uid, Ouid),
    notify_profile_update(Uid, Ouid),
    ?INFO("~s withdraw_friend_request ~s", [Uid, Ouid]),
    pb:make_iq_result(IQ, #pb_friendship_response{result = ok, profile = OuidProfile});

%% set FriendshipRequest (action = remove_friend)
process_local_iq(#pb_iq{from_uid = Uid, type = set,
        payload = #pb_friendship_request{action = reject_friend, uid = Ouid}} = IQ) ->
    IsFriends = model_halloapp_friends:is_friend(Uid, Ouid),
    ok = model_halloapp_friends:remove_friend(Uid, Ouid),
    case IsFriends of
        true -> remove_friend_hook(Uid, Ouid, false);
        false -> ok %% Dont run hook if they were never friends in the first place.
    end,
    stat:count("HA/friends", "reject_friend"),
    OuidProfile = model_accounts:get_halloapp_user_profiles(Uid, Ouid),
    notify_profile_update(Uid, Ouid),
    ?INFO("~s reject_friend ~s", [Uid, Ouid]),
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
    stat:count("HA/friends", "block"),
    OuidProfile = model_accounts:get_halloapp_user_profiles(Uid, Ouid),
    ?INFO("~s blocked ~s", [Uid, Ouid]),
    pb:make_iq_result(IQ, #pb_friendship_response{result = ok, profile = OuidProfile});


%% set FriendshipRequest (action = unblock)
process_local_iq(#pb_iq{from_uid = Uid, type = set,
        payload = #pb_friendship_request{action = unblock, uid = Ouid}} = IQ) ->
    ok = model_halloapp_friends:unblock(Uid, Ouid),
    stat:count("HA/friends", "unblock"),
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
    AppType = util_uid:get_app_type(Uid),
    case AppType of
        halloapp ->
            %% Users transitioning will set a username, so we'll carry over their existing friends.
            {ok, FriendUids} = model_friends:get_friends(Uid),
            lists:foreach(
                fun(Ouid) -> model_halloapp_friends:accept_friend_request(Uid, Ouid) end,
                FriendUids),

            %% We will also carry over their existing block relationships
            {ok, BlockedUids} = model_privacy:get_blocked_uids2(Uid),
            lists:foreach(
                fun(Ouid) -> model_halloapp_friends:block(Uid, Ouid) end,
                BlockedUids),
            ok;
        _ ->
            ok
    end,
    NewFriendUids = model_halloapp_friends:get_all_friends(Uid),
    OutgoingFriendUids = model_halloapp_friends:get_all_outgoing_friends(Uid),
    IncomingFriendUids = model_halloapp_friends:get_all_incoming_friends(Uid),
    notify_profile_update(Uid, NewFriendUids ++ OutgoingFriendUids ++ IncomingFriendUids, normal),
    %% ask clients to sync all lists after username is updated for the first time.
    SyncUpdate = #pb_friend_list_request{action = sync_all},
    send_msg(<<>>, Uid, SyncUpdate);
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
notify_profile_update(_Uid, [], _) -> ok;
notify_profile_update(Uid, Ouids, UpdateType) when is_list(Ouids) ->
    %% Notify Ouids about a change to Uid's profile
    lists:foreach(
        fun(Ouid) ->
            Profile = model_accounts:get_halloapp_user_profiles(Ouid, Uid),
            send_msg(Uid, Ouid, #pb_halloapp_profile_update{type = UpdateType, profile = Profile})
        end,
        Ouids);

notify_profile_update(Uid, Ouid, UpdateType) ->
    %% Notify Ouid about a change to Uid's profile
    ProfileUpdate = #pb_halloapp_profile_update{type = UpdateType, profile = model_accounts:get_halloapp_user_profiles(Ouid, Uid)},
    send_msg(Uid, Ouid, ProfileUpdate).

%%====================================================================
%% Internal functions
%%====================================================================

notify_account_deleted(Uid, Ouid) ->
    %% Notify Ouid that Uid's account no longer exists
    ProfileUpdate = #pb_halloapp_profile_update{type = delete_notice, profile = #pb_halloapp_user_profile{uid = Uid}},
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

