%%%-------------------------------------------------------------------
%%% @author josh
%%% @copyright (C) 2022, HalloApp, Inc.
%%% @doc
%%%
%%% @end
%%%-------------------------------------------------------------------
-module(mod_follow).
-author("josh").

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
    notify_profile_update/3
]).

%% Number of users to return RelationshipList request
-define(USERS_PER_PAGE, 256).

%%====================================================================
%% gen_mod API
%%====================================================================

start(_Host, _Opts) ->
    gen_iq_handler:add_iq_handler(ejabberd_local, ?KATCHUP, pb_relationship_request, ?MODULE, process_local_iq),
    gen_iq_handler:add_iq_handler(ejabberd_local, ?KATCHUP, pb_relationship_list, ?MODULE, process_local_iq),
    ejabberd_hooks:add(remove_user, ?KATCHUP, ?MODULE, remove_user, 50),
    ok.

stop(_Host) ->
    gen_iq_handler:remove_iq_handler(ejabberd_local, ?KATCHUP, pb_relationship_request),
    gen_iq_handler:remove_iq_handler(ejabberd_local, ?KATCHUP, pb_relationship_list),
    ejabberd_hooks:delete(remove_user, ?KATCHUP, ?MODULE, remove_user, 50),
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

%% get RelationshipList (type = following)
process_local_iq(#pb_iq{from_uid = Uid, type = get,
        payload = #pb_relationship_list{type = following, cursor = Cursor} = RelationshipList} = IQ) ->
    {FollowingUids, NewCursor} = model_follow:get_following(Uid, Cursor, ?USERS_PER_PAGE),
    UserProfiles = model_accounts:get_basic_user_profiles(Uid, FollowingUids),
    pb:make_iq_result(IQ, RelationshipList#pb_relationship_list{cursor = NewCursor, users = UserProfiles});


%% get RelationshipList (type = follower)
process_local_iq(#pb_iq{from_uid = Uid, type = get,
        payload = #pb_relationship_list{type = follower, cursor = Cursor} = RelationshipList} = IQ) ->
    {FollowerUids, NewCursor} = model_follow:get_followers(Uid, Cursor, ?USERS_PER_PAGE),
    UserProfiles = model_accounts:get_basic_user_profiles(Uid, FollowerUids),
    pb:make_iq_result(IQ, RelationshipList#pb_relationship_list{cursor = NewCursor, users = UserProfiles});


%% get RelationshipList (type = blocked)
process_local_iq(#pb_iq{from_uid = Uid, type = get,
        payload = #pb_relationship_list{type = blocked} = RelationshipList} = IQ) ->
    BlockedUids = model_follow:get_blocked_uids(Uid),
    UserProfiles = model_accounts:get_basic_user_profiles(Uid, BlockedUids),
    %% Need to insert names as per the designs for the blocked list in-app
    UserProfiles2 = lists:map(
        fun(#pb_basic_user_profile{uid = Ouid} = UserProfile) ->
            {ok, Name} = model_accounts:get_name(Ouid),
            UserProfile#pb_basic_user_profile{name = Name}
        end,
        UserProfiles),
    pb:make_iq_result(IQ, RelationshipList#pb_relationship_list{cursor = <<>>, users = UserProfiles2});


%% get RelationshipList error: unknown type
process_local_iq(#pb_iq{from_uid = Uid, type = get,
        payload = #pb_relationship_list{type = Type}} = IQ) ->
    ?ERROR("Received IQ from ~s for unknown RelationshipList type: ~s", [Uid, Type]),
    pb:make_error(IQ, util:err(invalid_type));


%% RelationshipRequest where user tries to do something with themself should fail
process_local_iq(#pb_iq{from_uid = Uid,
    payload = #pb_relationship_request{action = Action, uid = Ouid}} = IQ) when Uid =:= Ouid ->
    ?WARNING("User tried to ~p themselves: ~p", [Action, Uid]),
    pb:make_iq_result(IQ, #pb_relationship_response{result = fail});

%% RelationshipRequest (action = follow)
process_local_iq(#pb_iq{from_uid = Uid,
        payload = #pb_relationship_request{action = follow, uid = Ouid}} = IQ) ->
    Ret = case model_follow:is_blocked_any(Uid, Ouid) of
        false ->
            ok = model_follow:follow(Uid, Ouid),
            %% Send both for now here.
            ok = notify_profile_update(Uid, Ouid),
            ok = notify_profile_update(Uid, Ouid, follower_notice),
            ejabberd_hooks:run(new_follow_relationship, ?KATCHUP, [Uid, Ouid]),
            ?INFO("~s follows ~s", [Uid, Ouid]),
            #pb_relationship_response{
                result = ok,
                profile = model_accounts:get_basic_user_profiles(Uid, Ouid)
            };
        true ->
            ?INFO("~s follows ~s failed (someone was blocked)", [Uid, Ouid]),
            #pb_relationship_response{
                result = fail
            }
    end,
    pb:make_iq_result(IQ, Ret);

%% RelationshipRequest (action = unfollow)
process_local_iq(#pb_iq{from_uid = Uid,
        payload = #pb_relationship_request{action = unfollow, uid = Ouid}} = IQ) ->
    case model_follow:is_blocked_any(Uid, Ouid) of
        false ->
            ok = model_follow:unfollow(Uid, Ouid),
            ok = notify_profile_update(Uid, Ouid),
            ejabberd_hooks:run(remove_follow_relationship, ?KATCHUP, [Uid, Ouid]);
        true ->
            ?INFO("~s tries to unfollow ~s as a follower but someone is already blocked", [Uid, Ouid]),
            ok
    end,
    Ret = #pb_relationship_response{
        result = ok,
        profile = model_accounts:get_basic_user_profiles(Uid, Ouid)
    },
    ?INFO("~s unfollows ~s", [Uid, Ouid]),
    pb:make_iq_result(IQ, Ret);


%% RelationshipRequest (action = remove_follower)
process_local_iq(#pb_iq{from_uid = Uid,
        payload = #pb_relationship_request{action = remove_follower, uid = Ouid}} = IQ) ->
    case model_follow:is_blocked_any(Uid, Ouid) of
        false ->
            ok = model_follow:unfollow(Ouid, Uid),
            %% if I remove someone as a follower, I should not show up in their follow suggestions for a while
            ok = model_accounts:add_rejected_suggestions(Ouid, [Uid]),
            ok = notify_profile_update(Uid, Ouid),
            ejabberd_hooks:run(remove_follow_relationship, ?KATCHUP, [Ouid, Uid]);
        true ->
            ?INFO("~s tries to remove ~s as a follower but someone is already blocked", [Uid, Ouid]),
            ok
    end,
    Ret = #pb_relationship_response{
        result = ok,
        profile = model_accounts:get_basic_user_profiles(Uid, Ouid)
    },
    ?INFO("~s removes ~s as a follower", [Uid, Ouid]),
    pb:make_iq_result(IQ, Ret);


%% RelationshipRequest (action = block)
process_local_iq(#pb_iq{from_uid = Uid,
        payload = #pb_relationship_request{action = block, uid = Ouid}} = IQ) ->
    Notify = model_follow:is_following(Uid, Ouid) orelse model_follow:is_follower(Uid, Ouid),
    %% model_follow:block will remove follow relationship from each user
    ok = model_follow:block(Uid, Ouid),
    case Notify of
        true ->
            ok = notify_account_deleted(Uid, Ouid);
        false -> ok
    end,
    ejabberd_hooks:run(block_uids, ?KATCHUP, [Uid, util:get_host(), [Ouid]]),
    UserProfile = model_accounts:get_basic_user_profiles(Uid, Ouid),
    Ret = #pb_relationship_response{
        result = ok,
        profile = UserProfile
    },
    ?INFO("~s blocked ~s", [Uid, Ouid]),
    pb:make_iq_result(IQ, Ret);


%% RelationshipRequest (action = unblock)
process_local_iq(#pb_iq{from_uid = Uid,
        payload = #pb_relationship_request{action = unblock, uid = Ouid}} = IQ) ->
    ok = model_follow:unblock(Uid, Ouid),
    ejabberd_hooks:run(unblock_uids, ?KATCHUP, [Uid, util:get_host(), [Ouid]]),
    Ret = #pb_relationship_response{
        result = ok,
        profile = model_accounts:get_basic_user_profiles(Uid, Ouid)
    },
    ?INFO("~s unblocked ~s", [Uid, Ouid]),
    pb:make_iq_result(IQ, Ret).

%%====================================================================
%% API
%%====================================================================

remove_user(Uid, _Server) ->
    %% Unfollow all
    {ok, FollowingUids} = model_follow:remove_all_following(Uid),
    lists:foreach(
        fun(Ouid) -> notify_account_deleted(Uid, Ouid) end,
        FollowingUids),
    %% Remove all followers
    {ok, FollowerUids} = model_follow:remove_all_followers(Uid),
    lists:foreach(
        fun(Ouid) -> notify_account_deleted(Uid, Ouid) end,
        FollowerUids),
    %% Remove all block/blocked by relationships
    model_follow:remove_all_blocked_uids(Uid),
    model_follow:remove_all_blocked_by_uids(Uid),
    ?INFO("Removed all following/follower, blocked/blocked by lists for ~s", [Uid]),
    ok.


-spec notify_profile_update(Uid :: uid() | list(uid()), Ouid :: uid() | list(uid())) -> ok.
notify_profile_update(Uid, Ouid)  ->
    notify_profile_update(Uid, Ouid, normal).


-spec notify_profile_update(Uid :: uid() | list(uid()), Ouid :: uid() | list(uid()), UpdateType :: 'pb_profile_update.Type'()) -> ok.
notify_profile_update(Uid, Ouids, UpdateType) when is_list(Ouids) ->
    %% Notify Ouids about a change to Uid's profile
    Profiles = model_accounts:get_basic_user_profiles(Ouids, Uid),
    lists:foreach(
        fun({Ouid, Profile}) ->
            send_msg(Uid, Ouid, #pb_profile_update{type = UpdateType, profile = Profile})
        end,
        lists:zip(Ouids, Profiles));

notify_profile_update(Uid, Ouid, UpdateType) ->
    %% Notify Ouid about a change to Uid's profile
    ProfileUpdate = #pb_profile_update{type = UpdateType, profile = model_accounts:get_basic_user_profiles(Ouid, Uid)},
    send_msg(Uid, Ouid, ProfileUpdate).

%%====================================================================
%% Internal functions
%%====================================================================

notify_account_deleted(Uid, Ouid) ->
    %% Notify Ouid that Uid's account no longer exists
    %% this could also mean Ouid has been blocked by Uid
    UserProfile = model_accounts:get_basic_user_profiles(Ouid, Uid),
    ProfileUpdate = #pb_profile_update{type = delete, profile = UserProfile},
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

