%%%-------------------------------------------------------------------
%%% @author josh
%%% @copyright (C) 2022, HalloApp, Inc.
%%% @doc
%%%
%%% @end
%%%-------------------------------------------------------------------
-module(mod_user_profile).
-author("josh").

-include("ha_types.hrl").
-include("logger.hrl").
-include("feed.hrl").
-include("account.hrl").
-include("packets.hrl").

%% gen_mod API
-export([start/2, stop/1, reload/3, depends/2, mod_options/1]).

%% API
-export([
    process_local_iq/1,
    account_name_updated/2,
    user_avatar_published/3,
    username_updated/2,
    broadcast_profile_update/1
]).

-define(MAX_BIO_LENGTH, 150).
-define(VALID_LINK_TYPES, [user_defined, tiktok, snapchat, instagram]).

%%====================================================================
%% gen_mod API
%%====================================================================

start(_Host, _Opts) ->
    gen_iq_handler:add_iq_handler(ejabberd_local, ?KATCHUP, pb_user_profile_request, ?MODULE, process_local_iq),
    ejabberd_hooks:add(account_name_updated, katchup, ?MODULE, account_name_updated, 50),
    ejabberd_hooks:add(user_avatar_published, katchup, ?MODULE, user_avatar_published, 50),
    ejabberd_hooks:add(username_updated, katchup, ?MODULE, username_updated, 50),
    ok.

stop(_Host) ->
    gen_iq_handler:remove_iq_handler(ejabberd_local, ?KATCHUP, pb_user_profile_request),
    ejabberd_hooks:delete(account_name_updated, katchup, ?MODULE, account_name_updated, 50),
    ejabberd_hooks:delete(user_avatar_published, katchup, ?MODULE, user_avatar_published, 50),
    ejabberd_hooks:delete(username_updated, katchup, ?MODULE, username_updated, 50),
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

%% SetBioRequest
process_local_iq(#pb_iq{from_uid = Uid, payload = #pb_set_bio_request{text = Text}} = Iq) ->
    Ret = case byte_size(Text) >= ?MAX_BIO_LENGTH of
        true ->
            #pb_set_bio_result{
                result = fail,
                reason = too_long
            };
        false ->
            ok = model_accounts:set_bio(Uid, Text),
            #pb_set_bio_result{result = ok}
    end,
    pb:make_iq_result(Iq, Ret);


%% SetLinkRequest
process_local_iq(#pb_iq{from_uid = Uid,
        payload = #pb_set_link_request{link = #pb_link{type = BinType, text = Text}}} = Iq) ->
    Type = util:to_atom(BinType),
    Ret = case lists:member(Type, ?VALID_LINK_TYPES) of
        true ->
            LinkMap = model_accounts:get_links(Uid),
            ok = model_accounts:set_links(Uid, LinkMap#{Type => Text}),
            #pb_set_link_result{result = ok};
        false ->
            #pb_set_link_result{result = fail, reason = bad_type}
    end,
    pb:make_iq_result(Iq, Ret);


%% UserProfileRequest for uid
process_local_iq(#pb_iq{from_uid = Uid,
        payload = #pb_user_profile_request{uid = Ouid}} = Iq) when Ouid =/= undefined andalso Ouid =/= <<>> ->
    process_user_profile_request(Uid, Ouid, Iq);

%% UserProfileRequest for username
process_local_iq(#pb_iq{from_uid = Uid,
        payload = #pb_user_profile_request{username = Username}} = Iq)
        when Username =/= undefined andalso Username =/= <<>> ->
    {ok, Ouid} = model_accounts:get_username_uid(Username),
    process_user_profile_request(Uid, Ouid, Iq);

%% UserProfileRequest (invalid)
process_local_iq(#pb_iq{payload = #pb_user_profile_request{}} = Iq) ->
    Ret = #pb_user_profile_result{
        result = fail,
        reason = unknown_reason
    },
    pb:make_iq_result(Iq, Ret).

%%====================================================================
%% Hooks
%%====================================================================

-spec account_name_updated(Uid :: binary(), Name :: binary()) -> ok.
account_name_updated(Uid, _Name) ->
    broadcast_profile_update(Uid),
    ok.

-spec user_avatar_published(Uid :: binary(), Server :: binary(), AvatarId :: binary()) -> ok.
user_avatar_published(Uid, _Server, _AvatarId) ->
    broadcast_profile_update(Uid),
    ok.


-spec username_updated(Uid :: binary(), Username :: binary()) -> ok.
username_updated(Uid, _Username) ->
    broadcast_profile_update(Uid),
    ok.


%%====================================================================
%% Internal functions
%%====================================================================

process_user_profile_request(Uid, Ouid, Iq) ->
    Ret = case model_accounts:account_exists(Ouid) andalso not model_follow:is_blocked_any(Uid, Ouid) of
        true ->
            UserProfile = model_accounts:get_user_profiles(Uid, Ouid),
            RawRecentPosts = model_feed:get_recent_user_posts(Uid),
            AccountName = model_accounts:get_name_binary(Uid),
            RecentPosts = lists:map(
                fun(#post{id = PostId, payload = PayloadBase64, ts_ms = TimestampMs, tag = PostTag, moment_info = MomentInfo}) ->
                    #pb_post{
                        id = PostId,
                        publisher_uid = Uid,
                        publisher_name = AccountName,
                        payload = base64:decode(PayloadBase64),
                        timestamp = util:ms_to_sec(TimestampMs),
                        moment_info = MomentInfo,
                        tag = PostTag
                    }
                end, RawRecentPosts),
            #pb_user_profile_result{
                result = ok,
                profile = UserProfile,
                recent_posts = RecentPosts
            };
        false ->
            #pb_user_profile_result{
                result = fail,
                reason = no_user
            }
    end,
    pb:make_iq_result(Iq, Ret).


%% Broadcasts profile update to followers.
%% TODO: Send this to contactUids who have this number.
-spec broadcast_profile_update(Uid :: binary()) -> ok.
broadcast_profile_update(Uid) ->
    ?INFO("Broadcasting update Uid: ~p", [Uid]),
    Followers = model_follow:get_all_followers(Uid),
    Following = model_follow:get_all_following(Uid),
    {ok, Account} = model_accounts:get_account(Uid),

    lists:foreach(
        fun(FollowerUid) ->
            ?INFO("Sending update of Uid: ~p ToUid: ~p", [Uid, FollowerUid]),
            FollowingStatus = case sets:is_element(FollowerUid, sets:from_list(Following)) of
                true -> following;
                false -> none
            end,
            OFollowing = model_follow:get_all_following(FollowerUid),
            Message = #pb_msg{
                id = util_id:new_msg_id(),
                to_uid = FollowerUid,
                payload = #pb_profile_update{
                    type = normal,
                    profile =  #pb_basic_user_profile{
                            uid = Uid,
                            username = Account#account.username,
                            name = Account#account.name,
                            avatar_id = Account#account.avatar_id,
                            follower_status = following,
                            following_status = FollowingStatus,
                            num_mutual_following = sets:size(sets:intersection(sets:from_list(Following), sets:from_list(OFollowing)))
                        }
                    }
                },
            ejabberd_router:route(Message)
        end, Followers),
    ok.

