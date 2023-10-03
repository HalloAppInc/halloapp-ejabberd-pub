%%%-------------------------------------------------------------------
%%% @author josh
%%% @copyright (C) 2020, HalloApp, Inc.
%%% @doc
%%%
%%% @end
%%%-------------------------------------------------------------------
-module(mod_props).
-author("josh").
-behaviour(gen_mod).

-include("ha_types.hrl").
-include("logger.hrl").
-include("props.hrl").
-include("feed.hrl").
-include("packets.hrl").
-include("groups.hrl").
-include("time.hrl").


-define(DAILY_NOTIF_STRINGS_FILE, "daily_katchup_body_strings.json").

-ifdef(TEST).
-export([
    generate_hash/1,
    make_response/3    
]).
-endif.

%% gen_mod API.
-export([start/2, stop/1, reload/3, depends/2, mod_options/1]).
-export([process_local_iq/2]).

%% API
-export([
    get_hash/2,
    get_props/2,    %% debug only
    get_invite_strings_to_rm_by_cc/2,
    get_daily_notif_strings_bin/0
]).

%%====================================================================
%% gen_mod functions
%%====================================================================

start(_Host, _Opts) ->
    gen_iq_handler:add_iq_handler(ejabberd_local, halloapp, pb_props, ?MODULE, process_local_iq, 2),
    gen_iq_handler:add_iq_handler(ejabberd_local, katchup, pb_props, ?MODULE, process_local_iq, 2),
    ok.

stop(_Host) ->
    gen_iq_handler:remove_iq_handler(ejabberd_local, halloapp, pb_props),
    gen_iq_handler:remove_iq_handler(ejabberd_local, katchup, pb_props),
    ok.

depends(_Host, _Opts) ->
    [].

reload(_Host, _NewOpts, _OldOpts) ->
    ok.

mod_options(_Host) ->
    [].

%%====================================================================
%% IQ handler
%%====================================================================

process_local_iq(#pb_iq{from_uid = Uid, type = get} = IQ,
        #{client_version := ClientVersion} = _C2SState) ->
    IsDev = dev_users:is_dev_uid(Uid),
    {Hash, SortedProplist} = get_props_and_hash(Uid, ClientVersion),
    ?INFO("Uid:~s (dev = ~s) requesting props. hash = ~s, proplist = ~p",
        [Uid, IsDev, Hash, SortedProplist]),
    make_response(IQ, SortedProplist, Hash).

%%====================================================================
%% API
%%====================================================================

-spec get_hash(Uid :: binary(), ClientVersion :: binary()) -> binary().
get_hash(Uid, ClientVersion) ->
    try
        {Hash, _} = get_props_and_hash(Uid, ClientVersion),
        Hash
    catch
        Class:Reason:Stacktrace ->
            ?ERROR("Stacktrace:~s",
                [lager:pr_stacktrace(Stacktrace, {Class, Reason})]),
            ?INFO("Unable to fetch props hash Uid: ~s ClientVersion: ~p", [Uid, ClientVersion]),
            <<>>
    end.


-spec get_props(Uid :: binary(), ClientVersion :: binary()) -> proplist().
get_props(Uid, ClientVersion) ->
    case util_ua:get_app_type(ClientVersion) of
        undefined -> [];
        AppType -> get_props(Uid, ClientVersion, AppType)
    end.


-spec get_props(Uid :: binary(), ClientVersion :: binary(), AppType :: app_type()) -> proplist().
get_props(Uid, ClientVersion, katchup) ->
    PropMap1 = #{
        dev => false, %% whether the client is dev or not.
        contact_sync_frequency => 1 * ?DAYS, %% how often should clients sync all contacts.
        max_video_bit_rate => 4000000, %% max_video_bit_rate set to 4Mbps.
        %% Lower bitrate on selfie is because selfies are shown only in a small view on screen.
        max_selfie_video_bit_rate => 1000000, %% max_selfie_video_bit_rate set to 1Mbps.
        audio_note_bit_rate => 96000, %% audio_note_bit_rate set to 96Kbps.
        streaming_upload_chunk_size =>  65536, %% size of media streaming upload chunk size, 64KB.
        streaming_initial_download_size => 5242880, %% size of intial download while media streaming, 5MB.
        streaming_sending_enabled => true, %% whether streaming is enabled.
        emoji_version => 2, %% emoji version for clients to use.
        nse_runtime_sec => 17, %% ios-nse needs 3 secs to cleanup, we want our nse to run =< 20 secs.
        enable_sentry_perf_tracking => false, %% Enable Sentry perf tracking on iOS clients
        background_upload => true,   %% Enables background upload on ios clients.
        relationship_sync_frequency => 1 * ?DAYS, %% how often should clients sync all relationships.
        refresh_public_feed_interval_secs => ?KATCHUP_PUBLIC_FEED_REFRESH_SECS,
        close_friends_recos => false, %% Should invite recommendations be sorted based on number of close friends
        ai_generated_images => false,  %% Enable AI-generated images for the background of text posts
        ambassador => false,
        feed_comment_notifications => true,
        feed_following_comment_notifications => false,
        daily_katchup_notif_template => <<>>
    },
    ClientType = util_ua:get_client_type(ClientVersion),
    AppType = util_ua:get_app_type(ClientVersion),
    PropMap2 = case model_accounts:get_phone(Uid) of
        {ok, Phone} ->
            get_phone_based_props(PropMap1, AppType, Phone);
        {error, _} ->
            PropMap1
    end,
    PropMap3 = get_client_based_props(PropMap2, AppType, ClientType, ClientVersion),
    PropMap4 = get_uid_based_props(PropMap3, AppType, Uid),
    Proplist = maps:to_list(PropMap4),
    lists:keysort(1, Proplist);

get_props(Uid, ClientVersion, halloapp) ->
    PropMap1 = #{
        dev => false, %% whether the client is dev or not.
        contact_sync_frequency => 1 * ?DAYS, %% how often should clients sync all contacts.
        relationship_sync_frequency => 1 * ?DAYS, %% how often should clients sync all relationships.
        max_group_size => ?MAX_GROUP_SIZE, %% max limit on the group size.
        max_post_media_items => 10, %% max number of media_items client can post.
        max_chat_media_items => 30, %% max number of media_items client can share in a chat message.
        group_chat => true, %% whether the client can access group_chat or not.
        max_feed_video_duration => 600, %% duration in seconds for videos on feed.
        max_chat_video_duration => 600, %% duration in seconds for videos in chats.
        private_reactions => false, %% whether client can send private reactions.
        group_sync_time => 1 * ?WEEKS, %% how often should clients sync group metadata
        max_video_bit_rate => 4000000, %% max_video_bit_rate set to 4Mbps.
        audio_note_bit_rate => 96000, %% audio_note_bit_rate set to 96Kbps.
        cleartext_group_feed => true, %% whether client must send unencrypted content in group_feed.
        use_cleartext_group_feed => true, %% whether clients must rely on unencrypted content in group_feed.
        cleartext_home_feed => true, %% whether client must send unencrypted content in home_feed.
        use_cleartext_home_feed => true, %% whether clients must rely on unencrypted content in home_feed.
        audio_calls => true, %% whether clients can make audio calls.
        video_calls => true, %% whether clients can make video calls.
        call_wait_timeout => 60, %% time (sec) to wait before ending the call on timeout when remote party is not responding.
        streaming_upload_chunk_size =>  65536, %% size of media streaming upload chunk size, 64KB.
        streaming_initial_download_size => 5242880, %% size of intial download while media streaming, 5MB.
        streaming_sending_enabled => false, %% whether streaming is enabled.
        emoji_version => 2, %% emoji version for clients to use.
        call_hold => false, %% allow calls to be on hold
        call_rerequest => false, %% controls if clients will respond to call-rerequests and also wait for them
        group_max_for_showing_invite_sheet => 5, %% max members to show the invite link after group flow.
        draw_media => true,
        privacy_label => false,
        krisp_noise_suppression => false,
        group_comments_notification => true, %% notifications for group comments by friends on group posts.
        home_feed_comment_notifications => false, %% notifications for home feed comments by friends.
        nse_runtime_sec => 17, %% ios-nse needs 3 secs to cleanup, we want our nse to run =< 20 secs.
        file_sharing => true,   %% clients are capable of sending files.
        invite_strings => mod_invites:get_invite_strings_bin(Uid), %% json string with invite text.
        pre_invite_strings => mod_invites:get_pre_invite_strings_bin(Uid),
        new_chat_ui => false,   %% turn on new chat ui on ios.
        is_psa_admin => false, %% is client allowed to post PSA Moment
        group_expiry => false, %% whether group expiry option is turned on for clients.
        default_krisp_noise_suppression => false,  %% Should client use noise suppression by default
        enable_sentry_perf_tracking => false, %% Enable Sentry perf tracking on iOS clients
        enable_groups_grid => false, %% enables the new group grid experience on iOS clients
        chat_reactions => false, %% enable reactions in chat on the sending side.
        comment_reactions => false, %% enable reactions in comments on the sending side.
        post_reactions => false, %% enable reactions in posts on the sending side.
        pre_answer_calls => false,   %% Enables clients to pre-answer calls.
        background_upload => false,   %% Enables background upload on ios clients.
        aggressive_invite_screen => false,  %% Indicates to the client to show invite screen
        contact_sharing => false,  %% Enables clients to share contacts on chat
        close_friends_recos => false, %% Should invite recommendations be sorted based on number of close friends
        location_sharing => false,
        moment_external_share => false, %% Enabled external sharing of moments
        photo_suggestions => true %% Enable Magic Posts tab
    },
    AppType = util_ua:get_app_type(ClientVersion),
    ClientType = util_ua:get_client_type(ClientVersion),
    PropMap2 = get_uid_based_props(PropMap1, AppType, Uid),
    PropMap3 = get_client_based_props(PropMap2, AppType, ClientType, ClientVersion),
    Proplist = maps:to_list(PropMap3),
    lists:keysort(1, Proplist).


-spec get_invite_strings_to_rm_by_cc(binary(), app_type()) -> #{LangId :: binary() => list(InvStr :: binary())}.
get_invite_strings_to_rm_by_cc(CC, AppType) ->
    %% This is a map of lang_id -> strings_to_rm for each country
    case {CC, AppType} of
        {<<"US">>, ?HALLOAPP} -> #{<<"en">> => [
            %% ID: bC4w8HJbHV0zVxoZsIh+rA==
            <<"I am inviting you to install HalloApp. Download for free here: https://halloapp.com/free">>,
            %% ID: rpQ1erWtA2dUhEnDRYXOuA==
            <<"Hey %@, let’s keep in touch on HalloApp. Download at https://halloapp.com/kit (HalloApp is a new, private social app for close friends and family, with no ads or algorithms).">>
        ]};
        _ -> #{}
    end.

%%====================================================================
%% Internal functions
%%====================================================================

-spec get_uid_based_props(PropMap :: map(), AppType :: atom(), Uid :: binary()) -> map().
get_uid_based_props(PropMap, halloapp, Uid) ->
    ResPropMap = case dev_users:is_dev_uid(Uid) of
        false ->
            PropMap;
        true ->
            % Set dev to be true.
            PropMap1 = maps:update(dev, true, PropMap),
            PropMap2 = maps:update(streaming_sending_enabled, true, PropMap1),
            PropMap3 = maps:update(call_hold, true, PropMap2),
            PropMap5 = maps:update(draw_media, true, PropMap3),
            PropMap6 = maps:update(privacy_label, true, PropMap5),
            PropMap7 = maps:update(home_feed_comment_notifications, false, PropMap6),
            PropMap8 = maps:update(use_cleartext_group_feed, true, PropMap7),
            PropMap9 = maps:update(cleartext_group_feed, true, PropMap8),
            PropMap10 = maps:update(new_chat_ui, true, PropMap9),
            PropMap11 = maps:update(enable_sentry_perf_tracking, true, PropMap10),
            PropMap12 = maps:update(group_expiry, true, PropMap11),
            PropMap13 = maps:update(enable_groups_grid, true, PropMap12),
            PropMap14 = maps:update(chat_reactions, true, PropMap13),
            PropMap15 = maps:update(comment_reactions, true, PropMap14),
            PropMap16 = maps:update(post_reactions, true, PropMap15),
            PropMap17 = maps:update(pre_answer_calls, true, PropMap16),
            PropMap18 = maps:update(background_upload, true, PropMap17),
            PropMap19 = maps:update(aggressive_invite_screen, true, PropMap18),
            PropMap20 = maps:update(contact_sharing, true, PropMap19),
            PropMap21 = maps:update(close_friends_recos, false, PropMap20),
            PropMap22 = maps:update(location_sharing, true, PropMap21),
            PropMap23 = maps:update(moment_external_share, true, PropMap22),
            PropMap23
    end,
    apply_uid_prop_overrides(Uid, ResPropMap);

get_uid_based_props(PropMap, katchup, Uid) ->
    ResPropMap = case dev_users:is_dev_uid(Uid) of
        false ->
            PropMap;
        true ->
            % Set dev to be true.
            PropMap#{
                dev => true,
                ai_generated_images => true,
                feed_comment_notifications => true,
                feed_following_comment_notifications => true,
                daily_katchup_notif_template => get_daily_notif_strings_bin()
            }
    end,
    apply_uid_prop_overrides(Uid, ResPropMap).


get_phone_based_props(PropMap, katchup, Phone) ->
    PropMap1 = maps:update(ambassador, dev_users:is_katchup_ambassador_phone(Phone), PropMap),
    PropMap1;

get_phone_based_props(PropMap, _, _Phone) ->
    PropMap.


-spec get_client_based_props(PropMap :: map(), AppType :: atom(),
        ClientType :: atom(), ClientVersion :: binary()) -> map().
get_client_based_props(PropMap, halloapp, android, ClientVersion) ->
    PropMap4 = maps:update(streaming_sending_enabled, true, PropMap),
    Result5 = util_ua:is_version_greater_than(ClientVersion, <<"HalloApp/Android1.4.5">>),
    PropMap5 = maps:update(group_expiry, Result5, PropMap4),
    Result6 = util_ua:is_version_greater_than(ClientVersion, <<"HalloApp/Android1.5.4">>),
    PropMap6 = maps:update(chat_reactions, Result6, PropMap5),
    PropMap7 = maps:update(comment_reactions, Result6, PropMap6),
    Result7 = util_ua:is_version_greater_than(ClientVersion, <<"HalloApp/Android1.6.4">>),
    PropMap8 = maps:update(post_reactions, Result7, PropMap7),
    PropMap9 = maps:update(photo_suggestions, false, PropMap8),
    PropMap9;


get_client_based_props(PropMap, halloapp, ios, ClientVersion) ->
    %% Enable groups grid on the latest version.
    Result3 = util_ua:is_version_greater_than(ClientVersion, <<"HalloApp/iOS1.21.279">>),
    PropMap3 = maps:update(enable_groups_grid, Result3, PropMap),
    Result5 = util_ua:is_version_greater_than(ClientVersion, <<"HalloApp/iOS1.22.290">>),
    PropMap5 = maps:update(new_chat_ui, Result5, PropMap3),
    Result6 = util_ua:is_version_greater_than(ClientVersion, <<"HalloApp/iOS1.23.292">>),
    PropMap6 = maps:update(group_expiry, Result6, PropMap5),
    Result7 = util_ua:is_version_greater_than(ClientVersion, <<"HalloApp/iOS1.22.290">>),
    PropMap7 = maps:update(pre_answer_calls, Result7, PropMap6),
    PropMap8 = maps:update(streaming_sending_enabled, true, PropMap7),
    Result9 = util_ua:is_version_greater_than(ClientVersion, <<"HalloApp/iOS1.25.301">>),
    PropMap10 = maps:update(chat_reactions, Result9, PropMap8),
    PropMap11 = maps:update(comment_reactions, Result9, PropMap10),
    Result10 = util_ua:is_version_greater_than(ClientVersion, <<"HalloApp/iOS1.25.305">>),
    PropMap12 = maps:update(location_sharing, Result10, PropMap11),
    Result11 = util_ua:is_version_greater_than(ClientVersion, <<"HalloApp/iOS1.26.318">>),
    PropMap13 = maps:update(post_reactions, Result11, PropMap12),
    PropMap14 = maps:update(background_upload, Result11, PropMap13),
    PropMap15 = maps:update(moment_external_share, Result11, PropMap14),
    PropMap15;

get_client_based_props(PropMap, halloapp, undefined, _) ->
    maps:update(groups, false, PropMap);

get_client_based_props(PropMap, katchup, android, ClientVersion) ->
    Result1 = util_ua:is_version_greater_than(ClientVersion, <<"Katchup/Android1.10.5">>),
    PropMap1 = maps:update(ai_generated_images, Result1, PropMap),
    PropMap1;

get_client_based_props(PropMap, katchup, ios, ClientVersion) ->
    Result1 = util_ua:is_version_greater_than(ClientVersion, <<"Katchup/iOS1.7.52">>),
    PropMap1 = maps:update(ai_generated_images, Result1, PropMap),
    PropMap1.


apply_uid_prop_overrides(Uid, PropMap) ->
    maps:map(
        fun (K, V) ->
            case uid_prop_override(Uid, K) of
                undef -> V;
                NewV -> NewV
            end
        end,
        PropMap).

-spec uid_prop_override(Uid :: uid(), Prop :: atom()) -> undef | term().
uid_prop_override(<<"1000000000490675850">>, use_cleartext_group_feed) -> false;  %% Murali (groupe2e)
uid_prop_override(<<"1000000000212763494">>, use_cleartext_group_feed) -> false;  %% Murali (groupe2e)
uid_prop_override(Uid, is_psa_admin) ->
    dev_users:is_psa_admin(Uid);
uid_prop_override(_Uid, _Prop) ->
    undef.

generate_hash(SortedProplist) ->
    Json = jsx:encode(SortedProplist),
    <<HashValue:?PROPS_SHA_HASH_LENGTH_BYTES/binary, _Rest/binary>> = crypto:hash(sha256, Json),
    HashValue.


get_props_and_hash(Uid, ClientVersion) ->
    SortedProplist = get_props(Uid, ClientVersion),
    Hash = generate_hash(SortedProplist),
    {Hash, SortedProplist}.


make_response(IQ, SortedProplist, Hash) ->
    Props = [#pb_prop{name = util:to_binary(Key), value = util:to_binary(Val)} ||
            {Key, Val} <- SortedProplist],
    Prop = #pb_props{hash = Hash, props = Props},
    pb:make_iq_result(IQ, Prop).


get_daily_notif_strings_bin() ->
    try
        Filename = filename:join(misc:data_dir(), ?DAILY_NOTIF_STRINGS_FILE),
        {ok, Bin} = file:read_file(Filename),
        InviteStringsMap = jiffy:decode(Bin, [return_maps]),
        %% en localization strings dont appear with other languages in ios repo for some reason.
        InviteStringsMap1 = InviteStringsMap#{
            <<"en">> => <<"%1$@"/utf8>>
        },
        jiffy:encode(InviteStringsMap1)
    catch
        Class: Reason: Stacktrace  ->
            ?ERROR("Failed to get invite strings", [lager:pr_stacktrace(Stacktrace, {Class, Reason})]),
            <<>>
    end.

