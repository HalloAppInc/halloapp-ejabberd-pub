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
-include("packets.hrl").

%% gen_mod API
-export([start/2, stop/1, reload/3, depends/2, mod_options/1]).

%% API
-export([
    process_local_iq/1
]).

-define(MAX_BIO_LENGTH, 150).
-define(VALID_LINK_TYPES, [user_defined, tiktok, snapchat, instagram]).

%%====================================================================
%% gen_mod API
%%====================================================================

start(_Host, _Opts) ->
    gen_iq_handler:add_iq_handler(ejabberd_local, ?KATCHUP, pb_user_profile_request, ?MODULE, process_local_iq),
    ok.

stop(_Host) ->
    gen_iq_handler:remove_iq_handler(ejabberd_local, ?KATCHUP, pb_user_profile_request),
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

