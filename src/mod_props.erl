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
-include("packets.hrl").
-include("groups.hrl").
-include("time.hrl").

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
    get_props/2    %% debug only
]).

%%====================================================================
%% gen_mod functions
%%====================================================================

start(Host, _Opts) ->
    gen_iq_handler:add_iq_handler(ejabberd_local, Host, pb_props, ?MODULE, process_local_iq, 2),
    ok.

stop(Host) ->
    gen_iq_handler:remove_iq_handler(ejabberd_local, Host, pb_props),
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
    PropMap1 = #{
        dev => false, %% whether the client is dev or not.
        contact_sync_frequency => 1 * ?DAYS, %% how often should clients sync all contacts.
        max_group_size => ?MAX_GROUP_SIZE, %% max limit on the group size.
        max_post_media_items => 10, %% max number of media_items client can post.
        max_chat_media_items => 30, %% max number of media_items client can share in a chat message.
        group_chat => false, %% whether the client can access group_chat or not.
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
        draw_media => false,
        privacy_label => false,
        krisp_noise_suppression => false,
        group_comments_notification => true, %% notifications for group comments by friends on group posts.
        home_feed_comment_notifications => false, %% notifications for home feed comments by friends.
        nse_runtime_sec => 17, %% ios-nse needs 3 secs to cleanup, we want our nse to run =< 20 secs.
        file_sharing => false,   %% clients are capable of sending files.
        invite_strings => mod_invites:get_invite_strings_bin(Uid), %% json string with invite text.
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
        location_sharing => false
    },
    PropMap2 = get_uid_based_props(PropMap1, Uid),
    ClientType = util_ua:get_client_type(ClientVersion),
    PropMap3 = get_client_based_props(PropMap2, ClientType, ClientVersion),
    Proplist = maps:to_list(PropMap3),
    lists:keysort(1, Proplist).

%%====================================================================
%% Internal functions
%%====================================================================

-spec get_uid_based_props(PropMap :: map(), Uid :: binary()) -> map().
get_uid_based_props(PropMap, Uid) ->
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
            PropMap8 = maps:update(file_sharing, true, PropMap7),
            PropMap9 = maps:update(use_cleartext_group_feed, false, PropMap8),
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
            PropMap21 = maps:update(close_friends_recos, true, PropMap20),
            PropMap22 = maps:update(location_sharing, true, PropMap21),
            PropMap23 = maps:update(group_chat, true, PropMap22),
            PropMap23
    end,
    apply_uid_prop_overrides(Uid, ResPropMap).


-spec get_client_based_props(PropMap :: map(),
        ClientType :: atom(), ClientVersion :: binary()) -> map().
get_client_based_props(PropMap, android, ClientVersion) ->
    PropMap4 = maps:update(streaming_sending_enabled, true, PropMap),
    Result4 = util_ua:is_version_less_than(ClientVersion, <<"HalloApp/Android1.3.6">>),
    PropMap5 = maps:update(use_cleartext_group_feed, Result4, PropMap4),
    Result5 = util_ua:is_version_greater_than(ClientVersion, <<"HalloApp/Android1.4.5">>),
    PropMap6 = maps:update(group_expiry, Result5, PropMap5),
    Result6 = util_ua:is_version_less_than(ClientVersion, <<"HalloApp/Android1.5.1">>),
    PropMap7 = maps:update(cleartext_group_feed, Result6, PropMap6),
    PropMap7;

get_client_based_props(PropMap, ios, ClientVersion) ->
    %% Enable groups grid on the latest version.
    Result3 = util_ua:is_version_greater_than(ClientVersion, <<"HalloApp/iOS1.21.279">>),
    PropMap3 = maps:update(enable_groups_grid, Result3, PropMap),
    %% Enable group encryption on latest ios build.
    Result4 = util_ua:is_version_less_than(ClientVersion, <<"HalloApp/iOS1.21.279">>),
    PropMap4 = maps:update(use_cleartext_group_feed, Result4, PropMap3),
    Result5 = util_ua:is_version_greater_than(ClientVersion, <<"HalloApp/iOS1.22.290">>),
    PropMap5 = maps:update(new_chat_ui, Result5, PropMap4),
    Result6 = util_ua:is_version_greater_than(ClientVersion, <<"HalloApp/iOS1.23.292">>),
    PropMap6 = maps:update(group_expiry, Result6, PropMap5),
    Result7 = util_ua:is_version_greater_than(ClientVersion, <<"HalloApp/iOS1.22.290">>),
    PropMap7 = maps:update(pre_answer_calls, Result7, PropMap6),
    PropMap8 = maps:update(streaming_sending_enabled, true, PropMap7),
    Result8 = util_ua:is_version_less_than(ClientVersion, <<"HalloApp/iOS1.24.295">>),
    PropMap9 = maps:update(cleartext_group_feed, Result8, PropMap8),
    PropMap9;

get_client_based_props(PropMap, undefined, _) ->
    maps:update(groups, false, PropMap).


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

